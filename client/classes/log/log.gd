class_name Log
extends RichTextLabel

func _message(message: String, color: Color = Color.WHITE) -> void:
	append_text("[color=#%s]%s[/color]\n" % [color.to_html(false), str(message)])

func info(msg: String) -> void:
	_message(msg, Color.WHITE)

func warning(msg: String) -> void:
	_message(msg, Color.YELLOW)

func error(msg: String) -> void:
	_message(msg, Color.ORANGE_RED)

func success(msg: String) -> void:
	_message(msg, Color.LAWN_GREEN)

func chat(sender_name: String, message: String) -> void:
	_message("[color=#%s]%s:[/color] [i]%s[/i]" % [Color.CORNFLOWER_BLUE.to_html(false), sender_name, message])
