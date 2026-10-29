extends CanvasLayer
## Pause menu: Esc (or Start on a controller) pauses the game and opens a framed card with
##   PLAY    - back to the game (Esc again does the same)
##   RESTART - start a fresh run (skips the title screen)
##   MUSIC   - turns the background music on / off (remembered between plays)
##   QUIT    - back to the title screen (main menu)
## It can't be opened over the title screen or the game-over book.
##
## Setup: right-click Main > Add Child Node > CanvasLayer, name it "PauseMenu", attach this script.
## Uses res://ui/ (card_frame.png, banner_yellow.png, button_green/blue/teal/red.png,
## icon_sound_on/off.png, the Fredoka font).
## Music and ambience keep playing while paused (the MusicPlayer autoload ignores the pause).

@export var ui_folder := "res://ui/"
@export var ui_scale := 1.0
## Sounds that keep playing while paused. Any AudioStreamPlayer whose name contains one of these words
## (e.g. "Music", "Ambience", "BackgroundMusic") is found automatically, as is anything in the "music" group.
@export var keep_playing_words: Array[String] = ["music", "ambien", "bgm", "song"]
## Extra sound nodes to keep playing that don't match the words above.
@export var keep_playing: Array[NodePath] = []
## The music the MUSIC button turns on and off (the ambience stays on).
@export var music_path: NodePath = ^"/root/MusicPlayer/BackgroundMusic"

const SETTINGS_FILE := "user://settings.cfg"

const BROWN := Color(0.43, 0.19, 0.16)
const CREAM := Color(1.0, 0.98, 0.9)

var _font: Font
var _k := 1.0
var _root: Control
var _open := false
var _busy := false
var _buttons: Array[TextureButton] = []
var _music_btn: TextureButton
static var _music_off := false


func _enter_tree() -> void:
	# done here (not in _ready) so the title screen can find it whatever order the nodes are in
	add_to_group("pause_menu")                              # the title screen's music button talks to this
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) == OK:
		_music_off = cfg.get_value("audio", "music_off", false)


func _ready() -> void:
	layer = 70
	process_mode = Node.PROCESS_MODE_ALWAYS                 # has to keep working while the game is paused
	_font = load(ui_folder + "Fredoka-SemiBold.ttf") if ResourceLoader.exists(ui_folder + "Fredoka-SemiBold.ttf") else ThemeDB.fallback_font
	_keep_music_going()
	_apply_music.call_deferred()
	get_viewport().size_changed.connect(_on_resize)                            # after the MusicPlayer has started its song


func _input(event: InputEvent) -> void:
	var esc: bool = event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE
	var start: bool = event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START
	var pad_b: bool = event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B
	if _busy:
		return
	if _open and (esc or start or pad_b):
		get_viewport().set_input_as_handled()
		_resume()
	elif not _open and (esc or start) and _can_pause():
		get_viewport().set_input_as_handled()
		_pause()


## Opens the menu (used by the on-screen pause button, see game_ui.gd).
func open() -> void:
	if not _open and not _busy and _can_pause():
		_pause()


func _can_pause() -> bool:
	var main := get_parent()
	if main.get("game_over") == true or main.get("waves_on_hold") == true:
		return false                                          # game-over book or title screen is up
	return true


# ---------------------------------------------------------------- open / close

func _pause() -> void:
	_open = true
	_keep_music_going()
	get_tree().paused = true
	_build(false)


## The screen changed shape while paused (a phone turned): lay the menu out again.
func _on_resize() -> void:
	if _open and not _busy and _root:
		_build(true)


