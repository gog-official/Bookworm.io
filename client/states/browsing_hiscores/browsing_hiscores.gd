extends Node

const packets := preload("res://packets.gd")

@onready var _hs: Hiscores = $UI/MarginContainer/VBoxContainer/Hiscores

@onready var _back_button: Button = $UI/MarginContainer/VBoxContainer/HBoxContainer/Button
@onready var _search_button: Button = $UI/MarginContainer/VBoxContainer/HBoxContainer/Search
@onready var _line_edit: LineEdit = $UI/MarginContainer/VBoxContainer/HBoxContainer/LineEdit
@onready var _log: Log = $UI/MarginContainer/VBoxContainer/Log


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_line_edit.text_submitted.connect(_on_search_submitted)
	_search_button.pressed.connect(_on_search_pressed)
	_back_button.pressed.connect(_on_back_button_pressed)
	WsClient.packet_received.connect(_on_ws_packet_received)
	var packet := packets.Packet.new()
	packet.new_hiscore_board_request()
	WsClient.send(packet)


func _on_search_submitted(_new_txt: String) -> void:
	_on_search_pressed()


func _on_search_pressed() -> void:
	var packet := packets.Packet.new()
	var search_hs_msg := packet.new_search_hiscore()
	search_hs_msg.set_name(_line_edit.text)
	WsClient.send(packet)


func _on_back_button_pressed() -> void:
	var packet := packets.Packet.new()
	packet.new_finished_browsing_hiscores()
	WsClient.send(packet)
	GameManager.set_state(GameManager.State.CONNECTED)


func _on_ws_packet_received(packet: packets.Packet) -> void:
	if packet.has_hiscore_board():
		_handle_hiscore_board_msg(packet.get_hiscore_board())
	elif packet.has_deny_response():
		_handle_deny_response(packet.get_deny_response())


func _handle_hiscore_board_msg(hiscore_board_msg: packets.HiscoreBoardMessage) -> void:
	_hs.clear_hiscores()
	for hiscore_msg: packets.HiscoreMessage in hiscore_board_msg.get_hiscores():
		var name := hiscore_msg.get_name()
		var rank_n_name := "%d. %s" % [hiscore_msg.get_rank(), name]
		var score := hiscore_msg.get_score()
		var hl := name.to_lower().contains(_line_edit.text.to_lower())
		_hs.set_hiscore(rank_n_name, score, hl)


func _handle_deny_response(deny_response: packets.DenyResponseMessage) -> void:
	_log.error(deny_response.get_reason())


func _process(delta: float) -> void:
	pass
