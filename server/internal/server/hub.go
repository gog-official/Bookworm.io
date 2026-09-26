package server


import (
	"log"
	"net/http"
	"server/internal/server/objects"
	"server/pkg/packets"
	"time"

	"context"
	_ "embed"
	"server/internal/server/db"

	"database/sql"
	"math/rand/v2"

	_ "modernc.org/sqlite"
)
//go:embed db/config/schema.sql
var schemaGenSql string
const MaxSpores int = 1000

type ClientInterfacer interface {
	Id() uint64
	ProcessMessage(senderId uint64, message packets.Msg)

	Initialize(id uint64)

	SocketSend(message packets.Msg)

	SocketSendAs(message packets.Msg, senderId uint64)

	PassToPeer(message packets.Msg, peerId uint64)

	Broadcast(message packets.Msg)

	SetState(newState ClientStateHandler)

	DbTx() *DbTx

	SharedGameObjects() *SharedGameObjects

	ReadPump()

	WritePump()

	Close(reason string)
}
type SharedGameObjects struct {
	Players *objects.SharedCollection[*objects.Player]
	Spores *objects.SharedCollection[*objects.Spore]
}

type Hub struct {
	Clients        *objects.SharedCollection[ClientInterfacer]
	BroadcastChan  chan *packets.Packet
	RegisterChan   chan ClientInterfacer
	UnregisterChan chan ClientInterfacer
	dbPool         *sql.DB
	SharedGameObjects *SharedGameObjects

}

type ClientStateHandler interface {
	Name() string
	SetClient(clint ClientInterfacer)
	OnEnter()
	HandleMessage(senderId uint64, message packets.Msg)
	OnExit()
}

func NewHub() *Hub {
	dbPool, err := sql.Open("sqlite", "db.sqlite")
	if err != nil {
		log.Fatal(err)
	}
	return &Hub{
		Clients:        objects.NewSharedCollection[ClientInterfacer](),
		BroadcastChan:  make(chan *packets.Packet),
		RegisterChan:   make(chan ClientInterfacer),
		UnregisterChan: make(chan ClientInterfacer),
		dbPool:         dbPool,
		SharedGameObjects: &SharedGameObjects{
			Players: objects.NewSharedCollection[*objects.Player](),
			Spores: objects.NewSharedCollection[*objects.Spore](),
		},
	}
}

type DbTx struct {
	Ctx     context.Context
	Queries *db.Queries
}

func (h *Hub) NewDbTx() *DbTx {
	return &DbTx{
		Ctx:     context.Background(),
		Queries: db.New(h.dbPool),
	}
}

func (h *Hub) Run() {
	log.Println("Initializing database...")
	
	log.Println("Placing spores....")
	for i:=0; i<MaxSpores; i++{
		h.SharedGameObjects.Spores.Add(h.newSpore())
	}
	log.Println("Awating client registrations")
	
	if _, err := h.dbPool.ExecContext(context.Background(), schemaGenSql); err != nil {
		log.Fatal(err)
	}
	for {
		select {
		case client := <-h.RegisterChan:
			client.Initialize(h.Clients.Add(client))
		case client := <-h.UnregisterChan:
			h.Clients.Remove(client.Id())
		case packet := <-h.BroadcastChan:
			h.Clients.ForEach(func(clientId uint64, client ClientInterfacer) {
				if clientId != packet.SenderId {
					client.ProcessMessage(packet.SenderId, packet.Msg)
				}
			})
		}
	}
	go h.replenishSporesLoop(2 * time.Second)
}
func (h *Hub) newSpore() *objects.Spore{
	sporeRadius := max(rand.NormFloat64()*3+10, 5)
	x, y := objects.SpawnCoords(sporeRadius, h.SharedGameObjects.Players, h.SharedGameObjects.Spores)
	return &objects.Spore{
		X: x, 
		Y: y, 
		Radius: sporeRadius,
	}
	
}

func (h *Hub) Serve(getNewClient func(*Hub, http.ResponseWriter, *http.Request) (ClientInterfacer, error), writer http.ResponseWriter, request *http.Request) {
	log.Println("New client connected from", request.RemoteAddr)
	client, err := getNewClient(h, writer, request)

	if err != nil {
		log.Printf("Error obtaining client for new connection %v", err)
		return
	}
	h.RegisterChan <- client

	go client.WritePump()
	go client.ReadPump()
}

func (h *Hub) replenishSporesLoop(rate time.Duration){
	ticker := time.NewTicker(rate)
	defer ticker.Stop()
	
	for range ticker.C {
		sporesRemaining := h.SharedGameObjects.Spores.Len()
		diff := MaxSpores - sporesRemaining

		if diff > 0 {
			continue
		}

		log.Printf("%d spores remain - going to replenish %d spores", sporesRemaining, diff)

		for i := 0; i<min(diff, 10); i++{
			spore := h.newSpore()
			sporeId := h.SharedGameObjects.Spores.Add(spore)

			h.BroadcastChan <- &packets.Packet{
				SenderId: 0,
				Msg: packets.NewSpore(sporeId, spore),
			}

			time.Sleep(50 * time.Millisecond)
		}
	}
}