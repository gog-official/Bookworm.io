package clients

import (
	"fmt"
	"log"
	"net/http"

	"server/internal/server"
	_package "server/pkg/package"

	"github.com/gorilla/websocket"
)

type WebSocketsClient struct {
	id       uint64
	conn     *websocket.Conn
	hub      *server.Hub
	sendChan chan _package.Packet
	logger   *log.Logger
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
	c := &WebSocketsClient{
		hub:      hub,
		conn:     conn,
		sendChan: make(chan _package.Packet, 256),
		logger:   log.New(log.Writer(), "Client unknown: ", log.LstdFlags),
	}
	return c, nil
}
func (c *WebSocketsClient) Id() uint64 {
	return c.id
}

func (c *WebSocketsClient) Initialize(id uint64) {
	c.id = id
	c.logger.SetPrefix(fmt.Sprintf("clinet %d", c.id))
}

func (c *WebSocketsClient) ProcessMessage(senderId uint64, message _package.Msg) {
}
func (c *WebSocketsClient) SocketSend(message _package.Msg) {
	c.SocketSendAs(message, c.id)
}
func (c *WebSocketsClient) SocketSendAs(message _package.Msg, senderId uint64) {
	select {
	case c.sendChan <- _package.Packet{SenderId: senderId, Msg: message}:
	default:
		c.logger.Printf("Client %d send channel full, dropping message: %T", c.id, message)
	}
}
