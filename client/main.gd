extends Node

const packets := preload("res://packets.gd")
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var packet := packets.Packet.new()
	packet.set_sender_id(67)
	var chat_msg := packet.new_chat()
	chat_msg.set_msg("Hello dude wassup")
	print(chat_msg)

	var new_packet := packets.Packet.new()
	new_packet.from_bytes([8, 69, 18, 15, 10, 13, 72, 101, 108, 108, 111, 44, 32, 119, 111, 114, 108, 100 , 33])
	print(new_packet.get_chat().get_msg())


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
