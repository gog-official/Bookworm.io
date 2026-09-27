extends Area2D

const packets := preload("res://packets.gd")
const Scene := preload("res://objects/actor/actor.tscn")
const Actor := preload("res://objects/actor/actor.gd")
const MAGNET_EXTRA_RADIUS := 60.0
const EYE_RADIUS_RATIO := 0.28
const EYE_SPREAD := 0.36
const LENS_COLOR := Color(0.88, 0.91, 0.95)
const FRAME_COLOR := Color(0.16, 0.15, 0.2)
const FRAME_RADIUS_RATIO := 1.16
const FRAME_WIDTH_RATIO := 0.13
const FRAME_ARC_SEGMENTS := 22
# Pupil travel is in eye radii, so it can never slide out of the eye.
const PUPIL_TRAVEL := 0.3
const PUPIL_RATE := 7.0
const FACE_RATE := 20.0
const SPIRAL_SPAN := 0.82
const SPIRAL_TURNS := 1.15
const SPIRAL_STEPS := 26
const SPIRAL_WIDTH := 0.34
const SPIRAL_COLOR := Color(0.09, 0.07, 0.11)
const MAGNET_PULL_SPEED := 500.0

# Server updates arrive every ~50ms. Rendering that far in the past guarantees two
# bracketing snapshots always exist, so interpolation never has to extrapolate, but
# every millisecond here is a millisecond of lag between the mouse and the snake.
# 60ms keeps us inside the 50ms server cadence with just enough room to still find a
# bracketing pair, and falls back to holding the newest snapshot rather than
# guessing when it cannot.
const INTERP_DELAY := 0.06
const MAX_SNAPSHOTS := 24

# Segment spacing is a fraction of the drawn body radius, not the collision radius.
# Tying it to the collision radius meant narrowing the body silently widened the
# gaps until the chain read as a string of separate beads. Deriving it from the
# radius we actually paint keeps the overlap ratio constant for any width scale.
const SEGMENT_SPACING_RATIO := 0.4
const MIN_SEGMENT_SPACING := 2.0
# Ignore sub-epsilon spacing errors so settled links are not rewritten every pass.
const SPACING_EPSILON := 0.01
# World-space body length grows with the body radius, so a bigger snake is longer.
# A linear length looks wrong at both ends, so the length grows a little faster
# than the radius instead: that keeps the spawn genuinely tiny while still paying
# off dramatically as you eat.
#
# The spawn radius is the reference, so BODY_LENGTH_RATIO sets the starting length
# directly (5 * 20 = 100px, about four body-widths) and BODY_LENGTH_GROWTH sets how
# much faster than the radius it opens up. At 0.75 a snake six times the spawn
# radius ends up roughly twenty-five times longer than it started.
const BODY_LENGTH_RATIO := 5.0
const BODY_LENGTH_GROWTH := 0.75
const REFERENCE_RADIUS := 20.0
const MIN_BODY_POINTS := 6
const MAX_BODY_POINTS := 220
# The server radius is really a mass proxy, and drawing the tube at that radius makes
# a fat stubby worm whose length:width ratio never changes as you grow. Rendering the
# body narrower than the collision circle decouples the two, so growth shows up as
# added length rather than added girth. Collision and the magnet keep using the full
# server radius, so hit detection is unchanged.
const BODY_WIDTH_SCALE := 0.65
# The head stays a little broader than the neck so it still reads as a head.
const HEAD_WIDTH_SCALE := 0.8
# Head and body hold the full radius; only the last stretch shrinks to a point.
# Tapering along the whole length would expose every spot where segments bunch
# on a turn as a visible pinch. Shrinking only the tip is what reads as "fluffy":
# the circles stay heavily overlapped the whole way, so the silhouette rounds off.
const TAIL_TAPER_FRACTION := 0.22
const MIN_TAIL_SEGMENTS := 4
const TAIL_MIN_SCALE := 0.12
# Cap the sub-stepping so a long stall cannot turn into a huge catch-up loop. The
# chain is ~115 links long now, so the head outruns the body well before the old
# cap of 16 and the tail visibly lags behind on every fast turn.
const MAX_SUBSTEPS := 32
# Below this the server disagreement is noise; correcting it only adds jitter.
const RECONCILE_DEADZONE := 5.0
const RECONCILE_RATE := 0.25
# Sending a direction packet per frame is wasteful; ignore sub-threshold turns.
const SEND_ANGLE_THRESHOLD := TAU / 15

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
var velocity: Vector2
# Body points in local space; index 0 sits on the head, the tail is last.
var _points: Array[Vector2] = []
# Past server updates as (x, y, arrival time) for client-side interpolation.
var _snapshots: Array[Vector3] = []
var _facing := 0.0
var _draw_facing := 0.0
var _pupil_angle := 0.0
var _pupil_amount := 0.0
var radius: float:
	set(new_radius):
		radius = new_radius
		_collision_shape.set_radius(radius)
		_update_zoom()
		_update_magnet()
		queue_redraw()

