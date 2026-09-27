# Bookworm.io
# THIS IS PROJECT BOOKWORM.IO:-->

    Its a MMO-Game based on bookworms(that's why we named it BookWorm.io).
    In the game after Log-In the player has to eat books in his worms on the game map. There is no multiple map there only a single platform where all books are been scattered out. The players spawn randomly and they have to eat book to grow larger and survive the game.The more books the worm eats the more the worm grows.

# FEATURES:-->

    - Multiplayer Online Game
    - Bookworms Based theme
    - Real-time Multiplayer Interaction
    - Chat with other players in the game-lobby
    - Game statistics and leaderboard system

# HOW TO PLAY:-->

    - Log-In to the game
    that's is then the game starts automatically.
    - Eat books to grow larger.
    - Eat small worms to grow more large.
    - Avoid big worms to survive the game.
    - See your score and rank on leaderboard.


# HOW IT WORKS:-->

The game has two main parts:

Godot → the actual game client
Golang → the multiplayer server

Godot takes care of the game itself — rendering, player input, movement and everything the player sees.

The Go server handles the multiplayer side and keeps track of what's happening in the game. The client and server communicate in real time using WebSockets.

There is also a shared folder containing the things both sides need to understand the same data and communicate with each other.

Bookworm.io
|--- client/    -> Godot game
|--- server/    -> Go multiplayer server and database (SQLite)
|--- shared/    -> Shared networking/data

The "proto" file on the 'shared' folder is like the main holder of the whole code, Without this file no other things in The code will work as it holds every imports,functions,definations,declarations etc.
We have to register every function into the '.proto' file and then use it in the code.
After writing the declaration of the function in the ".proto" file, we have to register it into the "server/" folder using this command:
```cmd
protoc -I="shared" --go_out="server" "shared/packets.proto"
```

Then it will work and also for the database we have to install it on the folder of the game using:
```cmd
go get github.com/mattn/go-sqlite3
```
After that we designed the server database and register every needed things into it make the game more effiecient,
secre and Fun to play.


# WHAT WE ARE USING:-->
    -Godot 4
For the game client and everything running on the player's side.

    -Golang 
For the multiplayer backend and game server.

    -WebSockets
For real-time communication between the clients and server.

    -SQLite
For the database to store player information and game state.

# WE have published a live version of the game on itch.io
LINK:-->

# COMMITMENTS:-->
we have used youtube for the guide and tutorial, and used AI for some database sync errors solving, some bug-solving that are hard to find in code checks but yet effecting the game,and solving some frontend and backend sync errors that were very hard to find and solve on our own.

- 
