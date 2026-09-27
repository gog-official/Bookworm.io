extends Node

const packets := preload("res://packets.gd")
const Actor := preload("res://objects/actor/actor.gd")
const Spore := preload("res://objects/spores/spore.gd")

var _players: Dictionary[int, Actor]
var _spores: Dictionary[int, Spore]
# Seconds of immunity after (re)spawning, so you cannot die inside a snake you were
# just placed on top of.
var _spawn_protection := SPAWN_PROTECTION
# victim id -> time we last reported it, so a single collision is not resent every
# frame while the server catches up.
var _reported_deaths: Dictionary[int, float] = {}
# Set when the server tells us we died, so the next position we hear about is a
# respawn rather than ordinary movement.
var _awaiting_respawn := false

# Slither kills on contact. The reach is the two drawn widths that actually touch,
# so a fat snake is not any easier to slip past and a thin one is not a free pass.
const SNAKE_HIT_REACH_RATIO := 1.0
# Point 0 is the head and point 1 sits one spacing behind it; both are still head,
# and head-to-head is handled separately as a mutual kill.
const SNAKE_BODY_START_INDEX := 2
const SPAWN_PROTECTION := 1.5
const DEATH_REPORT_COOLDOWN := 2.0

@onready var _logout_button: Button = $UI/MarginContainer/VBoxContainer/HBoxContainer/Logout
@onready var _line_edit: LineEdit = $UI/MarginContainer/VBoxContainer/HBoxContainer/LineEdit
@onready var _send_button: Button = $UI/MarginContainer/VBoxContainer/HBoxContainer/Send
@onready var _log: Log = $UI/MarginContainer/VBoxContainer/Log
@onready var _hiscores: Hiscores = $UI/MarginContainer/VBoxContainer/Hiscores
@onready var _world: Node2D = $World
@onready var _minimap: Minimap = $UI/Minimap


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_line_edit.text_submitted.connect(_on_line_edit_text_submitted)
	WsClient.connection_closed.connect(_on_ws_connection_closed)
	WsClient.packet_received.connect(_on_ws_packet_recieved)
	_logout_button.pressed.connect(_on_logout_button_pressed)
	_send_button.pressed.connect(_on_send_button_pressed)
	_minimap.setup(_players)


func _on_logout_button_pressed() -> void:
	var packet := packets.Packet.new()
	var disconnect_msg := packet.new_disconnect()
	disconnect_msg.set_reason("logged out")
	WsClient.send(packet)
	GameManager.set_state(GameManager.State.CONNECTED)


func _on_send_button_pressed() -> void:
	_on_line_edit_text_submitted(_line_edit.text)


func _on_ws_connection_closed() -> void:
	_log.error("Connection closed")


func _on_ws_packet_recieved(packet: packets.Packet) -> void:
	var sender_id := packet.get_sender_id()
	if packet.has_chat():
		_handle_chat_msg(sender_id, packet.get_chat())
	elif packet.has_player():
		_handle_player_msg(sender_id, packet.get_player())
	elif packet.has_spore():
		_handle_spore_msg(sender_id, packet.get_spore())
	elif packet.has_spore_consumed():
		_handle_spore_consumed_msg(sender_id, packet.get_spore_consumed())
	elif packet.has_disconnect():
		_handle_disconnect_msg(sender_id, packet.get_disconnect())
	elif packet.has_player_consumed():
		_handle_player_consumed_msg(sender_id, packet.get_player_consumed())


func _handle_player_consumed_msg(_sender_id: int, msg: packets.PlayerConsumedMessage) -> void:
	var victim_id := msg.get_player_id()
	if victim_id == GameManager.client_id:
		# Somebody ran into us. The server drops our mass and teleports us to a fresh
		# spawn, which arrives as the next Player message; arm the grace period now so
		# the corpse cannot report a kill on the way out.
		_arm_local_death()
	elif victim_id in _players:
		_remove_actor(_players[victim_id])


func _handle_disconnect_msg(sender_id: int, disconnect_msg: packets.DisconnectMessage) -> void:
	if sender_id in _players:
		var player := _players[sender_id]
		var reason := disconnect_msg.get_reason()
		_log.info("%s disconnected because %s" % [player.actor_name, reason])
		_remove_actor(player)