@onready var _nameplate: Label = $Label
@onready var _cam: Camera2D = $Camera2D
@onready var _collision_shape: CircleShape2D = $CollisionShape2D.shape
@onready var _magnet_shape: CircleShape2D = $MagnetArea/CollisionShape2D.shape

signal magnet_area_entered(area: Area2D)


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
	position = Vector2(start_x, start_y)
	_facing = start_rad
	_draw_facing = _facing
	_pupil_angle = 0.0
	_pupil_amount = 0.22
	velocity = Vector2.from_angle(start_rad) * speed
	radius = start_rad
	$MagnetArea.area_entered.connect(_on_magnet_area_entered)
	_nameplate.text = actor_name
	_seed_body()
	queue_redraw()


func _process(delta: float) -> void:
	var target := _server_guided_position()

	if is_player:
		target = _predict_player_head(delta, target)

	_advance_body(target)
	_update_zoom_interpolation()
	_update_pupil(delta)


# Only the head reacts to input. Every other segment is dragged into place by the
# one in front of it, so a turn ripples backwards down the body instead of the
# whole snake sliding sideways as a rigid shape.
func _advance_body(target: Vector2) -> void:
	var movement := target - position
	var distance := movement.length()
	if distance > 0.0001:
		_facing = movement.angle()
		# Sub-step along the path so each segment advances by at most one spacing
		# per step, which keeps the chain at a constant arclength when moving fast.
		var spacing := _segment_spacing()
		var steps := mini(MAX_SUBSTEPS, maxi(1, ceili(distance / spacing)))
		var step_movement := movement / float(steps)
		for step in steps:
			position += step_movement
			# Body points live in world space, so re-seating the head here is what
			# makes the rest of the chain fall behind and swing around on a turn.
			_points[0] = position
			_relax_body(spacing)
		_sync_body_length(spacing)

	queue_redraw()


func _relax_body(spacing: float) -> void:
	for i in range(1, _points.size()):
		var parent := _points[i - 1]
		var offset := _points[i] - parent
		var distance := offset.length()
		# Snap to exactly the spacing in both directions. Clamping only the far
		# side lets a turn compress the body permanently, and a body that keeps
		# shrinking under a head-locked camera reads as frozen.
		if absf(distance - spacing) <= SPACING_EPSILON:
			continue
		if distance > 0.0001:
			_points[i] = parent + offset / distance * spacing
		else:
			_points[i] = parent + _tail_fallback(i) * spacing


# Points ahead of a server snapshot, so interpolation would have to extrapolate.
# Hold the newest known position until the next snapshot lands.
func _server_guided_position() -> Vector2:
	if _snapshots.is_empty():
		return position

	var now := _now_seconds()
	var render_time := now - INTERP_DELAY
	var newest := _snapshots[-1]
	if render_time >= newest.z:
		return Vector2(newest.x, newest.y)

	for i in range(_snapshots.size() - 1, 0, -1):
		var newer := _snapshots[i]
		var older := _snapshots[i - 1]
		if older.z <= render_time and render_time <= newer.z:
			var span := newer.z - older.z
			var t := 0.0 if span <= 0.0 else (render_time - older.z) / span
			var blended := older.lerp(newer, t)
			return Vector2(blended.x, blended.y)

	# The buffer has not filled yet; fall back to the oldest snapshot we hold.
	var oldest := _snapshots[0]
	return Vector2(oldest.x, oldest.y)


func _predict_player_head(delta: float, server_target: Vector2) -> Vector2:
	var input_direction := position.direction_to(get_global_mouse_position())
	if not input_direction.is_zero_approx():
		# A zero velocity has no angle of its own, so angle_to reports 0 and the turn
		# looks like "no change". That starves the server of the direction packet which
		# starts its movement loop, and a snake the server never moves is stuck for
		# good, so treat a zero velocity as always worth sending.
		var wants_new_direction := (
			velocity.is_zero_approx()
			or absf(velocity.angle_to(input_direction)) > SEND_ANGLE_THRESHOLD
		)
		if wants_new_direction:
			velocity = input_direction * speed
			_send_direction(velocity)

	# Predict locally for responsiveness, then ease back toward the server so the
	# head cannot drift arbitrarily far from the authoritative path.
	var predicted := position + velocity * delta
	var error := server_target - predicted
	if error.length() > RECONCILE_DEADZONE:
		predicted += error * RECONCILE_RATE
	return predicted


