package server

import (
	"log"
	"net/http"
	_package "server/pkg/package"
)

type ClientInterfacer interface {
	Id() uint64
	ProcessMessage(senderId uint64, message _package.Msg)

	Initialize(id uint64)

	SocketSend(message _package.Msg)

	SocketSendAs(message _package.Msg, senderId uint64)

	PassToPeer(message _package.Msg, peerId uint64)

	Broadcasr(message _package.Msg)

	ReadPump()

	WritePump()

	Close(reason string)
}

type Hub struct {
	Client         map[uint64]ClientInterfacer
	BroadcastChan  chan _package.Packet
	RegisterChan   chan ClientInterfacer
	UnregisterChan chan ClientInterfacer
}

func NewHub() *Hub {
	return &Hub{
		Client:         make(map[uint64]ClientInterfacer),
		BroadcastChan:  make(chan _package.Packet),
		RegisterChan:   make(chan ClientInterfacer),
		UnregisterChan: make(chan ClientInterfacer),
	}
}

func (h *Hub) Run() {
	log.Println("Awating client registrations")
	for {
		select {
		case client := <-h.RegisterChan:
			client.Initialize(uint64(len(h.Client)))
		case client := <-h.UnregisterChan:
			h.Client[client.Id()] = nil
		case packet := <-h.BroadcastChan:
			for id, client := range h.Client {
				if id != packet.SenderId {
					client.ProcessMessage(packet.SenderId, packet.Msg)
				}
			}
		}
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