func _handle_spore_consumed_msg(
	sender_id: int, spore_consumed_msg: packets.SporeConsumedMessage
) -> void:
	if sender_id in _players:
		var actor := _players[sender_id]
		var actor_mass := _radius_to_mass(actor.radius)

		var spore_id := spore_consumed_msg.get_spore_id()
		if spore_id in _spores:
			var spore := _spores[spore_id]
			var spore_massss := _radius_to_mass(spore.rad)
			_set_actor_mass(actor, actor_mass + spore_massss)
			_remove_spore(spore)


func _radius_to_mass(r: float) -> float:
	return r * r * PI


func _set_actor_mass(actor: Actor, new_mass: float) -> void:
	actor.radius = sqrt(new_mass / PI)
	_hiscores.set_hiscore(actor.actor_name, roundi(new_mass))


func _handle_chat_msg(sender_id: int, chat_msg: packets.ChatMessage) -> void:
	if sender_id in _players:
		var actor := _players[sender_id]
		_log.chat(actor.actor_name, chat_msg.get_msg())


func _on_line_edit_text_submitted(txt: String) -> void:
	var packet := packets.Packet.new()
	var chat_msg := packet.new_chat()
	chat_msg.set_msg(txt)

	var err := WsClient.send(packet)
	if err:
		_log.error("Error  sending chat message")
	else:
		_log.chat("You", txt)
		_line_edit.text = ""


func _handle_player_msg(sender_id: int, player_msg: packets.PlayerMessage) -> void:
	var actor_id := player_msg.get_id()
	var actor_name := player_msg.get_name()
	var x := player_msg.get_x()
	var y := player_msg.get_y()
	var radius := player_msg.get_radius()
	var speed := player_msg.get_speed()
	var color_hex := player_msg.get_color()

	var color := Color.hex(color_hex)

	var is_player := actor_id == GameManager.client_id

	if actor_id not in _players:
		_add_actor(actor_id, actor_name, x, y, radius, speed, is_player, color)
	else:
		_update_actor(actor_id, x, y, radius)


func _handle_spore_msg(sender_id: int, spore_msg: packets.SporeMessage) -> void:
	var spore_id := spore_msg.get_id()
	var x := spore_msg.get_x()
	var y := spore_msg.get_y()
	var radius := spore_msg.get_radius()
	var underneath_player := false
	if GameManager.client_id in _players:
		var player := _players[GameManager.client_id]
		var player_pos := Vector2(player.position.x, player.position.y)
		var spore_pos := Vector2(x, y)
		underneath_player = (
			player_pos.distance_squared_to(spore_pos) < player.radius * player.radius
		)

	if spore_id in _spores:
		var spore := _spores[spore_id]
		spore.position = Vector2(x, y)
		spore.underneath_player = underneath_player
		return

	var spore := Spore.instantiate(spore_id, x, y, radius, underneath_player)
	_world.add_child(spore)
	_spores[spore_id] = spore


func _add_actor(
	actor_id: int,
	actor_name: String,
	x: float,
	y: float,
	radius: float,
	speed: float,
	is_player: bool,
	color: Color
) -> void:
	var actor := Actor.instantiate(actor_id, actor_name, x, y, radius, speed, is_player, color)
	_world.add_child(actor)
	actor.z_index = 1
	_set_actor_mass(actor, _radius_to_mass(radius))
	actor.push_snapshot(x, y)
	_players[actor_id] = actor

	if is_player:
		actor.area_entered.connect(_on_player_area_entered)
		actor.magnet_area_entered.connect(_on_player_magnet_area_entered)
		# Grace starts when we actually join the world, not when the scene loaded,
		# because logging in can take longer than the countdown.
		_spawn_protection = SPAWN_PROTECTION


func _update_actor(actor_id: int, x: float, y: float, radius: float) -> void:
	var actor := _players[actor_id]
	_set_actor_mass(actor, _radius_to_mass(radius))
	if _awaiting_respawn and actor_id == GameManager.client_id:
		_awaiting_respawn = false
		_reported_deaths.erase(actor_id)
		actor.respawn(x, y, radius)
		return
	# The actor buffers this and interpolates between it and the next one at
	# render time, so no snapping or extrapolation happens here.
	actor.push_snapshot(x, y)


