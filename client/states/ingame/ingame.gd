extends Node

const packets := preload("res://packets.gd")

@onready var _line_edit: LineEdit = $UI/LineEdit
@onready var _log: Log = $UI/Log

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_line_edit.text_submitted.connect(_on_line_edit_text_submitted)
	WsClient.connection_closed.connect(_on_ws_connection_closed)
	WsClient.packet_received.connect(_on_ws_packet_recieved)
# Cal	_line_edit.text_submitted.connect(_on_line_edit_text_submitted)
func _process(delta: float) -> void:
	pass

func _on_ws_connection_closed() -> void:
	_log.error("Connection closed")

func _on_ws_packet_recieved(packet: packets.Packet) -> void:
	var sender_id := packet.get_sender_id()
	if packet.has_chat():
		_handle_chat_msg(sender_id, packet.get_chat())

func _handle_chat_msg(sender_id: int, chat_msg: packets.ChatMessage) -> void:
	_log.chat("Client %d" % sender_id, chat_msg.get_msg())

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
