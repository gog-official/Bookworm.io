package clients

import (
	"fmt"
	"log"
	"net/http"
	"sync"

	"server/internal/server"
	"server/internal/server/states"
	"server/pkg/packets"

	"github.com/gorilla/websocket"
	"google.golang.org/protobuf/proto"
)

type WebSocketClient struct {
	id       uint64
	conn     *websocket.Conn
	hub      *server.Hub
	sendChan chan *packets.Packet
	logger   *log.Logger
	state    server.ClientStateHandler
	dbTx     *server.DbTx

	closeOnce sync.Once
	// sendMux is held for reading while a packet is queued and for writing while
	// sendChan is closed. A state that has not noticed the disconnect yet can still
	// be mid-send, and closing the channel under it would panic the whole server.
	sendMux sync.RWMutex
	closed  bool
	dropped int

	// stateMux guards the state pointer only. It is never held across OnEnter/OnExit
	// or HandleMessage, because those re-enter SetState.
	stateMux sync.RWMutex
}

func NewWebSocketClient(hub *server.Hub, writer http.ResponseWriter, request *http.Request) (server.ClientInterfacer, error) {
	upgrader := websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin:     func(_ *http.Request) bool { return true },
	}
	conn, err := upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return nil, err
	}
	c := &WebSocketClient{
		hub:      hub,
		conn:     conn,
		sendChan: make(chan *packets.Packet, 1024),
		logger:   log.New(log.Writer(), "Client unknown: ", log.LstdFlags),
		dbTx:     hub.NewDbTx(),
	}
	return c, nil
}
func (c *WebSocketClient) Id() uint64 {
	return c.id
}

func (c *WebSocketClient) Initialize(id uint64) {
	c.id = id
	c.logger.SetPrefix(fmt.Sprintf("Client %d", c.id))
	c.SetState(&states.Connected{})
}

func (c *WebSocketClient) ProcessMessage(senderId uint64, message packets.Msg) {
	c.stateMux.RLock()
	state := c.state
	c.stateMux.RUnlock()
	if state == nil {
		return
	}
	state.HandleMessage(senderId, message)
}
func (c *WebSocketClient) SocketSend(message packets.Msg) {
	c.SocketSendAs(message, c.id)
}
func (c *WebSocketClient) SocketSendAs(message packets.Msg, senderId uint64) {
	c.sendMux.RLock()
	defer c.sendMux.RUnlock()
	if c.closed {
		return
	}

	select {
	case c.sendChan <- &packets.Packet{SenderId: senderId, Msg: message}:
	default:
		// A full queue means this socket stopped draining long ago (the buffer holds
		// ~50s of 20Hz updates), so the peer is gone no matter what. Report it once
		// instead of twenty times a second, then tear the client down so the queue
		// cannot keep growing and the log cannot flood.
		c.dropped++
		if c.dropped == 1 {
			c.logger.Printf("send channel full, dropping message: %T", message)
			go c.Close("send channel full")
		}
	}
}
func (c *WebSocketClient) PassToPeer(message packets.Msg, peerId uint64) {
	if peer, exists := c.hub.Clients.Get(peerId); exists {
		peer.ProcessMessage(c.id, message)
	}
}

// The hub drains BroadcastChan on its own goroutine, and it dispatches to clients
// synchronously from there. So any handler that reaches a nested broadcast -- a
// death dropping its books, a chat, a spore -- would otherwise block the hub while
// the hub is the only thing able to unblock it, deadlocking the entire server.
func (c *WebSocketClient) Broadcast(message packets.Msg) {
	packet := &packets.Packet{SenderId: c.id, Msg: message}
	select {
	case c.hub.BroadcastChan <- packet:
	default:
		// Hub is mid-dispatch and the buffer is full. Hand the send to a goroutine so
		// the caller is never blocked; it goes through as soon as the hub is idle.
		go func() { c.hub.BroadcastChan <- packet }()
	}
}

func (c *WebSocketClient) ReadPump() {
    defer func() {
        c.logger.Println("Closing read pump")
        c.Close("read pump closed")
    }()

    for {
        _, data, err := c.conn.ReadMessage()
        if err != nil {
            if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
                c.logger.Printf("error: %v", err)
            }
            break
        }

        packet := &packets.Packet{}
        err = proto.Unmarshal(data, packet)
        if err != nil {
            c.logger.Printf("error unmarshalling data: %v", err)
            continue
        }

        // To allow the client to lazily not set the sender ID, we'll assume they want to send it as themselves
        if packet.SenderId == 0 {
            packet.SenderId = c.id
        }

        c.ProcessMessage(packet.SenderId, packet.Msg)
    }
}
func (c *WebSocketClient) Close(reason string) {
	// Both pumps call Close on their way out, so this has to run exactly once.
	c.closeOnce.Do(func() {
		c.logger.Printf("Closing client connection because: %s", reason)

		// Exit the current state first. A disconnect never went through SetState, so
		// InGame.OnExit was never called and its 50ms update loop kept queueing
		// position packets into a socket nobody was reading. That is what filled the
		// send channel and spammed the log forever after the client vanished.
		c.SetState(nil)

		c.Broadcast(packets.NewDisconnect(reason))
		c.hub.UnregisterChan <- c
		c.conn.Close()

		// Flag before closing, and under the write lock, so a sender that is already
		// inside the critical section finishes queueing before the channel goes away.
		c.sendMux.Lock()
		c.closed = true
		close(c.sendChan)
		c.sendMux.Unlock()
	})
}
func (c *WebSocketClient) WritePump() {
    defer func() {
        c.logger.Println("Closing write pump")
        c.Close("write pump closed")
    }()

    for packet := range c.sendChan {
        writer, err := c.conn.NextWriter(websocket.BinaryMessage)
        if err != nil {
            c.logger.Printf("error getting writer for %T packet, closing client: %v", packet.Msg, err)
            return
        }

        data, err := proto.Marshal(packet)
        if err != nil {
            c.logger.Printf("error marshalling %T packet, dropping: %v", packet.Msg, err)
            continue
        }

        _, writeErr := writer.Write(data)

        if writeErr != nil {
            c.logger.Printf("error writing %T packet: %v", packet.Msg, err)
            continue
        }

        writer.Write([]byte{'\n'})

        if closeErr := writer.Close(); closeErr != nil {
            c.logger.Printf("error closing writer, dropping %T packet: %v", packet.Msg, err)
            continue
        }
    }
}
func (c *WebSocketClient) SetState(state server.ClientStateHandler) {
	// Swap the pointer under the lock, then run the lifecycle callbacks outside it.
	// They re-enter SetState (Connected.handleLoginRequest -> InGame), and Go's
	// RWMutex cannot be upgraded, so holding the lock across them would self-deadlock.
	c.stateMux.Lock()
	prevState := c.state
	c.state = state

	prevStateName := "None"
	if prevState != nil {
		prevStateName = prevState.Name()
	}
	newStateName := "None"
	if state != nil {
		newStateName = state.Name()
	}
	c.logger.Printf("switching form state %s to %s", prevStateName, newStateName)
	c.stateMux.Unlock()

	if prevState != nil {
		prevState.OnExit()
	}
	if state != nil {
		state.SetClient(c)
		state.OnEnter()
	}
}
func (c *WebSocketClient) DbTx() *server.DbTx {
	return c.dbTx
}
func (c *WebSocketClient) SharedGameObjects() *server.SharedGameObjects{
	return c.hub.SharedGameObjects
}

