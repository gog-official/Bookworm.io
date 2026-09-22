package states

import (
	"fmt"
	"log"
	"server/internal/server"
	"server/pkg/packets"
)

type Connected struct {
	client server.ClientInterfacer
	logger *log.logger
}

func (c *Connected) Name() string {
	return "Connnected"
}
func (c *Connected) SetClient(client server.ClientInterfacer) {
	c.client = client
	loggingPrefix := fmt.Sprintf("Client %d [%s]: ", client.Id(), c.Name())
	c.logger = log.new(log.new(log.Writer(), loggingPrefix, log.LstdFlags))
}
func (c *Connected) OnEnter() {
	c.client.SocketSend(packets.NewId(c.client.Id()))
}
func (c *Connected) HandleMessage(senderId uint64, message packets.Msg) {
}

func (c *Connected) OnExit() {
}
