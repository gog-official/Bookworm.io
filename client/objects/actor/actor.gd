extends Area2D

const packets := preload("res://packets.gd")
const Scene := preload("res://objects/actor/actor.tscn")
const Actor := preload("res://objects/actor/actor.gd")

var actor_id: int
var actor_name: String
var start_x: float
var start_y: float
var start_rad: float
var speed: float
var is_player: bool
var color: Color

var _target_zoom := 2.0
var _furthest_zoom_allowed := _target_zoom
var server_position: Vector2
var velocity: Vector2
var radius: float:
	set(new_radius):
		radius = new_radius
		_collision_shape.set_radius(radius)
		_update_zoom()
		queue_redraw()

@onready var _nameplate: Label = $Label
@onready var _cam: Camera2D = $Camera2D
@onready var _collision_shape: CircleShape2D = $CollisionShape2D.shape


static func instantiate(
	actor_id: int,
	actor_name: String,
	x: float,
	y: float,
	radius: float,
	speed: float,
	is_player: bool,
	color: Color
) -> Actor:
	var actor := Scene.instantiate()
	actor.actor_id = actor_id
	actor.actor_name = actor_name
	actor.start_x = x
	actor.start_y = y
	actor.start_rad = radius
	actor.speed = speed
	actor.is_player = is_player
	actor.color = color

	return actor


# Called when t he node enters the scene tree for the first time.
func _ready() -> void:
	_cam.enabled = is_player
	position.x = start_x
	position.y = start_y
	server_position = position
	velocity = Vector2.RIGHT * speed
	radius = start_rad

	_collision_shape.radius = radius
	_nameplate.text = actor_name


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	position += velocity * delta
	server_position += velocity * delta
	position += (server_position - position) * 0.5

	if not is_player:
		return

	var mouse_pos := get_global_mouse_position()

	var input_vec = position.direction_to(mouse_pos).normalized()
	if abs(velocity.angle_to(input_vec)) > TAU / 15:
		velocity = input_vec * speed
		var packet := packets.Packet.new()
		var player_direction_message := packet.new_player_direction()
		player_direction_message.set_direction(velocity.angle())
		WsClient.send(packet)


func _draw() -> void:
	draw_circle(Vector2.ZERO, _collision_shape.radius, color)


func _input(event):
	if is_player and event is InputEventMouseButton and event.is_pressed():
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_target_zoom = min(4, _target_zoom + 0.1)
			MOUSE_BUTTON_WHEEL_DOWN:
				_target_zoom = max(_furthest_zoom_allowed, _target_zoom - 0.1)


func _update_zoom() -> void:
	if is_node_ready():
		_nameplate.add_theme_font_size_override("font_size", max(16, radius / 2))
	if not is_player:
		return

	var new_furthest_zoom_allowed := 2 * start_rad / radius
	if is_equal_approx(_target_zoom, _furthest_zoom_allowed):
		_target_zoom = new_furthest_zoom_allowed
	_furthest_zoom_allowed = new_furthest_zoom_allowed


func _process(_delta: float) -> void:
	if not is_equal_approx(_cam.zoom.x, _target_zoom):
		_cam.zoom -= Vector2(1, 1) * (_cam.zoom.x - _target_zoom) * 0.05
