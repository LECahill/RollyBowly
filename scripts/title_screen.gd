class_name TitleScreen
extends CanvasLayer
## Title screen, shown once when the game is first launched (not after PLAY AGAIN).
##   - "ROLLY BOWLY" bounces in letter by letter over the backyard (which keeps running, waves on hold).
##   - PLAY starts the game. HOW TO PLAY opens the book with the rules on its two pages.
##   - Enter / A = PLAY on the title, BACK in the book.
##
## Setup: right-click Main > Add Child Node > CanvasLayer, name it "TitleScreen", attach this script.
## It uses the same res://ui/ images and font as game_ui.gd.
## Phones: it fits any screen (see ui_fit.gd). Held upright, ROLLY and BOWLY stack, and the how-to book
## becomes one tall page. Turning the phone lays it all out again.

@export var ui_folder := "res://ui/"
@export var ui_scale := 1.0
@export var show_in_editor_runs := true          ## off = skip the title while you test (F5) in the editor

const BROWN := Color(0.43, 0.19, 0.16)
const CREAM := Color(1.0, 0.98, 0.9)
const INK := Color(0.36, 0.2, 0.15)

static var shown_once := false                   # survives reload_current_scene(), so PLAY AGAIN skips the title

var _font: Font
var _k := 1.0
var _root: Control
var _dim: ColorRect
var _title_parts: Array[Control] = []            # everything on the title page (letters, ribbon, buttons)
var _letters: Array[Label] = []
var _book_parts: Array[Control] = []
var _title_play: Control                         # selected first when using a controller
var _mode := "title"                             # title / book / leaving
var _t := 0.0
var _game_ui: Node
var _player: Node
var _title_k := 1.0                              # the title page's scale (the book has its own)
var _resize_token := 0


func _ready() -> void:
	if Net.online:                                   # online match: the lobby already did the welcoming
		queue_free()
		return
	if shown_once or (OS.has_feature("editor") and not show_in_editor_runs):
		queue_free()
		return
	shown_once = true
	layer = 60
	_font = load(ui_folder + "Fredoka-SemiBold.ttf") if ResourceLoader.exists(ui_folder + "Fredoka-SemiBold.ttf") else ThemeDB.fallback_font
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_dim = ColorRect.new()
	_dim.color = Color(0.1, 0.07, 0.04, 0.0)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP         # nothing behind the title gets clicked
	_root.add_child(_dim)
	create_tween().tween_property(_dim, "color:a", 0.4, 0.4)
	_hold_game.call_deferred()
	_build_title()
	get_viewport().size_changed.connect(_on_resize)


## The screen changed shape (a phone turned, a window resized): lay everything out again, once it settles.
func _on_resize() -> void:
	_resize_token += 1
	var token := _resize_token
	await get_tree().create_timer(0.25).timeout
	if token != _resize_token or _mode == "leaving" or not is_inside_tree():
		return
	for c in _title_parts + _book_parts:
		if is_instance_valid(c):
			_stop_throb(c)                                     # looping tweens must stop before their button goes
			c.free()
	_title_parts.clear()
	_book_parts.clear()
	_letters.clear()
	_build_title()
	if _mode == "book":
		_set_title_visible(false)
		_build_book()


## The backyard keeps running behind the title (music, ambience, swaying grass), but the first wave
## waits, the HUD is hidden and the rolly polly ignores clicks (so clicking a button doesn't launch it).
func _hold_game() -> void:
	var main := get_parent()
	if "waves_on_hold" in main:
		main.waves_on_hold = true
	_player = get_tree().get_first_node_in_group("player")
	if _player:
		_player.set_process_input(false)
	_game_ui = get_tree().get_first_node_in_group("game_over_screen")   # game_ui.gd
	if _game_ui:
		_game_ui.visible = false


# ---------------------------------------------------------------- helpers

func _tex(name: String) -> Texture2D:
	return load(ui_folder + name + ".png")