func _send_direction(direction: Vector2) -> void:
	var packet := packets.Packet.new()
	var player_direction_message := packet.new_player_direction()
	player_direction_message.set_direction(direction.angle())
	WsClient.send(packet)


func push_snapshot(x: float, y: float) -> void:
	_snapshots.append(Vector3(x, y, _now_seconds()))
	while _snapshots.size() > MAX_SNAPSHOTS:
		_snapshots.pop_front()


static func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


func _segment_spacing() -> float:
	return maxf(radius * BODY_WIDTH_SCALE * SEGMENT_SPACING_RATIO, MIN_SEGMENT_SPACING)


func _target_body_length() -> float:
	return maxf(radius, 0.001) * BODY_LENGTH_RATIO * pow(maxf(radius, 0.001) / REFERENCE_RADIUS, BODY_LENGTH_GROWTH)


func _target_point_count() -> int:
	var count := int(_target_body_length() / _segment_spacing()) + 1
	return clampi(count, MIN_BODY_POINTS, MAX_BODY_POINTS)


# Lay the initial chain out straight behind the spawn heading, otherwise every
# segment collapses onto the head and the snake pops in with a visible kink.
# Points are world-space, with index 0 sitting exactly on the head.
func _seed_body() -> void:
	_points.clear()
	var spacing := _segment_spacing()
	var backwards := -Vector2.from_angle(start_rad)
	for i in _target_point_count():
		_points.append(position + backwards * spacing * i)


func _sync_body_length(spacing: float) -> void:
	while _points.size() < _target_point_count():
		_points.append(_extended_tail_point(spacing))
	while _points.size() > _target_point_count():
		_points.pop_back()


func _extended_tail_point(spacing: float) -> Vector2:
	if _points.size() < 2:
		return _points[_points.size() - 1] + Vector2.LEFT * spacing
	var direction := _points[-1] - _points[-2]
	if direction.is_zero_approx():
		return _points[-1] + Vector2.LEFT * spacing
	return _points[-1] + direction.normalized() * spacing


# Direction to reuse when a segment has collapsed exactly onto its parent and
# the offset carries no direction of its own.
func _tail_fallback(index: int) -> Vector2:
	if index < 2:
		return Vector2.LEFT
	var direction := _points[index - 1] - _points[index - 2]
	if direction.is_zero_approx():
		return Vector2.LEFT
	return direction.normalized()


func _draw() -> void:
	var count := _points.size()
	# Tail to head, so the head and its eyes land on top of the whole body.
	for i in range(count - 1, -1, -1):
		draw_circle(_points[i] - position, _body_radius_at(i), color)

	var forward := Vector2.from_angle(_draw_facing)
	var side := forward.orthogonal()
	# Eyes are sized off the drawn head, not the collision radius, or they would
	# sit outside the head once the body is rendered narrower.
	var head_radius := radius * HEAD_WIDTH_SCALE
	var eye_radius := head_radius * EYE_RADIUS_RATIO
	var eyes: Array[Vector2] = []
	var pupil_dir := Vector2.from_angle(_draw_facing + _pupil_angle)
	for eye_side: float in [-1.0, 1.0]:
		var eye_center := forward * (head_radius * 0.42) + side * (eye_side * head_radius * EYE_SPREAD)
		eyes.append(eye_center)
		draw_circle(eye_center, eye_radius, LENS_COLOR)
		_draw_spiral_pupil(eye_center + pupil_dir * (_pupil_amount * eye_radius), eye_radius)
	_draw_frames(eyes[0], eyes[1], forward, eye_radius)


# Full body width everywhere except the tapered tail, which falls off with a
# square root so it stays broad at the base and rounds off softly at the tip.
func _body_radius_at(index: int) -> float:
	if index == 0:
		return radius * HEAD_WIDTH_SCALE

	var last := _points.size() - 1
	if last <= 0:
		return radius * HEAD_WIDTH_SCALE

	var taper_span := maxi(MIN_TAIL_SEGMENTS, int(float(last) * TAIL_TAPER_FRACTION))
	var tail_start := maxi(0, last - taper_span)
	if index <= tail_start:
		return radius * BODY_WIDTH_SCALE

	var t := float(last - index) / float(maxi(1, last - tail_start))
	return radius * BODY_WIDTH_SCALE * maxf(TAIL_MIN_SCALE, sqrt(t))


