# Bookworm.io

A [slither.io](https://slither.io) style multiplayer online game with a Godot client and a Go server.

## Features

- User registration and login, with your own color
- Passwords hashed with bcrypt, never stored plain
- Highscores browsing and player lookup by name
- In-game multiplayer with bookworms and spores
- In-game chat
- Slither rules, a head into a body is a death and head to head kills both
- Mass drops on death and a respawn with spawn protection
- Minimap with the worms around you
- Camera that zooms out the bigger you get
- Client side interpolation so the movement is smooth
- SQLite for users, colors and best scores
- WebSocket communication
- Protobuf for packet serialization
- TLS with a `/health` endpoint for keeping the server awake
- Dockerized, with a compose file next to it

## Setup

Just copy this repo, add the necessary `.env`s and you're good to go.

### Client (Godot)

1. Install [Godot 4.7](https://godotengine.org/download)
2. Open `client/project.godot`
3. Run the project

The client points at a deployed server, `wss://bookworm-927r.onrender.com/ws`, so change
`SERVER_URL` in `client/states/entered/entered.gd` if you run your own one.

### Server (Go)

Requires [Go 1.27+](https://go.dev/dl/).

```bash
cd server
go mod tidy
go run cmd/main.go
```

### Environment

The server reads `server/.env` on start, or whatever you pass with `--config`.

| Variable    | Default | Description                                                              |
| ----------- | ------- | ------------------------------------------------------------------------ |
| `PORT`      | `8080`  | Port the server listens on                                              |
| `DATA_PATH` | —       | Where `db.sqlite` is kept, falls back to the mounted docker dir          |
| `CERT_PATH` | —       | Path to the TLS certificate, no TLS when missing                        |
| `KEY_PATH`  | —       | Path to the TLS key                                                     |

## Docker

```bash
# Build
docker build -t bookworm -f server/Dockerfile .

# Run
docker run -p 8080:8080 --env-file .env -v "$(pwd)/certs:/gameserver/certs" bookworm

# Or, with the compose file
docker compose -f server/compose.yaml up
```

The image is a distroless static build pinned to port `10000`, which is what Render wants,
and the data dir is a volume so the sqlite file survives a redeploy.

## Deployment

- Push the branch and let Render build `server/Dockerfile`
- Mount the certificate at `/gameserver/certs/live` and point `CERT_PATH` and `KEY_PATH` there
- Put your data dir on a disk, `DATA_PATH` is where the sqlite file goes
- Hit `/health` now and then, the free tier sleeps

## Project Structure

```text
client/                  Godot game client
  addons/                Custom addons (godobuf, wakatime)
  classes/               UI components (login, register, highscores, logs, minimap)
  exports/               Exported web build
  objects/               Game objects (actors, spores)
  resources/             Assets and themes
  states/                Game states (browsing, connected, entered, ingame)
server/                  Go server
  cmd/                   Main entry point
  Dockerfile             Distroless static build
  compose.yaml
  internal/server/       Server logic
    clients/             WebSocket client handling
    db/                  Sqlite queries, generated with sqlc
    objects/             Game objects and spawning
    states/              Server state machines
    hub.go
  pkg/                   Shared packages (packets)
shared/                  Shared protobuf definitions
```

## Controls

| Input              | Action                                       |
| ------------------ | -------------------------------------------- |
| Move the mouse     | Steer the worm                               |
| Scroll             | Zoom, the camera pulls back as you grow      |
| Type and hit enter | Chat                                         |
| Logout             | Drops you back to the login form             |

## Screenshots

![Screenshot 1](screenshot-2026-09-27_19-49-03.png)
![Screenshot 2](screenshot-2026-09-27_19-50-11.png)
![Screenshot 3](screenshot-2026-09-27_19-51-03.png)
![Screenshot 4](screenshot-2026-09-27_19-52-08.png)
![Screenshot 5](screenshot-2026-09-27_19-52-15.png)
