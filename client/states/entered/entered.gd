extends Node

const packets := preload("res://packets.gd")

@onready var _log: Log = $UI/Log


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	WsClient.connected_to_server.connect(_on_ws_connected_to_server)
	WsClient.connection_closed.connect(_on_ws_connection_closed)
	WsClient.packet_received.connect(_on_ws_packet_received)

	_log.info("Connecting to server...")
	WsClient.connect_to_url("ws://localhost:8080/ws")

func _on_ws_connected_to_server() -> void:
	_log.info("Connected to server")

func _on_ws_connection_closed() -> void:
	_log.info("Connection closed")

func _on_ws_packet_received(packet: packets.Packet) -> void:
	var sen_id := packet.get_sender_id()
	if packet.has_id():
		_handle_id_msg(sen_id, packet.get_id())

func _handle_id_msg(sen_id: int, id_msg: packets.IdMessage) -> void:
	GameManager.client_id = id_msg.get_id()
	GameManager.set_state(GameManager.State.INGAME)
