package states

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"unicode"

	"golang.org/x/crypto/bcrypt"
	"server/internal/server"
	"server/internal/server/db"
	"server/internal/server/objects"
	"server/pkg/packets"
)

type Connected struct {
	client  server.ClientInterfacer
	logger  *log.Logger
	queries *db.Queries
	dbCtx   context.Context
}

const MinUsernameLength = 3
const MaxUsernameLength = 20
const MinPasswordLength = 8
const MaxPasswordLength = 72

func (c *Connected) Name() string {
	return "Connected"
}
func (c *Connected) SetClient(client server.ClientInterfacer) {
	c.client = client
	loggingPrefix := fmt.Sprintf("Client %d [%s]: ", client.Id(), c.Name())
	c.logger = log.New(log.Writer(), loggingPrefix, log.LstdFlags)
	c.queries = client.DbTx().Queries
	c.dbCtx = client.DbTx().Ctx
}
func (c *Connected) OnEnter() {
	c.client.SocketSend(packets.NewId(c.client.Id()))
}

func (c *Connected) HandleMessage(senderId uint64, message packets.Msg) {
	switch message := message.(type) {
	case *packets.Packet_LoginRequest:
		c.handleLoginRequest(senderId, message)
	case *packets.Packet_RegisterRequest:
		c.handleRegisterRequest(senderId, message)
	case *packets.Packet_HiscoreBoardRequest:
		c.handleHiscoreBoardRequest(senderId, message)
	}
}

func (c *Connected) handleLoginRequest(senderId uint64, message *packets.Packet_LoginRequest) {
	if senderId != c.client.Id() {
		c.logger.Printf("Received login message from another client (Id %d)", senderId)
		return
	}
	username := message.LoginRequest.Username
	genericFailMessage := packets.NewDenyResponse("Incorrect username or password")
	user, err := c.queries.GetUserByUsername(c.dbCtx, strings.ToLower(username))
	if err != nil {
		c.logger.Printf("Error getting user %s: %v", username, err)
		c.client.SocketSend(genericFailMessage)
		return
	}

	err = bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(message.LoginRequest.Password))
	if err != nil {
		c.logger.Printf("User entered wrong password: %s", username)
		c.client.SocketSend(genericFailMessage)
		return
	}
	c.logger.Printf("User %s logged in successfully", username)

	c.client.SocketSend(packets.NewOkResponse())
	player, err := c.queries.GetPlayerByUserID(c.dbCtx, user.ID)

	if err != nil {
		c.logger.Printf("error getting player %s: %v", username, err)
		c.client.SocketSend(genericFailMessage)
		return
	}

	c.client.SetState(&InGame{
		player: &objects.Player{
			Name:      player.Name,
			DbId:      player.ID,
			BestScore: player.BestScore,
			Color:     int32(player.Color),
		},
	})
}

func (c *Connected) handleRegisterRequest(senderId uint64, message *packets.Packet_RegisterRequest) {
	if senderId != c.client.Id() {
		c.logger.Printf("Received registered message from another client (Id %d)", senderId)
		return
	}
	
	username := strings.ToLower(message.RegisterRequest.Username)
	password := message.RegisterRequest.Password

	if err := validateUsername(message.RegisterRequest.Username); err != nil {
		reason := fmt.Sprintf("Invalid username: %v", err)
		c.logger.Println(reason)
		c.client.SocketSend(packets.NewDenyResponse(reason))
		return
	}

	if err := validatePassword(password); err != nil {
		reason := fmt.Sprintf("Invalid password: %v", err)
		c.logger.Println(reason)
		c.client.SocketSend(packets.NewDenyResponse(reason))
		return
	}

	_, err := c.queries.GetUserByUsername(c.dbCtx, username)
	if err == nil {
		c.logger.Printf("Username %s already exists", username)
		c.client.SocketSend(packets.NewDenyResponse("User already Exists"))
		return
	}

	genericFailMessage := packets.NewDenyResponse("Error registering user (internal server error) - please try again later")

	passwordHash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		c.logger.Printf("Failed to hash password: %s", username)
		c.client.SocketSend(genericFailMessage)
		return
	}

	user, err := c.queries.CreateUser(c.dbCtx, db.CreateUserParams{
		Username:     username,
		PasswordHash: string(passwordHash),
	})

	if err != nil {
		c.logger.Printf("Failed to create user %s: %v", username, err)
		c.client.SocketSend(genericFailMessage)
		return
	}

	_, err = c.queries.CreatePlayer(c.dbCtx, db.CreatePlayerParams{
		UserID: user.ID,
		Name:   username, // Explicitly lowercase everywhere to match the user table
		Color:  int64(message.RegisterRequest.Color),
	})

	if err != nil {
		c.logger.Printf("Failed to create player %s: %v", username, err)
		c.client.SocketSend(genericFailMessage)
		return
	}
	c.client.SocketSend(packets.NewOkResponse())
	c.logger.Printf("User %s registered successfully", username)
}

func validateUsername(username string) error {
	if len(username) < MinUsernameLength {
		return fmt.Errorf("must be at least %d characters", MinUsernameLength)
	}
	if len(username) > MaxUsernameLength {
		return fmt.Errorf("must be at most %d characters", MaxUsernameLength)
	}
	if username != strings.TrimSpace(username) {
		return errors.New("leading or trailing whitespaces")
	}
	for _, r := range username {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_' && r != '-' {
			return errors.New("may only contain letters, numbers, underscores and dashes")
		}
	}
	return nil
}

func validatePassword(password string) error {
	if len(password) < MinPasswordLength {
		return fmt.Errorf("must be at least %d characters", MinPasswordLength)
	}
	if len(password) > MaxPasswordLength {
		return fmt.Errorf("must be at most %d characters", MaxPasswordLength)
	}
	return nil
}

func (c *Connected) handleHiscoreBoardRequest(senderId uint64, _ *packets.Packet_HiscoreBoardRequest) {
	c.client.SetState(&BrowsingHiscores{})
}
func (c *Connected) OnExit() {}
