class_name Minimap
extends Control

const DOT_RADIUS := 3.0
const LOCAL_DOT_RADIUS := 5.0
const PADDING := 6.0

const RADAR_ZOOM_RADIUS := 1500.0

var _local_position := Vector2.ZERO
var _players: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func setup(players: Dictionary) -> void:
	_players = players


func set_local_position(pos: Vector2) -> void:
	_local_position = pos


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var map_radius := minf(size.x, size.y) * 0.5 - PADDING

	draw_circle(center, map_radius, Color(0.08, 0.08, 0.12, 0.35))
	draw_arc(center, map_radius, 0.0, TAU, 64, Color(1, 1, 1, 0.2), 1.5)

	var scale_factor := map_radius / RADAR_ZOOM_RADIUS

	for id in _players.keys():
		var actor: Node2D = _players[id]
		if not is_instance_valid(actor):
			continue

		if id == GameManager.client_id:
			draw_circle(center, LOCAL_DOT_RADIUS, Color.WHITE)
			draw_arc(center, LOCAL_DOT_RADIUS + 3.0, 0.0, TAU, 16, Color(1, 1, 1, 0.5), 1.0)
			continue

		var offset := (actor.position - _local_position) * scale_factor

		if offset.length() > map_radius - DOT_RADIUS:
			offset = offset.normalized() * (map_radius - DOT_RADIUS)

		draw_circle(center + offset, DOT_RADIUS, actor.color)
