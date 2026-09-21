extends Node

const packets := preload("res://packets.gd")
@onready var _log = $Log
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	WsClient.connected_to_server.connect(_on_ws_connected_to_server)
	WsClient.connection_closed.connect(_on_ws_connection_closed)
	WsClient.packet_recieved.connect(_on_ws_packet_recieved)

	_log.info("Connecting to server...")
	WsClient.connect_to_url("ws://127.0.0.1:8080/ws")

func _on_ws_connected_to_server() -> void:
	var packet := packets.Packet.new()
	var chat_msg := packet.new_chat()
	chat_msg.set_msg("Sup Golang")

	var err := WsClient.send(packet)
	if err:
		_log.error("Error sending packet")
	else:
		_log.success("Sent packet")

func _on_ws_connection_closed() -> void:
	_log.error("Connection closed")

func _on_ws_packet_recieved(packet: packets.Packet) -> void:
	_log.info("Received packet from the server at: %s" % packet)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
