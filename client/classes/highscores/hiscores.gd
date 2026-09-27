class_name Hiscores
extends ScrollContainer

var _scores: Array[int]

@onready var _vbox: VBoxContainer = $VBoxContainer
@onready var _entry_template: HBoxContainer = $VBoxContainer/HBoxContainer


func _find_entry(name: String) -> HBoxContainer:
	for entry in _vbox.get_children():
		if entry == _entry_template:
			continue
		var name_label: Label = entry.get_child(0)
		if name_label.text == name:
			return entry
	return null


func _add_hiscore(name: String, score: int, highlight: bool) -> void:
	_scores.append(score)
	_scores.sort()
	var pos := len(_scores) - _scores.find(score) - 1
	var entry: HBoxContainer = _entry_template.duplicate()
	var name_label: Label = entry.get_child(0)
	var score_label: Label = entry.get_child(1)
	_vbox.add_child(entry)
	_vbox.move_child(entry, pos)
	name_label.text = name
	score_label.text = str(score)
	entry.show()
	if highlight:
		name_label.add_theme_color_override("font_color", Color.YELLOW)


func set_hiscore(name: String, score: int, highlight: bool = false) -> void:
	var existing := _find_entry(name)
	if existing != null:
		var old_score := int(existing.get_child(1).text)
		if old_score == score:
			return
	remove_hiscore(name)
	_add_hiscore(name, score, highlight)


func remove_hiscore(name: String) -> void:
	var entry := _find_entry(name)
	if entry == null:
		return
	_scores.erase(int(entry.get_child(1).text))
	_vbox.remove_child(entry)
	entry.queue_free()


func clear_hiscores() -> void:
	_scores.clear()
	for entry in _vbox.get_children():
		if entry != _entry_template:
			_vbox.remove_child(entry)
			entry.queue_free()


func _ready() -> void:
	_entry_template.hide()
