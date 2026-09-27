package objects
import "time"
type Player struct {
	Name string
	X float64 
	Y float64
	Radius float64
	Direction float64
	Speed float64
	DbId int64
	BestScore int64
	Color int32
	// When this player entered the world. Death reports arriving inside the spawn
	// grace are ignored, otherwise a report that was already in flight when the
	// snake respawned would kill the fresh one and the two would trade deaths
	// forever.
	SpawnedAt time.Time
}
type Spore struct{
	X float64
	Y float64
	Radius float64
	DroppedBy *Player
	DroppedAt time.Time
}

