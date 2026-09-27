package states

import (
	"context"
	"fmt"
	"log"
	"math"
	"math/rand"
	"server/internal/server"
	"server/internal/server/db"
	"server/internal/server/objects"
	"server/pkg/packets"
	"sync"
	"time"
)

type InGame struct {
	client                 server.ClientInterfacer
	player                 *objects.Player
	logger                 *log.Logger
	cancelPlayerUpdateLoop context.CancelFunc
	// OnExit now also runs from the websocket teardown path, so it has to be safe to
	// reach more than once.
	exitOnce sync.Once
}

// How long a freshly spawned snake is immune to death reports. Matches the client's
// own spawn protection so neither side decides a collision the other one ignores.
const SpawnGrace = 1500 * time.Millisecond

func (g *InGame) Name() string {
	return "InGame"
}

func (g *InGame) SetClient(client server.ClientInterfacer) {
	g.client = client
	loggingPrefix := fmt.Sprintf("Client %d [%s]: ", client.Id(), g.Name())
	g.logger = log.New(log.Writer(), loggingPrefix, log.LstdFlags)
}

func (g *InGame) OnEnter() {
	g.logger.Printf("Adding player %s to the shared collection", g.player.Name)
	go g.client.SharedGameObjects().Players.Add(g.player, g.client.Id())

	g.player.Speed = 200.0
	g.player.Radius = 20.0
	g.player.SpawnedAt = time.Now()
	g.player.X, g.player.Y = objects.SpawnCoords(g.player.Radius, g.client.SharedGameObjects().Players, nil)
	g.client.SocketSend(packets.NewPlayer(g.client.Id(), g.player))
	go func() {
		g.client.SharedGameObjects().Spores.ForEach(func(sporeId uint64, spore *objects.Spore) {
			time.Sleep(5 * time.Millisecond)
			g.client.SocketSend(packets.NewSpore(sporeId, spore))
		})
	}()
}

func (g *InGame) syncPlayer(delta float64) {
	newX := g.player.X + g.player.Speed*math.Cos(g.player.Direction)*delta
	newY := g.player.Y + g.player.Speed*math.Sin(g.player.Direction)*delta
	g.player.X = newX
	g.player.Y = newY
	probability := g.player.Radius / float64(server.MaxSpores*5)
    if rand.Float64() < probability && g.player.Radius > 10 {
        spore := &objects.Spore{
            X:      g.player.X,
            Y:      g.player.Y,
            Radius: min(5+g.player.Radius/50, 15),
			DroppedBy: g.player,
			DroppedAt: time.Now(),
        }
        sporeId := g.client.SharedGameObjects().Spores.Add(spore)
        g.client.Broadcast(packets.NewSpore(sporeId, spore))
        go g.client.SocketSend(packets.NewSpore(sporeId, spore))
        g.player.Radius = g.nextRadius(-radToMass(spore.Radius))
    }

	updatePacket := packets.NewPlayer(g.client.Id(), g.player)
	g.client.Broadcast(updatePacket)
	go g.client.SocketSend(updatePacket)
}

func (g *InGame) HandleMessage(senderId uint64, message packets.Msg) {
	switch message := message.(type) {
	case *packets.Packet_Player:
		g.handlePlayer(senderId, message)
	case *packets.Packet_PlayerDirection:
		g.handlePlayerDirection(senderId, message)
	case *packets.Packet_Chat:
		g.handleChat(senderId, message)
	case *packets.Packet_SporeConsumed:
		g.handleSporeConsumed(senderId, message)
	case *packets.Packet_PlayerConsumed:
		g.handlePlayerConsumed(senderId, message)
	case *packets.Packet_Spore:
		g.handleSpore(senderId, message)
		if senderId == g.client.Id() {
			g.client.Broadcast(message)
		} else {
			g.client.SocketSendAs(message, senderId)
		}
	case *packets.Packet_Disconnect:
		g.handleDisconnect(senderId, message)
	}
}

func (g *InGame) handleDisconnect(senderId uint64, message *packets.Packet_Disconnect){
	if senderId == g.client.Id(){
		g.client.Broadcast(message)
		g.client.SetState(&Connected{})		
	}else{
		go g.client.SocketSendAs(message, senderId)
	}
}