func _build(again: bool) -> void:
	if _root:
		_root.free()
	# the card + its ribbon need about 500 x 740 design pixels; fit that to the screen (phones too)
	_k = UIFit.menu_k(get_viewport(), Vector2(500, 740)) * ui_scale
	var vs := get_viewport().get_visible_rect().size
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.1, 0.07, 0.04, 0.45 if again else 0.0)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	if not again:
		create_tween().tween_property(dim, "color:a", 0.45, 0.2)

	# everything sits on one panel, so it all scales / fades together
	var panel := Control.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(panel)
	var card := _sprite("card_frame", 440.0, panel)
	panel.size = card.size
	panel.position = (vs - panel.size) * 0.5 + Vector2(0, 30 * _k)
	panel.pivot_offset = panel.size * 0.5
	var rib := _sprite("banner_yellow", 500.0, panel)
	rib.position = Vector2((card.size.x - rib.size.x) * 0.5, -rib.size.y * 0.45)
	var title := _label("PAUSED", 50, Color(0.36, 0.2, 0.15))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size = Vector2(rib.size.x, rib.size.y * 0.62)
	rib.add_child(title)

	_buttons.clear()
	var specs := [
		["button_green", "PLAY", Color(0.1, 0.45, 0.1), _resume],
		["button_blue", "RESTART", Color(0.05, 0.35, 0.55), _restart],
		["button_teal", "", Color(0.02, 0.33, 0.3), _toggle_music],
		["button_red", "QUIT", Color(0.55, 0.1, 0.12), _quit],
	]
	var y := card.size.y * 0.17
	for s in specs:
		var b := _button(s[0], s[1], 230.0, s[2], s[3], panel)
		b.position = Vector2((card.size.x - b.size.x) * 0.5, y)
		y += b.size.y + 14 * _k
		_buttons.append(b)
		if s[3] == _toggle_music:
			_music_btn = b
			var icon := TextureRect.new()
			icon.name = "Icon"
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.size = Vector2(40, 40) * _k
			icon.position = Vector2(b.size.x * 0.09, b.size.y * 0.41 - icon.size.y * 0.5)
			b.add_child(icon)
			_update_music_button()

	PadUI.hook(_buttons, _buttons[0])                     # controller: up / down, PLAY selected first

	if again:
		return
	panel.scale = Vector2.ONE * 0.6
	panel.modulate.a = 0.0
	var t := create_tween().set_parallel(true)
	t.tween_property(panel, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(panel, "modulate:a", 1.0, 0.15)


func _close(then: Callable = Callable()) -> void:
	_busy = true
	PadUI.clear()
	var panel := _root.get_child(1) if _root.get_child_count() > 1 else null
	var t := create_tween().set_parallel(true)
	if panel:
		t.tween_property(panel, "scale", Vector2.ONE * 0.8, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		t.tween_property(panel, "modulate:a", 0.0, 0.15)
	t.tween_property(_root.get_child(0), "color:a", 0.0, 0.15)
	await t.finished
	_root.queue_free()
	_root = null
	_open = false
	_busy = false
	if then.is_valid():
		then.call()


func _resume() -> void:
	if _busy:
		return
	await _close()
	get_tree().paused = false


func _restart() -> void:
	if _busy:
		return
	_busy = true
	PadUI.clear()
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().reload_current_scene()                         # the title screen only shows on first launch


func _quit() -> void:
	if _busy:
		return
	_busy = true
	for c in ProjectSettings.get_global_class_list():         # make the title screen show again
		if c["class"] == "TitleScreen":
			var script = load(c["path"])
			if script:
				script.set("shown_once", false)
	PadUI.clear()
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().reload_current_scene()


# ---------------------------------------------------------------- music on / off

## Used by the title screen's music button too, so both always agree.
func is_music_off() -> bool:
	return _music_off


func _toggle_music() -> void:
	toggle_music()


func toggle_music() -> void:
	_music_off = not _music_off
	_apply_music()
	_update_music_button()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)
	cfg.set_value("audio", "music_off", _music_off)
	cfg.save(SETTINGS_FILE)


func _apply_music() -> void:
	var m := get_node_or_null(music_path)
	if m == null:
		return
	m.stream_paused = _music_off                            # picks the song back up where it left off
	if not _music_off and not m.playing:
		m.play()


func _update_music_button() -> void:
	if _music_btn == null:
		return
	var l: Label = _music_btn.get_child(0)
	l.text = "MUSIC OFF" if _music_off else "MUSIC ON"
	l.label_settings.font_size = maxi(int(26 * _k), 8)
	l.position.x = _music_btn.size.x * 0.27                  # leave room for the speaker on the left
	l.size.x = _music_btn.size.x * 0.66
	var icon: TextureRect = _music_btn.get_node("Icon")
	icon.texture = load(ui_folder + ("icon_sound_off.png" if _music_off else "icon_sound_on.png"))
	_music_btn.self_modulate = Color(0.85, 0.85, 0.85) if _music_off else Color.WHITE


# ---------------------------------------------------------------- helpers

## Music and ambience ignore the pause; everything else (rolling, ant, helmet sounds) pauses with the game.
func _keep_music_going() -> void:
	for path in keep_playing:
		var n := get_node_or_null(path)
		if n:
			n.process_mode = Node.PROCESS_MODE_ALWAYS
	var music := get_tree().get_nodes_in_group("music")
	var stack: Array[Node] = [get_tree().root]               # includes autoloads like MusicPlayer
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not (n is AudioStreamPlayer or n is AudioStreamPlayer2D or n is AudioStreamPlayer3D):
			continue
		var lname := String(n.name).to_lower()
		var keep := music.has(n)
		for w in keep_playing_words:
			if lname.contains(w.to_lower()):
				keep = true
		if keep:
			n.process_mode = Node.PROCESS_MODE_ALWAYS

func _sprite(name: String, w: float, parent: Control) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load(ui_folder + name + ".png")
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := w * (float(r.texture.get_height()) / r.texture.get_width()) if r.texture else w
	r.size = Vector2(w, h) * _k
	parent.add_child(r)
	return r


func _label(text: String, size: float, color: Color, outline := 0.0, outline_color := BROWN) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font = _font
	ls.font_size = maxi(int(size * _k), 8)
	ls.font_color = color
	if outline > 0.0:
		ls.outline_size = maxi(int(outline * _k), 1)
		ls.outline_color = outline_color
	l.label_settings = ls
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Sprite button with a label; squashes down when pressed and springs back, like the other menus.
func _button(sprite: String, text: String, w: float, edge: Color, on_press: Callable, parent: Control) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = load(ui_folder + sprite + ".png")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	var h := w * (float(b.texture_normal.get_height()) / b.texture_normal.get_width())
	b.size = Vector2(w, h) * _k
	b.pivot_offset = b.size * 0.5
	var l := _label(text, 30, CREAM, 9, edge)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(b.size.x, b.size.y * 0.82)
	b.add_child(l)
	b.button_down.connect(func():
		b.set_meta("rest_y", b.get_meta("rest_y", b.position.y))
		var t := create_tween().set_parallel(true)
		t.tween_property(b, "scale", Vector2(1.04, 0.86), 0.06)
		t.tween_property(b, "position:y", b.get_meta("rest_y") + 7.0 * _k, 0.06)
		t.tween_property(b, "modulate", Color(0.85, 0.85, 0.85), 0.06))
	b.button_up.connect(func():
		var t := create_tween().set_parallel(true)
		t.tween_property(b, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(b, "position:y", b.get_meta("rest_y", b.position.y), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(b, "modulate", Color.WHITE, 0.1))
	b.pressed.connect(func():
		await get_tree().create_timer(0.15).timeout          # let it spring back first
		on_press.call())
	b.mouse_entered.connect(func():
		if not b.button_pressed and UIFit.hover_ok():         # no hover grow from a finger tap
			create_tween().tween_property(b, "scale", Vector2.ONE * 1.07, 0.12))
	b.mouse_exited.connect(func():
		if not b.button_pressed:
			create_tween().tween_property(b, "scale", Vector2.ONE, 0.12))
	parent.add_child(b)
	return b