# Round wire rims with a bridge and stub temples, so the eyes read as a pair of
# spectacles. Drawn after the lenses and pupils so the frame sits on top of them.
func _draw_frames(
	eye_a: Vector2, eye_b: Vector2, forward: Vector2, eye_radius: float
) -> void:
	var rim := eye_radius * FRAME_RADIUS_RATIO
	var width := maxf(1.0, eye_radius * FRAME_WIDTH_RATIO)
	var glint_dir := Vector2.from_angle(_draw_facing + PI * 0.78)
	var span := (eye_b - eye_a).normalized()

	for eye_center: Vector2 in [eye_a, eye_b]:
		draw_arc(eye_center, rim, 0.0, TAU, FRAME_ARC_SEGMENTS, FRAME_COLOR, width, true)
		draw_circle(
			eye_center + glint_dir * (eye_radius * 0.46), maxf(1.0, eye_radius * 0.2),
			Color(1, 1, 1, 0.9)
		)

	draw_line(eye_a + span * rim, eye_b - span * rim, FRAME_COLOR, width, true)
	var temple := forward * (eye_radius * 0.7)
	draw_line(eye_a - span * rim, eye_a - span * rim - temple, FRAME_COLOR, width, true)
	draw_line(eye_b + span * rim, eye_b + span * rim - temple, FRAME_COLOR, width, true)


# A Google-style spiral, drawn as one tapering polyline plus the bar that turns it
# into a G. The span is most of the eye so the turns stay far enough apart to read
# instead of filling the eye in as a solid dot.
func _draw_spiral_pupil(center: Vector2, eye_radius: float) -> void:
	var span := eye_radius * SPIRAL_SPAN
	var width := maxf(1.5, eye_radius * SPIRAL_WIDTH)
	var spiral := PackedVector2Array()
	for i in SPIRAL_STEPS + 1:
		var t := float(i) / float(SPIRAL_STEPS)
		var angle := t * TAU * SPIRAL_TURNS - PI * 0.5
		spiral.append(center + Vector2.from_angle(angle) * (span * (1.0 - t * 0.82)))
	draw_polyline(spiral, SPIRAL_COLOR, width, true)
	draw_line(spiral[spiral.size() - 1], center, SPIRAL_COLOR, width, true)


# The head angle is smoothed separately from _facing, which stays raw because the
# server is sent the true movement direction. Without this the eyes inherit every
# wobble in the head angle and twitch, since the pupil lives in the head's frame.
# The pupil is then eased as an angle in that frame, so it always takes the short
# way round instead of sweeping the long way through the PI wrap.
func _update_pupil(delta: float) -> void:
	_draw_facing = lerp_angle(_draw_facing, _facing, 1.0 - exp(-FACE_RATE * delta))

	var target_angle := 0.0
	var target_amount := 0.22
	if is_player:
		var to_mouse := global_position.direction_to(get_global_mouse_position())
		if to_mouse.length_squared() > 0.000001:
			# The full bearing, not the perpendicular remainder: projecting onto the
			# side axis pinned the pupil to the front half-plane and flipped it at the
			# boundary, which read as a snap. Any angle is safe because the travel is a
			# fraction of the eye radius, so the pupil stays inside the eye all round.
			target_angle = to_mouse.angle() - _draw_facing
			target_amount = PUPIL_TRAVEL
	_pupil_angle = lerp_angle(_pupil_angle, target_angle, 1.0 - exp(-PUPIL_RATE * delta))
	_pupil_amount = lerpf(_pupil_amount, target_amount, 1.0 - exp(-PUPIL_RATE * delta))


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


func _update_zoom_interpolation() -> void:
	if is_equal_approx(_cam.zoom.x, _target_zoom):
		return
	_cam.zoom -= Vector2.ONE * (_cam.zoom.x - _target_zoom) * 0.05


func _update_magnet() -> void:
	_magnet_shape.radius = radius + MAGNET_EXTRA_RADIUS


func _on_magnet_area_entered(area: Area2D) -> void:
	magnet_area_entered.emit(area)


func body_point_count() -> int:
	return _points.size()


func body_point(i: int) -> Vector2:
	return _points[i]


# Server teleports us to a fresh spawn after dying. The old chain is still strung
# out across the map at that point, and re-seeding it in place would make the body
# crawl back over several seconds, so drop it and start clean at the new position.
func respawn(x: float, y: float, radius: float) -> void:
	_snapshots.clear()
	velocity = Vector2.ZERO
	position = Vector2(x, y)
	self.radius = radius
	_facing = start_rad
	_draw_facing = _facing
	_pupil_angle = 0.0
	_pupil_amount = 0.22
	_seed_body()
	# The server's movement loop only starts on the first direction packet it sees
	# from us, and the fresh player arrives facing angle 0. Without this the snake
	# sits perfectly still until the mouse happens to swing far enough off
	# horizontal to trip the turn threshold.
	_send_direction(Vector2.from_angle(_facing))
	queue_redraw()