func (g *InGame) handlePlayer(senderId uint64, message *packets.Packet_Player) {
	if senderId == g.client.Id() {
		g.logger.Println("Received player message from our own client, ignoring")
		return
	}
	g.client.SocketSendAs(message, senderId)
}


func (g *InGame) handleChat(senderId uint64, message *packets.Packet_Chat) {
	if senderId == g.client.Id() {
		g.client.Broadcast(message)
	} else {
		g.client.SocketSendAs(message, senderId)
	}
}


func (g *InGame) handleSpore(senderId uint64, message *packets.Packet_Spore) {
	g.client.SocketSendAs(message, senderId)
}


func (g *InGame) playerUpdateLoop(ctx context.Context) {
	const delta float64 = 0.05
	ticker := time.NewTicker(time.Duration(delta*1000) * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			g.syncPlayer(delta)
		case <-ctx.Done():
			return
		}
	}
}

func (g *InGame) handlePlayerDirection(senderId uint64, message *packets.Packet_PlayerDirection) {
	if senderId == g.client.Id() {
		g.player.Direction = message.PlayerDirection.Direction

		if g.cancelPlayerUpdateLoop == nil {
			ctx, cancel := context.WithCancel(context.Background())
			g.cancelPlayerUpdateLoop = cancel
			go g.playerUpdateLoop(ctx)
		}
	}
}

func (g *InGame) handleSporeConsumed(senderId uint64, message *packets.Packet_SporeConsumed) {
	if senderId != g.client.Id() {
		g.client.SocketSendAs(message, senderId)
		return
	}
	errMsg := "could not verify spore coonsumption: "

	sporeId := message.SporeConsumed.SporeId
	spore, err := g.getSpore(sporeId)
	if err != nil {
		g.logger.Println(errMsg + err.Error())
		return
	}

	err = g.validatePlayerCloseToObject(spore.X, spore.Y, spore.Radius, 70)
	if err != nil {
		g.logger.Println(errMsg + err.Error())
		return
	}
	err = g.validatePlayerDropCooldown(spore, 10)
	if err != nil {
		g.logger.Println(errMsg + err.Error())
		return
	}

	sporeMass := radToMass(spore.Radius)
	g.player.Radius = g.nextRadius(sporeMass)

	go g.client.SharedGameObjects().Spores.Remove(sporeId)
	newSporeRadius := max(rand.NormFloat64()*3+10, 5)
	newX, newY := objects.SpawnNear(g.player.X, g.player.Y, 900)
	newSpore := &objects.Spore{
		X:      newX,
		Y:      newY,
		Radius: newSporeRadius,
	}
	newSporeId := g.client.SharedGameObjects().Spores.Add(newSpore)
	g.client.SocketSend(packets.NewSpore(newSporeId, newSpore))
	g.client.Broadcast(message)
	go g.syncPlayerBestScore()
}
func (g *InGame) validatePlayerDropCooldown(spore *objects.Spore, buffer float64) error{
	minAcceptableDistance := spore.Radius + g.player.Radius - buffer
    minAcceptableTime := time.Duration(minAcceptableDistance/g.player.Speed*1000) * time.Millisecond
    if spore.DroppedBy == g.player && time.Since(spore.DroppedAt) < minAcceptableTime {
        return fmt.Errorf("player dropped the spore too recently (time since drop: %v, min acceptable time: %v)", time.Since(spore.DroppedAt), minAcceptableTime)
    }
    return nil
}
func (g *InGame) getSpore(sporeId uint64) (*objects.Spore, error) {
	spore, exists := g.client.SharedGameObjects().Spores.Get(sporeId)
	if !exists {
		return nil, fmt.Errorf("spore %d not found", sporeId)
	}
	return spore, nil
}

func (g *InGame) validatePlayerCloseToObject(objX, objY, objRadius, buffer float64) error {
	realDX := g.player.X - objX
	realDY := g.player.Y - objY
	realDistSq := realDX*realDX + realDY*realDY

	thresholdDist := g.player.Radius + buffer + objRadius
	thresholdDistSq := thresholdDist * thresholdDist

	if realDistSq > thresholdDistSq {
		return fmt.Errorf("player is too far from the object(distSq: %f, thresholdSq: %f)", realDistSq, thresholdDistSq)
	}
	return nil

}
func radToMass(radius float64) float64 {
	return math.Pi * radius * radius
}