func _on_player_area_entered(area: Area2D) -> void:
	if area is Spore:
		_consume_spore(area as Spore)


func _remove_actor(actor: Actor) -> void:
	_players.erase(actor.actor_id)
	actor.queue_free()
	_hiscores.remove_hiscore(actor.actor_name)


func _consume_spore(spore: Spore) -> void:
	if spore.underneath_player:
		return
	var player = _players[GameManager.client_id]
	if spore.is_settling():
		return
	var player_mass := _radius_to_mass(player.radius)
	var spore_mass := _radius_to_mass(spore.rad)
	_set_actor_mass(player, player_mass + spore_mass)
	var packet := packets.Packet.new()
	var spore_consumed_msg := packet.new_spore_consumed()
	spore_consumed_msg.set_spore_id(spore.spore_id)
	WsClient.send(packet)
	_remove_spore(spore)


func _remove_spore(spore: Spore) -> void:
	_spores.erase(spore.spore_id)
	spore.queue_free()


# just 4 minimap
func _process(delta: float) -> void:
	_spawn_protection = maxf(_spawn_protection - delta, 0.0)
	_check_snake_hits()
	if GameManager.client_id in _players:
		var local_player = _players[GameManager.client_id]
		if is_instance_valid(local_player):
			_minimap.set_local_position(local_player.position)


func _on_player_magnet_area_entered(area: Area2D) -> void:
	if area is Spore and GameManager.client_id in _players:
		var spore := area as Spore
		if spore.is_settling():
			return
		var player := _players[GameManager.client_id]
		spore.attract_to(player, Actor.MAGNET_PULL_SPEED)


# Slither.io kills on contact and has no size rule at all: the head is the lethal
# part, and it is the snake that owns the head which dies. So driving your own head
# into somebody kills you, and letting somebody else's head touch your body kills
# them -- a giant running into a tiny snake's tail dies just as surely.
func _check_snake_hits() -> void:
	if not (GameManager.client_id in _players):
		return
	var me := _players[GameManager.client_id]
	if not is_instance_valid(me) or _spawn_protection > 0.0:
		return

	for id in _players:
		if id == GameManager.client_id:
			continue
		var other := _players[id]
		if not is_instance_valid(other):
			continue

		var their_head_in_my_body := _head_hits_body(other, me)
		var my_head_in_their_body := _head_hits_body(me, other)
		if not (their_head_in_my_body or my_head_in_their_body):
			continue

		var head_reach := (me.radius + other.radius) * Actor.HEAD_WIDTH_SCALE
		if me.position.distance_to(other.position) < head_reach:
			# Heads met, which is neither snake's head inside a body. Slither kills
			# both, so each side reports the other and its own death.
			_report_death(other.actor_id)
			_report_death(me.actor_id)
			continue

		if their_head_in_my_body:
			_report_death(other.actor_id)
		if my_head_in_their_body:
			_report_death(me.actor_id)


# Does `attacker`'s head reach into `victim`'s body? Measured against the drawn head
# and body widths, and skipping the two points that still count as the head.
func _head_hits_body(attacker: Actor, victim: Actor) -> bool:
	var reach := attacker.radius * Actor.HEAD_WIDTH_SCALE + victim.radius * Actor.BODY_WIDTH_SCALE
	var head := attacker.position
	var count := victim.body_point_count()
	for i in range(SNAKE_BODY_START_INDEX, count - 1):
		if _point_to_segment_distance(head, victim.body_point(i), victim.body_point(i + 1)) < reach:
			return true
	return false


# Distance from a point to a segment, so a fast-moving head cannot tunnel through a
# body link by landing past it between two frames.
static func _point_to_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _report_death(victim_id: int) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var last: float = _reported_deaths.get(victim_id, -INF)
	if now - last < DEATH_REPORT_COOLDOWN:
		return
	_reported_deaths[victim_id] = now

	var packet := packets.Packet.new()
	var msg := packet.new_player_consumed()
	msg.set_player_id(victim_id)
	WsClient.send(packet)

	if victim_id == GameManager.client_id:
		# We reported our own head running into somebody, so the server is not going
		# to broadcast it back to us. Arm the death here instead of waiting.
		_arm_local_death()


func _arm_local_death() -> void:
	_spawn_protection = SPAWN_PROTECTION
	_awaiting_respawn = true
