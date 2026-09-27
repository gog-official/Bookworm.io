extends Area2D

const Scene := preload("res://objects/spores/spore.tscn")
const Spore := preload("res://objects/spores/spore.gd")
const Actor := preload("res://objects/actor/actor.gd")

var spore_id: int
var x: float
var y: float
var rad: float
var color: Color
var underneath_player: bool

@onready var _collision_shape: CircleShape2D = $CollisionShape2D.shape


static func instantiate(
	spore_id: int, x: float, y: float, rad: float, underneath_player: bool
) -> Spore:
	var spore := Scene.instantiate() as Spore
	spore.spore_id = spore_id
	spore.x = x
	spore.y = y
	spore.rad = rad
	spore.underneath_player = underneath_player
	return spore


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if underneath_player:
		area_exited.connect(_on_area_exited)
	position.x = x
	position.y = y
	_collision_shape.radius = rad
	color = Color.from_hsv(randf(), 1, 1, 1)


func _on_area_exited(area: Area2D) -> void:
	if area is Actor:
		underneath_player = false


func _draw() -> void:
	draw_circle(Vector2.ZERO, rad, color)