func _sprite(name: String, w: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = _tex(name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := w * (float(r.texture.get_height()) / r.texture.get_width()) if r.texture else w
	r.size = Vector2(w, h) * _k
	r.pivot_offset = r.size * 0.5
	_root.add_child(r)
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


## A sprite button with a label on it that squashes down when pressed and springs back up.
func _button(sprite: String, text: String, w: float, edge: Color, on_press: Callable) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = _tex(sprite)
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	var h := w * (float(b.texture_normal.get_height()) / b.texture_normal.get_width())
	b.size = Vector2(w, h) * _k
	b.pivot_offset = b.size * 0.5
	var l := _label(text, maxf(w * 0.11, 30.0), CREAM, maxf(w * 0.03, 8.0), edge)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(b.size.x, b.size.y * 0.82)
	b.add_child(l)
	b.button_down.connect(func():
		_stop_throb(b)
		_press(b))
	b.button_up.connect(func(): _release(b))
	b.pressed.connect(func():
		await get_tree().create_timer(0.15).timeout          # let it spring back up first
		on_press.call())
	b.mouse_entered.connect(func():
		if not b.button_pressed and UIFit.hover_ok():         # no hover grow from a finger tap
			_stop_throb(b)
			create_tween().tween_property(b, "scale", Vector2.ONE * 1.07, 0.12))
	b.mouse_exited.connect(func():
		if not b.button_pressed:
			var t := create_tween()
			t.tween_property(b, "scale", Vector2.ONE, 0.12)
			if b.get_meta("throbs", false):
				t.tween_callback(func(): _throb(b)))
	_root.add_child(b)
	return b


func _press(b: Control) -> void:
	if not b.has_meta("rest_y"):
		b.set_meta("rest_y", b.position.y)
	var t := create_tween().set_parallel(true)
	t.tween_property(b, "scale", Vector2(1.04, 0.86), 0.06)
	t.tween_property(b, "position:y", b.get_meta("rest_y") + 7.0 * _k, 0.06)
	t.tween_property(b, "modulate", Color(0.85, 0.85, 0.85), 0.06)


func _release(b: Control) -> void:
	var t := create_tween().set_parallel(true)
	t.tween_property(b, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(b, "position:y", b.get_meta("rest_y", b.position.y), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(b, "modulate", Color.WHITE, 0.1)


## Gentle "press me" pulse, same as the PLAY AGAIN button on the game-over book.
func _throb(b: Control) -> void:
	_stop_throb(b)
	b.set_meta("throbs", true)
	var t := create_tween().set_loops()
	t.tween_property(b, "scale", Vector2.ONE * 1.05, 0.5).set_trans(Tween.TRANS_SINE)
	t.tween_property(b, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_SINE)
	b.set_meta("throb_tween", t)


func _stop_throb(b: Control) -> void:
	var t = b.get_meta("throb_tween") if b.has_meta("throb_tween") else null
	if t and t is Tween and t.is_valid():
		t.kill()
	b.set_meta("throb_tween", null)


func _pop_in(c: Control, delay: float) -> void:
	c.scale = Vector2.ZERO
	var t := create_tween()
	t.tween_interval(delay)
	t.tween_property(c, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ---------------------------------------------------------------- title page

func _build_title() -> void:
	var vp := get_viewport()
	var vs := UIFit.size(vp)
	var portrait := UIFit.is_portrait(vp)
	var show_close := _show_close()
	var buttons := 3 if show_close else 2
	var size := 150.0                                         # letter size, design pixels
	var letters_h := size * 1.25
	var rib_w := 600.0 if portrait else 760.0
	var rib_h := rib_w * 168.0 / 900.0
	var btn_h := 330.0 * 161.0 / 362.0
	# everything stacked: the name (one line, or two when upright), the ribbon, then the buttons
	var stack_h := letters_h * (1.85 if portrait else 1.0) + rib_h + 40.0 + buttons * btn_h + (buttons - 1) * 24.0
	_k = UIFit.menu_k(vp, Vector2(640.0 if portrait else 1200.0, stack_h), Vector2(0.92, 0.84)) * ui_scale
	_title_k = _k
	var top := maxf((vs.y - stack_h * _k) * 0.5 + 30.0 * _k, 20.0 * _k)

	# ROLLY BOWLY, letter by letter: the bug's blue-grey, then the ants' warm yellow
	var words := [["ROLLY", Color(0.7, 0.84, 1.0)], ["BOWLY", Color(1.0, 0.84, 0.32)]]
	var gap := 40.0 * _k
	var widths := []
	var total := -gap
	for w in words:
		var ww := 0.0
		for ch in w[0]:
			ww += _font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size * _k)).x
		widths.append(ww)
		total += ww + gap
	var x := (vs.x - total) * 0.5
	var y := top
	var i := 0
	for wi in words.size():
		if portrait:                                          # one word per line
			x = (vs.x - widths[wi]) * 0.5
			y = top + wi * letters_h * 0.85 * _k
		for ch in words[wi][0]:
			var l := _label(ch, size, words[wi][1], 34, BROWN)
			var cw := _font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size * _k)).x
			l.position = Vector2(x, y)
			l.size = Vector2(cw, letters_h * _k)
			l.pivot_offset = Vector2(cw * 0.5, size * 1.0 * _k)
			l.set_meta("base_y", y)
			l.set_meta("i", i)
			_root.add_child(l)
			_letters.append(l)
			_title_parts.append(l)
			# drop in from above, one after another
			l.position.y = -size * 2.0 * _k
			var t := create_tween()
			t.tween_interval(0.25 + i * 0.07)
			t.tween_property(l, "position:y", y, 0.55).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
			t.tween_callback(func(): l.set_meta("landed", true))
			x += cw
			i += 1
		x += gap
	var name_bottom := top + letters_h * (1.85 if portrait else 1.0) * _k
	# tagline ribbon
	var rib := _sprite("banner_yellow", rib_w)
	rib.position = Vector2((vs.x - rib.size.x) * 0.5, name_bottom)
	var tag := _label("Backyard Bug Bowling!", 40, INK)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.size = Vector2(rib.size.x, rib.size.y * 0.62)
	rib.add_child(tag)
	_title_parts.append(rib)
	_pop_in(rib, 0.25 + i * 0.07 + 0.2)
	# buttons
	var play := _button("button_green", "PLAY", 330.0, Color(0.1, 0.45, 0.1), _start_game)
	play.position = Vector2((vs.x - play.size.x) * 0.5, rib.position.y + rib.size.y + 40.0 * _k)
	var how := _button("button_blue", "HOW TO PLAY", 330.0, Color(0.05, 0.35, 0.55), _open_book)
	how.position = Vector2((vs.x - how.size.x) * 0.5, play.position.y + play.size.y + 24 * _k)
	_title_parts.append(play)
	_title_parts.append(how)
	# CLOSE quits the game (desktop only, see _show_close)
	if show_close:
		var close := _button("button_red", "CLOSE", 330.0, Color(0.55, 0.1, 0.12), func(): get_tree().quit())
		close.position = Vector2((vs.x - close.size.x) * 0.5, how.position.y + how.size.y + 24 * _k)
		_title_parts.append(close)
		_pop_in(close, 1.5)
	_pop_in(play, 1.2)
	_pop_in(how, 1.35)
	var music := _add_music_button(vs)
	# controller: up / down through the buttons, PLAY selected first
	_title_play = play
	PadUI.hook(_title_parts.filter(func(c): return c is BaseButton and c != music) + ([music] if music else []), play)


## CLOSE only makes sense on a desktop: browsers don't let a page close itself, and on phones
## people leave a game with the home button / swipe, like any other app.
func _show_close() -> bool:
	return not OS.has_feature("web") and not UIFit.is_mobile()


## Round speaker button in the bottom-left corner: turns the background music on / off.
## Shares the setting with the pause menu (which also saves it), so it needs the PauseMenu node in Main.
func _add_music_button(vs: Vector2) -> TextureButton:
	var pm := get_tree().get_first_node_in_group("pause_menu")
	if pm == null or not pm.has_method("toggle_music"):
		return null
	var b := TextureButton.new()
	b.texture_normal = _tex("button_round_teal")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	var w := 92.0
	var hk := UIFit.hud_k(get_viewport())                     # corner button: same size as the in-game HUD
	b.size = Vector2(w, w * float(b.texture_normal.get_height()) / b.texture_normal.get_width()) * hk
	b.pivot_offset = b.size * 0.5
	b.position = Vector2(28.0 * hk, vs.y - b.size.y - 24.0 * hk)
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size = Vector2(54, 54) * hk
	icon.position = Vector2((b.size.x - icon.size.x) * 0.5, b.size.y * 0.44 - icon.size.y * 0.5)
	b.add_child(icon)
	var show_state := func():
		var off: bool = pm.is_music_off()
		icon.texture = _tex("icon_sound_off" if off else "icon_sound_on")
		b.self_modulate = Color(0.85, 0.85, 0.85) if off else Color.WHITE
	show_state.call()
	b.button_down.connect(func(): _press(b))
	b.button_up.connect(func(): _release(b))
	b.pressed.connect(func():
		pm.toggle_music()
		show_state.call())
	b.mouse_entered.connect(func():
		if not b.button_pressed and UIFit.hover_ok():         # no hover grow from a finger tap
			create_tween().tween_property(b, "scale", Vector2.ONE * 1.08, 0.12))
	b.mouse_exited.connect(func():
		if not b.button_pressed:
			create_tween().tween_property(b, "scale", Vector2.ONE, 0.12))
	_root.add_child(b)
	_title_parts.append(b)
	_pop_in(b, 1.6)
	return b


func _process(delta: float) -> void:
	_t += delta
	# letters bob gently once they've landed, in a little wave
	for l in _letters:
		if l.get_meta("landed", false) and _mode != "leaving":
			var i: int = l.get_meta("i")
			l.position.y = l.get_meta("base_y") + sin(_t * 2.4 - i * 0.55) * 8.0 * _title_k
			l.rotation = deg_to_rad(sin(_t * 1.7 - i * 0.7) * 3.0)


func _set_title_visible(on: bool) -> void:
	for c in _title_parts:
		var t := create_tween()
		t.tween_property(c, "modulate:a", 1.0 if on else 0.0, 0.2)
		c.mouse_filter = Control.MOUSE_FILTER_STOP if on and c is BaseButton else Control.MOUSE_FILTER_IGNORE
	PadUI.set_enabled(_title_parts, on)


# ---------------------------------------------------------------- how to play book

func _open_book() -> void:
	if _mode != "title":
		return
	_mode = "book"
	_set_title_visible(false)
	_build_book()


## Landscape: the open book, three tips on each page. Portrait: one tall paper page with all six.
func _build_book() -> void:
	var vp := get_viewport()
	var vs := UIFit.size(vp)
	var portrait := UIFit.is_portrait(vp)
	# one bold headline + one short line each, so it can be read at a glance
	var rows_left := [
		["icon_hand", "DRAG BACK, LET GO", "to launch. Tap to stop." if UIFit.is_mobile() else "to launch. Click to stop."],
		["icon_worker", "BOWL THE ANTS", "before they reach your house"],
		["icon_medal_gold", "STRIKES & SPARES", "clear a group in 1 or 2 rolls"],
	]
	var rows_right := [
		["icon_soldier", "SOLDIERS BITE!", "knock their helmet off first"],
		["icon_heart", "STAY ALIVE", "no hearts or house is game over"],
		["icon_berry", "GRAB BLUBES", "roll through one to grow big"],
	]
	var page: Control
	var page_w := 0.0
	var rows_area: Rect2
	var buttons_y := 0.0
	var buttons_area_x := 0.0
	var buttons_area_w := 0.0
	var delay := 0.45
	if portrait:
		page_w = 600.0
		var page_h := 1100.0
		_k = UIFit.menu_k(vp, Vector2(page_w, page_h + 70.0), Vector2(0.94, 0.9)) * ui_scale
		var ps := Vector2(page_w, page_h) * _k
		page = UIFit.card(_tex("card_frame"), ps)
		page.position = (vs - ps) * 0.5 + Vector2(0, 30 * _k)
		_root.add_child(page)
		page.scale = Vector2(0.7, 0.7)
		page.modulate.a = 0.0
		var pt := create_tween().set_parallel(true)
		pt.tween_property(page, "modulate:a", 1.0, 0.15)
		pt.tween_property(page, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		var inner := Rect2(page.position + Vector2(52, 95) * _k, Vector2(page_w - 104.0, page_h - 95.0 - 75.0) * _k)
		var rows_h := inner.size.y - 150.0 * _k
		delay = _rows(rows_left + rows_right, Rect2(inner.position, Vector2(inner.size.x, rows_h)), rows_h / 6.0, delay, [], true)
		buttons_y = inner.end.y - 120.0 * _k
		buttons_area_x = inner.position.x
		buttons_area_w = inner.size.x
	else:
		_k = UIFit.menu_k(vp, Vector2(1200.0, 830.0)) * ui_scale
		page = _sprite("book", minf(1200.0, vs.x / _k * 0.94))
		page_w = page.size.x / _k
		var bs := page.size
		page.position = (vs - bs) * 0.5 + Vector2(0, 30 * _k)
		page.scale = Vector2(0.05, 0.9)
		var t := create_tween()
		t.tween_property(page, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		var left := Rect2(page.position + bs * Vector2(0.075, 0.09), bs * Vector2(0.38, 0.8))
		var right := Rect2(page.position + bs * Vector2(0.545, 0.09), bs * Vector2(0.38, 0.8))
		delay = _rows(rows_left, left, left.size.y / 3.0, delay)
		delay = _rows(rows_right, Rect2(right.position, Vector2(right.size.x, right.size.y * 0.72)), right.size.y * 0.72 / 3.0, delay)
		buttons_area_x = right.position.x
		buttons_area_w = right.size.x
		buttons_y = right.end.y - (190.0 * 161.0 / 362.0) * _k * 1.65   # well clear of the bottom edge of the book
	_book_parts.push_front(page)
	var rib := _sprite("banner_green", minf(640.0, page_w * (0.95 if portrait else 0.6)))
	rib.position = Vector2((vs.x - rib.size.x) * 0.5, page.position.y - rib.size.y * 0.55)
	var title := _label("HOW TO PLAY", 50, CREAM, 12, Color(0.1, 0.4, 0.1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size = Vector2(rib.size.x, rib.size.y * 0.62)
	rib.add_child(title)
	_book_parts.append(rib)
	_pop_in(rib, 0.25)

	# BACK and PLAY side by side at the bottom (of the right page, or of the single page)
	var back := _button("button_blue", "BACK", 190.0, Color(0.05, 0.35, 0.55), _close_book)
	var play := _button("button_green", "PLAY", 190.0, Color(0.1, 0.45, 0.1), _start_game)
	var gap := 20 * _k
	var bx := buttons_area_x + (buttons_area_w - back.size.x - play.size.x - gap) * 0.5
	back.position = Vector2(bx, buttons_y)
	play.position = Vector2(bx + back.size.x + gap, back.position.y)
	_book_parts.append(back)
	_book_parts.append(play)
	_pop_in(back, delay)
	_pop_in(play, delay + 0.08)
	PadUI.hook([back, play], play, true)                 # controller: left / right, PLAY selected first
	play.set_meta("throbs", true)
	var pt2 := create_tween()
	pt2.tween_interval(delay + 0.5)                      # once it has popped in, it starts to throb
	pt2.tween_callback(func(): if is_instance_valid(play) and not play.button_pressed: _throb(play))
	_k = _title_k


## Icon + wrapped text rows down a page, fading in one by one.
## Each row is [icon, headline, short line]. weights: optional share of the height per row.
## centered: the icons + text sit as one block in the middle of the page (the single tall page)
## instead of starting at its left edge.
func _rows(rows: Array, area: Rect2, row_h: float, delay: float, weights: Array = [], centered := false) -> float:
	var y := area.position.y
	# a phone held sideways squeezes the book into a short screen: bump the text up a little
	var tb := 1.2 if UIFit.is_mobile() and not UIFit.is_tablet() and not UIFit.is_portrait(get_viewport()) else 1.0
	var total_w := 0.0
	for w in weights:
		total_w += w
	var icon_s := 80.0 * _k                             # same size on every row, so the text lines up
	var gap := (26.0 if centered else 20.0) * _k
	var x0 := area.position.x
	var text_w := area.size.x - icon_s - gap
	if centered:
		# measure the longest line, then centre icon + text as one block on the page
		var widest := 0.0
		for r in rows:
			widest = maxf(widest, _font.get_string_size(r[1], HORIZONTAL_ALIGNMENT_LEFT, -1, int(32.0 * tb * _k)).x)
			if r.size() > 2:
				widest = maxf(widest, _font.get_string_size(r[2], HORIZONTAL_ALIGNMENT_LEFT, -1, int(24.0 * tb * _k)).x)
		text_w = minf(widest + 4.0 * _k, area.size.x - icon_s - gap)
		x0 = area.position.x + maxf((area.size.x - (icon_s + gap + text_w)) * 0.5, 0.0)
	for ri in rows.size():
		var r = rows[ri]
		if not weights.is_empty():
			row_h = area.size.y * weights[ri] / total_w
		var ic := _sprite(r[0], icon_s / _k)
		ic.size = Vector2(icon_s, icon_s)
		ic.pivot_offset = ic.size * 0.5
		ic.position = Vector2(x0, y + (row_h - icon_s) * 0.5)
		# headline + short line, stacked and centred on the icon
		var l := VBoxContainer.new()
		l.alignment = BoxContainer.ALIGNMENT_CENTER
		l.add_theme_constant_override("separation", int(-2 * _k))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.position = Vector2(x0 + icon_s + gap, y)
		l.size = Vector2(text_w, row_h)
		var head := _label(r[1], 32.0 * tb, BROWN)
		l.add_child(head)
		if r.size() > 2:
			var sub := _label(r[2], 24.0 * tb, Color(0.52, 0.38, 0.3))
			if UIFit.is_mobile() or UIFit.is_portrait(get_viewport()):
				sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # small screens: wrap rather than spill off the page
				sub.custom_minimum_size.x = text_w
			l.add_child(sub)
		_root.add_child(l)
		for c in [ic, l]:
			c.modulate.a = 0.0
			var t := create_tween()
			t.tween_interval(delay)
			t.tween_property(c, "modulate:a", 1.0, 0.25)
			_book_parts.append(c)
		_pop_in(ic, delay)
		delay += 0.12
		y += row_h
	return delay


func _close_book() -> void:
	if _mode != "book":
		return
	_mode = "title"
	PadUI.set_enabled(_book_parts, false)                # let go of the book's buttons before re-selecting PLAY
	for c in _book_parts:
		_stop_throb(c)
		var t := create_tween()
		t.tween_property(c, "modulate:a", 0.0, 0.18)
		t.tween_callback(c.queue_free)
	_book_parts.clear()
	_set_title_visible(true)
	PadUI.focus_default(_title_play)


# ---------------------------------------------------------------- start

func _start_game() -> void:
	if _mode == "leaving":
		return
	_mode = "leaving"
	PadUI.clear()
	PadUI.set_enabled(_title_parts + _book_parts, false)
	for c in _title_parts + _book_parts:
		if is_instance_valid(c):
			_stop_throb(c)
	# letters jump away, everything else shrinks, the backyard un-dims
	for l in _letters:
		var t := create_tween()
		t.tween_interval(randf() * 0.12)
		t.tween_property(l, "position:y", -300.0 * _k, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	# everything else (ribbon, buttons, and the whole book with its text and icons) fades out together,
	# with one tween, so no part of it is left behind for a moment
	var fade := create_tween().set_parallel(true)
	for c in _title_parts + _book_parts:
		if not is_instance_valid(c) or c is Label:            # the letters (the only bare labels) jump instead
			continue
		fade.tween_property(c, "modulate:a", 0.0, 0.25)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := create_tween()
	t.tween_property(_dim, "color:a", 0.0, 0.4)
	t.tween_callback(func():
		var main := get_parent()
		if "waves_on_hold" in main:
			main.waves_on_hold = false
			main._break_left = 1.5                       # a short breath, then wave 1
		if _player and is_instance_valid(_player):
			_player.set_process_input(true)
		if _game_ui:
			_game_ui.visible = true
		queue_free())


func _input(event: InputEvent) -> void:
	if _mode == "leaving":
		return
	if not (event is InputEventKey or event is InputEventJoypadButton) or not event.is_pressed():
		return
	# controller A presses whichever button is selected (handled by the buttons themselves);
	# Enter is a shortcut for PLAY / closing the book when nothing is selected
	var pad := event is InputEventJoypadButton
	var selected := get_viewport().gui_get_focus_owner() != null
	var accept: bool = not pad and not selected and event.is_action_pressed("ui_accept")
	var back: bool = (pad and event.button_index == JOY_BUTTON_B) or (not pad and event.is_action_pressed("ui_cancel"))
	if _mode == "title" and accept:
		get_viewport().set_input_as_handled()
		_start_game()
	elif _mode == "book" and (accept or back):
		get_viewport().set_input_as_handled()
		_close_book()