func massToRad(mass float64) float64 {
	return math.Sqrt(mass / math.Pi)
}

func (g *InGame) nextRadius(massDiff float64) float64 {
	oldMass := radToMass(g.player.Radius)
	newMass := oldMass + massDiff
	return massToRad(newMass)
}

// Slither.io has no size rule and the head is the lethal part: a snake dies by
// putting its own head into somebody, no matter how much bigger it is. The reporter
// is the client that ran the check, and the named player is the victim, so the
// victim is usually the reporter themselves.
//
// Self-reports are safe to trust even though the geometry is client-side, because
// the only thing a client can gain by lying about its own death is its own death.
// The head-to-body geometry is worked out on the client against the body it drew.
func (g *InGame) handlePlayerConsumed(senderId uint64, message *packets.Packet_PlayerConsumed) {
	victimId := message.PlayerConsumed.PlayerId

	if senderId != g.client.Id() {
		g.client.SocketSendAs(message, senderId)

		if victimId == g.client.Id() {
			g.logger.Println("player was consumed, dropping books and respawning")
			g.dropAllMass()
			g.respawnPlayer()
		}
		return
	}

	if time.Since(g.player.SpawnedAt) < SpawnGrace {
		return
	}

	if victimId == g.client.Id() {
		// We ran our own head into them. Tell everyone so our actor is removed and our
		// remains show up, then take the mass hit and come back.
		g.dropAllMass()
		g.client.Broadcast(message)
		g.respawnPlayer()
		return
	}

	victim, err := g.getOtherPlayer(victimId)
	if err != nil {
		// Already dead and gone from the collection. A duplicate report arriving late
		// must not kill a replacement snake, so stale reports are simply dropped.
		return
	}
	if time.Since(victim.SpawnedAt) < SpawnGrace {
		return
	}

	// Their head was inside our body, so they are the ones who die. We gain nothing:
	// like slither, the mass goes on the ground as orbs that anyone at all may scoop
	// up, and the victim drops it when it hears the broadcast.
	g.client.Broadcast(message)
}

// Respawning used to build a brand new player from the name alone, which silently
// threw away the colour and the database id, so the snake lost its colour and its
// best score stopped saving after the first death.
func (g *InGame) respawnPlayer() {
	g.client.SetState(&InGame{
		player: &objects.Player{
			Name:      g.player.Name,
			DbId:      g.player.DbId,
			BestScore: g.player.BestScore,
			Color:     g.player.Color,
		},
	})
}

func (g *InGame) getOtherPlayer(otherId uint64) (*objects.Player, error) {
	other, exists := g.client.SharedGameObjects().Players.Get(otherId)
	if !exists {
		return nil, fmt.Errorf("player %d not found", otherId)
	}
	return other, nil
}

func (g *InGame) syncPlayerBestScore() {
	currentScore := int64(math.Round(radToMass(g.player.Radius)))
	if currentScore > g.player.BestScore {
		g.player.BestScore = currentScore
		err := g.client.DbTx().Queries.UpdatePlayerBestScore(g.client.DbTx().Ctx, db.UpdatePlayerBestScoreParams{
			ID:        g.player.DbId,
			BestScore: g.player.BestScore,
		})
		if err != nil {
			g.logger.Printf("Error updating player best score: %v", err)
		}
	}
}

func (g *InGame) OnExit() {
	g.exitOnce.Do(func() {
		if g.cancelPlayerUpdateLoop != nil {
			g.cancelPlayerUpdateLoop()
		}
		g.client.SharedGameObjects().Players.Remove(g.client.Id())
		go g.syncPlayerBestScore()
	})
}

func (g *InGame) dropAllMass() {
	mass := radToMass(g.player.Radius)
	count := min(max(int(mass/40), 3), 60)
	for i := 0; i < count; i++ {
		x, y := objects.SpawnNear(g.player.X, g.player.Y, 150)
		book := &objects.Spore{X: x, Y: y, Radius: 8}
		bookId := g.client.SharedGameObjects().Spores.Add(book)
		// Broadcast skips the sender, so the dead snake has to be told separately or
		// its own remains never appear on its screen.
		sporePacket := packets.NewSpore(bookId, book)
		go g.client.SocketSend(sporePacket)
		g.client.Broadcast(sporePacket)
	}
}
