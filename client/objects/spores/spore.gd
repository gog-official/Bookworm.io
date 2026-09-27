extends Area2D

const Scene := preload("res://objects/spores/spore.tscn")
const Spore := preload("res://objects/spores/spore.gd")
const Actor := preload("res://objects/actor/actor.gd")
const BACK := preload("res://resources/book_back.svg")
const COVER := preload("res://resources/book_cover.svg")
const PAGES := preload("res://resources/book_pages.svg")
const SETTLE_MS := 600
var spore_id: int
var x: float
var y: float
var rad: float
var color: Color
var underneath_player: bool
var _attracted_to: Node2D = null
var _pull_speed := 0.0
var spawned_at_ms := 0
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
	spawned_at_ms = Time.get_ticks_msec()
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
	var size := rad * 2.1
	var rect := Rect2(-size * 0.5, -size * 0.5, size, size)
	draw_texture_rect(BACK, rect, false, color.lightened(0.35))
	draw_texture_rect(PAGES, rect, false)
	draw_texture_rect(COVER, rect, false, color.lightened(0.35))


func attract_to(target: Node2D, speed: float) -> void:
	_attracted_to = target
	_pull_speed = speed
	set_process(true)


func release() -> void:
	_attracted_to = null
	set_process(false)


func _process(delta: float) -> void:
	if _attracted_to == null or not is_instance_valid(_attracted_to):
		release()
		return

	var to_target := _attracted_to.position - position
	if to_target.length() < 2.0:
		release()
		return

	position += to_target.normalized() * _pull_speed * delta


func is_settling() -> bool:
	return Time.get_ticks_msec() - spawned_at_ms < SETTLE_MS
