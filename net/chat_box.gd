class_name ChatBox
extends PanelContainer
## Chat panel (book ch.4, restyled): a scrolling log and a line to type in.
## Messages go through Net.send_chat -> the server -> everyone (Net.chat_received).
## Used in the lobby and over the game. In the game:
##   Enter (or T) starts typing, Enter sends, Esc stops typing.
##   While you type, the game's keyboard shortcuts (camera Q / E, Tab target) are ignored.

@export var compact := false          ## in-game: see-through until you use it, smaller text

var log_label: RichTextLabel
var input: LineEdit
var _fade_tween: Tween


func _init(is_compact := false) -> void:
	compact = is_compact


func _ready() -> void:
	theme = NetUI.theme(20 if compact else 24)
	add_theme_stylebox_override("panel", NetUI.paper(NetUI.PAPER, 0.88 if compact else 1.0))
	add_to_group("blocks_bowling")                      # clicking the chat never launches the bug (player.gd)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.custom_minimum_size = Vector2(0, 80)
	log_label.add_theme_font_size_override("normal_font_size", 18 if compact else 22)
	log_label.add_theme_font_size_override("bold_font_size", 18 if compact else 22)
	log_label.add_theme_font_override("bold_font", NetUI.font())
	log_label.focus_mode = Control.FOCUS_NONE
	log_label.selection_enabled = false
	box.add_child(log_label)
	input = NetUI.line_edit("Press Enter to chat" if compact else "Say something...", "", 100)
	input.max_length = 200
	input.custom_minimum_size.y = 40 if compact else 48
	input.text_submitted.connect(_on_submit)
	input.focus_entered.connect(_wake)
	input.focus_exited.connect(_rest)
	input.gui_input.connect(_on_input_gui)
	box.add_child(input)
	Net.chat_received.connect(add_message)
	if compact:
		_rest()


func add_message(from_name: String, text: String, color: Color) -> void:
	if not is_instance_valid(log_label):
		return
	var safe := text.replace("[", "[lb]")              # nobody can sneak BBCode into the chat
	if from_name == "":
		log_label.append_text("[i][color=#%s]%s[/color][/i]\n" % [_darken(color).to_html(false), safe])
	else:
		log_label.append_text("[b][color=#%s]%s:[/color][/b] %s\n" % [_darken(color).to_html(false), from_name.replace("[", "[lb]"), safe])
	_wake()
	if compact and not input.has_focus():
		_rest(4.0)


## The light player colours are hard to read on cream paper: draw names a bit darker.
func _darken(c: Color) -> Color:
	return c.darkened(0.35)


func is_typing() -> bool:
	return input != null and input.has_focus()


func start_typing() -> void:
	input.grab_focus()


func _on_submit(text: String) -> void:
	Net.send_chat(text)
	input.clear()
	if compact:
		input.release_focus()                             # back to bowling


func _on_input_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		input.release_focus()
		accept_event()


## In game the chat fades back when you're not using it, so it doesn't hide the backyard.
func _wake() -> void:
	if not compact:
		return
	if _fade_tween:
		_fade_tween.kill()
	modulate.a = 1.0


func _rest(after := 0.0) -> void:
	if not compact or is_typing():
		return
	if _fade_tween:
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_interval(after)
	_fade_tween.tween_property(self, "modulate:a", 0.55, 0.6)
