package clients

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"server/internal/server"
	"server/pkg/packets"
	"github.com/gorilla/websocket"
)

const teardownTimeout = 2 * time.Second

// newTestClient stands up a real websocket pair, but drains the hub channels itself
// instead of running Hub.Run, which would need the sqlite schema applied.
func newTestClient(t *testing.T) *WebSocketClient {
	t.Helper()

	hub := server.NewHub(t.TempDir())
	finished := make(chan struct{})
	var drainers sync.WaitGroup
	drainers.Add(2)
	go func() {
		defer drainers.Done()
		for {
			select {
			case <-hub.BroadcastChan:
			case <-finished:
				return
			}
		}
	}()
	go func() {
		defer drainers.Done()
		for {
			select {
			case <-hub.UnregisterChan:
			case <-finished:
				return
			}
		}
	}()

	clientCh := make(chan server.ClientInterfacer, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := NewWebSocketClient(hub, w, r)
		if err != nil {
			return
		}
		clientCh <- c
		<-finished
	}))

	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dialing test server: %v", err)
	}

	t.Cleanup(func() {
		close(finished)
		drainers.Wait()
		conn.Close()
		srv.Close()
	})

	var iface server.ClientInterfacer
	select {
	case iface = <-clientCh:
	case <-time.After(teardownTimeout):
		t.Fatal("server never handed back the client")
	}
	c := iface.(*WebSocketClient)
	c.logger = log.New(io.Discard, "", 0)
	c.Initialize(7)
	return c
}

type countingState struct {
	exits atomic.Int32
}

func (s *countingState) Name() string                   { return "Counting" }
func (s *countingState) SetClient(server.ClientInterfacer) {}
func (s *countingState) OnEnter()                       {}
func (s *countingState) HandleMessage(uint64, packets.Msg) {}
func (s *countingState) OnExit()                        { s.exits.Add(1) }

// Close used to probe the channel with a receive, which blocks forever when the
// queue is empty. A healthy client has drained everything by the time it
// disconnects, so drain the seeded packets first to reproduce that state.
func TestCloseDoesNotBlockOnEmptySendChannel(t *testing.T) {
	c := newTestClient(t)

	for len(c.sendChan) > 0 {
		<-c.sendChan
	}

	done := make(chan struct{})
	go func() {
		c.Close("test")
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(teardownTimeout):
		t.Fatal("Close blocked on the send channel")
	}
}

// Both pumps call Close on the way out, so it has to tolerate concurrent callers.
func TestCloseIsIdempotentUnderConcurrency(t *testing.T) {
	c := newTestClient(t)

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.Close("test")
		}()
	}

	finished := make(chan struct{})
	go func() {
		wg.Wait()
		close(finished)
	}()

	select {
	case <-finished:
	case <-time.After(teardownTimeout):
		t.Fatal("concurrent Close calls deadlocked")
	}
}

// The actual flood: a disconnect never reached OnExit, so the 50ms InGame update
// loop kept queueing into a socket nobody was reading until the buffer filled.
func TestCloseExitsTheCurrentState(t *testing.T) {
	c := newTestClient(t)
	state := &countingState{}
	c.SetState(state)

	c.Close("test")

	if got := state.exits.Load(); got != 1 {
		t.Fatalf("state OnExit called %d times, want 1", got)
	}
}

// Now that Close really does close the channel, a straggler sender has to be
// dropped instead of panicking the whole server.
func TestSocketSendAfterCloseIsIgnored(t *testing.T) {
	c := newTestClient(t)
	c.Close("test")

	for i := 0; i < 100; i++ {
		c.SocketSendAs(packets.NewId(1), 1)
		c.SocketSend(packets.NewDisconnect("x"))
	}
}

// A queue that fills means the peer stopped reading, so the client has to be torn
// down rather than left to log a drop forever.
func TestFullSendChannelTearsTheClientDown(t *testing.T) {
	c := newTestClient(t)

	// Nobody is draining, so this overruns the buffer and trips the drop path.
	for i := 0; i < cap(c.sendChan)+16; i++ {
		c.SocketSend(packets.NewId(1))
	}

	deadline := time.Now().Add(teardownTimeout)
	for time.Now().Before(deadline) {
		c.sendMux.RLock()
		closed := c.closed
		c.sendMux.RUnlock()
		if closed {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("client kept queueing after its send channel filled")
}

// The hub dispatches to clients on its own goroutine, so a handler that broadcasts
// while being dispatched -- a death dropping its books, a chat, a spore -- used to
// wait on the one goroutine that could unblock it. That froze broadcasts, message
// dispatch and every respawn for the whole server.
func TestBroadcastDoesNotBlockOnABusyHub(t *testing.T) {
	hub := server.NewHub(t.TempDir())

	// Nothing is draining, which is exactly the state of a hub sitting inside a
	// client handler.
	for i := 0; i < cap(hub.BroadcastChan); i++ {
		hub.BroadcastChan <- &packets.Packet{SenderId: 1, Msg: packets.NewId(1)}
	}

	c := &WebSocketClient{hub: hub, id: 1, logger: log.New(io.Discard, "", 0)}

	done := make(chan struct{})
	go func() {
		for i := 0; i < 8; i++ {
			c.Broadcast(packets.NewId(1))
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(teardownTimeout):
		t.Fatal("Broadcast blocked while the hub was busy")
	}
}
