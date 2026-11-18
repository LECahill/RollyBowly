extends CanvasLayer
## Game UI made from your sprite sheets:
##   - Wave tab: a spiral-notebook tab hanging from the top of the screen. It drops down with a swing
##     every time a new wave starts ("WAVE 3"), shows "CLEARED!" and a countdown between waves.
##   - Score: a wooden plank in the top-left corner with a star; the number counts up and pops.
##   - Hearts: the rolly polly's health in the top-right corner, full and empty hearts.
##   - House health: a little bar with a house icon floating over the mushroom house. Green, then
##     yellow, then red as it drops; it shakes when the house is bitten.
##   - Pause button (top-right corner): opens the pause menu. Handy on phones, where there's no Esc key.
##   - Game over: a book that flies in and opens, with the run's breakdown: score, waves survived,
##     best combo, strikes, spares, berries, and how many worker / soldier ants you bowled over.
##
## Setup:
##   1. Copy the ui folder into your project so the images are at res://ui/ (book.png, wave_tab.png, ...).
##   2. Right-click Main > Add Child Node > CanvasLayer, name it "GameUI", attach this script.
## It finds Main, the ScoreLabel, the combo counter and the power-ups by itself.
## Phones: everything scales to the screen (see ui_fit.gd). Held upright, the wave tab hangs below the
## top row, and the game-over book becomes a single tall page.

@export var ui_folder := "res://ui/"
@export var ui_scale := 1.0                     ## make everything bigger or smaller (it also follows the window size)
@export var heart_size := 56.0                  ## design pixels
@export var pause_button := true                ## round pause button in the top-right corner
@export var pause_button_size := 68.0           ## design pixels
@export var house_bar := true                   ## health bar floating over the mushroom house
@export var house_bar_width := 230.0            ## design pixels
@export var wave_tab_hold := 2.0                ## seconds "WAVE N" stays down before the tab goes back up
@export var countdown_from := 3                 ## the countdown between waves starts at this number
@export var play_again_delay := 0.8             ## game over: ignore input this long, so a click mid-play doesn't skip the book

const BROWN := Color(0.43, 0.19, 0.16)
const CREAM := Color(1.0, 0.98, 0.9)
const INK := Color(0.36, 0.2, 0.15)

var main: Node
var stats := {"workers": 0, "soldiers": 0, "berries": 0}

var _font: Font
var _root: Control
var _k := 1.0                                    # pixels per design pixel (design = 1080 px tall)
var _tab: Control                                # holder that drops / swings
var _tab_art: TextureRect                        # the spiral notebook card
var _tab_label: Label
var _tab_wave := -1
var _tab_mode := "hidden"                        # hidden / wave / cleared / countdown
var _tab_token := 0
var _tab_tween: Tween
var _plank: TextureRect
var _score_label: Label
var _score_icon: TextureRect
var _shown_score := 0.0
var _score_tween: Tween
var _book_open := false
var _play_btn: TextureButton
var _btn_rest_y := 0.0
var _btn_tween: Tween
var _pulse_tween: Tween
var _restarting := false
var _hearts: HBoxContainer
var _player: Node
var _house: Node3D
var _house_top := 3.0                            # height of the house's top above its origin (measured)
var _hbar: Control
var _hbar_fill: TextureProgressBar
var _hbar_icon: TextureRect
var _hbar_tween: Tween
var _ready_ms := 0
var _pause_btn: TextureButton
var _book_root: Control                          # everything on the game-over book (rebuilt if the screen turns)
var _book_reason := ""
var _book_built := false
var _tab_base_y := 0.0                           # where the tab hangs: the top edge, or below the top row (portrait)
var _resize_token := 0
var _tb := 1.0                                   # text boost on the game-over book (sideways phones)


func _ready() -> void:
	layer = 30
	add_to_group("game_over_screen")
	main = get_parent()
	_font = _load_font()
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_wave_tab()
	_build_score()
	_build_hearts()
	if pause_button and not Net.online:              # online there's no pausing (the others keep playing)
		_build_pause_button()
	_hook_player.call_deferred()
	if house_bar:
		_build_house_bar()
		_hook_house.call_deferred()
	get_viewport().size_changed.connect(_on_resize)
	_layout()
	get_tree().node_added.connect(_on_node_added)
	if main.has_signal("game_ended"):
		main.game_ended.connect(_on_game_ended)


# ---------------------------------------------------------------- stats

func _on_node_added(node: Node) -> void:
	if node.has_signal("knocked_down"):
		node.knocked_down.connect(_on_ant_down)
	elif node.has_signal("collected"):
		node.collected.connect(_on_powerup)


func _on_powerup(kind: String) -> void:
	if kind == "size_up":
		stats.berries += 1


func _on_ant_down(ant: Node) -> void:
	var hits = ant.get("hits_to_knock")
	if hits != null and hits > 1:
		stats.soldiers += 1
	else:
		stats.workers += 1


func _score() -> int:
	var s := main.find_child("ScoreLabel", true, false)
	return s.score if s and "score" in s else 0


## Waves fully cleared: the wave you lost on doesn't count unless it was already cleared.
func _waves_survived() -> int:
	var w: int = main.get("wave") if main.get("wave") != null else 0
	var mid_wave: bool = main.get("_spawning") or get_tree().get_nodes_in_group("mob").size() > 0
	return maxi(w - 1, 0) if mid_wave else w


# ---------------------------------------------------------------- layout helpers

func _load_font() -> Font:
	var f = load(ui_folder + "Fredoka-SemiBold.ttf")
	return f if f is Font else ThemeDB.fallback_font


func _tex(name: String) -> Texture2D:
	var t = load(ui_folder + name + ".png")
	if t == null:
		push_warning("GameUI: missing %s%s.png" % [ui_folder, name])
	return t


func _sprite(name: String, parent: Control) -> TextureRect:
	var r := TextureRect.new()
	r.texture = _tex(name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r


func _label(text: String, size: float, color: Color, parent: Control, outline := 0.0, outline_color := BROWN) -> Label:
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
	l.set_meta("design_size", size)
	l.set_meta("design_outline", outline)
	parent.add_child(l)
	return l


## Size a sprite by its width (design pixels), keeping the image's proportions.
func _size_w(r: TextureRect, w: float) -> Vector2:
	var t := r.texture
	var h := w * (float(t.get_height()) / t.get_width()) if t else w * 0.3
	r.size = Vector2(w, h) * _k
	r.pivot_offset = r.size * 0.5
	return r.size


func _on_resize() -> void:
	_layout()
	# the game-over book is rebuilt for the new shape (e.g. a phone turned sideways), once it settles
	_resize_token += 1
	var token := _resize_token
	await get_tree().create_timer(0.25, true, false, true).timeout
	if token == _resize_token and _book_built and not _restarting and is_inside_tree():
		_rebuild_book()


func _layout() -> void:
	_k = UIFit.hud_k(get_viewport()) * ui_scale
	for l in _root.find_children("*", "Label", true, false):
		if _book_root and _book_root.is_ancestor_of(l):
			continue                                      # the book sizes its own text
		if l.has_meta("design_size"):
			l.label_settings.font_size = maxi(int(l.get_meta("design_size") * _k), 8)
			l.label_settings.outline_size = maxi(int(l.get_meta("design_outline") * _k), 0)
	var vw := get_viewport().get_visible_rect().size.x
	# wave tab, top centre: the spiral notebook card, text on its cream page
	var ts := _size_w(_tab_art, 300.0)
	_tab_art.position = Vector2.ZERO
	_tab.size = ts
	_tab.pivot_offset = Vector2(ts.x * 0.5, 0.0)          # swings from the top, where its rings are
	_tab.position.x = (vw - ts.x) * 0.5
	# held upright there's no room beside the score and hearts: the tab hangs just below them
	var was_base := _tab_base_y
	_tab_base_y = UIFit.top_bar_bottom(get_viewport()) if UIFit.is_portrait(get_viewport()) else 0.0
	if _tab.position.y > -ts.y * 0.5:                    # showing right now: move it along
		_tab.position.y += _tab_base_y - was_base
	_tab_label.position = Vector2(0, ts.y * 0.42)       # the cream page under the green strip
	_tab_label.size = Vector2(ts.x, ts.y * 0.5)
	# score plank, top left
	var ps := _size_w(_plank, 330.0)
	_plank.position = Vector2(24, 20) * _k
	_score_icon.size = Vector2(ps.y * 0.95, ps.y * 0.95)
	_score_icon.position = Vector2(ps.x * 0.012, ps.y * -0.02)
	_score_icon.pivot_offset = _score_icon.size * 0.5
	_score_label.position = Vector2(ps.x * 0.2, 0)
	_score_label.size = Vector2(ps.x * 0.76, ps.y * 0.92)
	# hearts, top right
	if _hearts:
		for h in _hearts.get_children():
			h.custom_minimum_size = Vector2.ONE * heart_size * _k
			h.pivot_offset = h.custom_minimum_size * 0.5
		_hearts.add_theme_constant_override("separation", int(8 * _k))
		_hearts.reset_size()
		var right_edge := vw - 24 * _k
		if _pause_btn:
			var pb := pause_button_size * _k
			_pause_btn.size = Vector2(pb, pb * float(_pause_btn.texture_normal.get_height()) / _pause_btn.texture_normal.get_width())
			_pause_btn.pivot_offset = _pause_btn.size * 0.5
			_pause_btn.position = Vector2(right_edge - _pause_btn.size.x, 16 * _k)
			right_edge = _pause_btn.position.x - 16 * _k
		_hearts.position = Vector2(right_edge - _hearts.size.x, 22 * _k)
	# house bar (positioned over the house every frame)
	if _hbar:
		var bar_scale := house_bar_width * _k / 400.0
		_hbar_fill.scale = Vector2.ONE * bar_scale
		var bh := 56.0 * bar_scale
		_hbar_icon.size = Vector2(bh, bh) * 2.3
		_hbar_icon.position = Vector2(-_hbar_icon.size.x * 0.7, -bh * 0.75)
		_hbar_fill.position = Vector2(0, 0)
		_hbar.size = Vector2(house_bar_width * _k, bh)
		_hbar.pivot_offset = _hbar.size * 0.5


# ---------------------------------------------------------------- wave tab

func _build_wave_tab() -> void:
	_tab = Control.new()
	_tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tab)
	_tab_art = _sprite("wave_tab", _tab)
	_tab_label = _label("", 40, INK, _tab)
	_tab_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tab_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tab.position.y = -400.0                            # hidden until the first wave


func _process(_delta: float) -> void:
	_place_house_bar()
	if _pause_btn:
		var can: bool = not _book_open and main != null and main.get("game_over") != true and main.get("waves_on_hold") != true
		_pause_btn.visible = can
	if main == null or _book_open:
		return
	_update_score()
	var w: int = main.get("wave") if main.get("wave") != null else 0
	var game_over: bool = main.get("game_over") == true
	if game_over:
		return
	var cleared: bool = w > 0 and not main.get("_spawning") and get_tree().get_nodes_in_group("mob").is_empty()
	if w != _tab_wave and w > 0:
		# new wave: show "WAVE N" for a moment, then tuck the tab away
		_tab_wave = w
		var was_down := _tab_mode == "cleared" or _tab_mode == "countdown"
		_tab_mode = "wave"
		if was_down:
			_tab_label.text = "WAVE %d" % w                # already hanging there after the countdown
			_bounce_tab()
		else:
			_drop_tab("WAVE %d" % w)
		_retract_tab_later(wave_tab_hold)
	elif cleared and (_tab_mode == "wave" or _tab_mode == "hidden"):
		_tab_mode = "cleared"
		_drop_tab("CLEARED!")
	elif _tab_mode == "cleared" or _tab_mode == "countdown":
		var left: float = main.get("_break_left") if main.get("_break_left") != null else 0.0
		var n := ceili(left)
		if left > 0.0 and n <= countdown_from:            # only the last few seconds: 3, 2, 1
			var text := "NEXT IN %d" % n
			if _tab_label.text != text:
				_tab_mode = "countdown"
				_tab_label.text = text
				_bounce_tab(0.06)


## The tab drops down from above the screen with `text` on it, bouncing and swinging on its rings.
## If it's already showing, it's pulled up first and the text changes while it's out of sight.
func _drop_tab(text: String) -> void:
	_tab_token += 1                                       # cancels any pending "go back up"
	var h := _tab.size.y
	if _tab_tween:
		_tab_tween.kill()
	_tab_tween = create_tween()
	if _tab.position.y > -h * 0.5:
		_tab_tween.tween_property(_tab, "position:y", -h * 1.1, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	else:
		_tab.position.y = -h * 1.1
	_tab_tween.tween_callback(func(): _tab_label.text = text)
	_tab_tween.tween_property(_tab, "position:y", _tab_base_y - h * 0.06, 0.55).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	_tab_tween.parallel().tween_method(_swing, 0.0, 1.0, 1.4)
	_tab.scale = Vector2.ONE


## After `hold` seconds the tab slides back up out of sight (unless something else dropped it since).
func _retract_tab_later(hold: float) -> void:
	_tab_token += 1
	var token := _tab_token
	await get_tree().create_timer(hold + 0.6).timeout     # + the time it takes to drop down
	if token != _tab_token or not is_inside_tree():
		return
	_tab_mode = "hidden"
	if _tab_tween:
		_tab_tween.kill()
	_tab_tween = create_tween()
	_tab_tween.tween_property(_tab, "position:y", _tab_base_y - _tab.size.y * 0.25, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tab_tween.tween_property(_tab, "position:y", -_tab.size.y * 1.1, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


func _swing(k: float) -> void:
	_tab.rotation = deg_to_rad(9.0 * sin(k * TAU * 2.5) * (1.0 - k))


func _bounce_tab(amount := 0.12) -> void:
	_tab.scale = Vector2.ONE * (1.0 + amount)
	create_tween().tween_property(_tab, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ---------------------------------------------------------------- pause button

func _build_pause_button() -> void:
	_pause_btn = TextureButton.new()
	_pause_btn.texture_normal = _tex("button_pause")
	if _pause_btn.texture_normal == null:
		_pause_btn.free()
		_pause_btn = null
		return
	_pause_btn.ignore_texture_size = true
	_pause_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_pause_btn.focus_mode = Control.FOCUS_NONE           # Start / Esc already pause with a controller or keyboard
	_pause_btn.add_to_group("blocks_bowling")            # tapping it never starts a launch (player.gd checks this)
	_root.add_child(_pause_btn)
	_pause_btn.button_down.connect(func():
		create_tween().tween_property(_pause_btn, "scale", Vector2(1.08, 0.88), 0.06))
	_pause_btn.button_up.connect(func():
		create_tween().tween_property(_pause_btn, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))
	_pause_btn.pressed.connect(func():
		var pm := get_tree().get_first_node_in_group("pause_menu")
		if pm and pm.has_method("open"):
			pm.open())
	_pause_btn.mouse_entered.connect(func():
		if not _pause_btn.button_pressed and UIFit.hover_ok():   # no hover grow from a finger tap
			create_tween().tween_property(_pause_btn, "scale", Vector2.ONE * 1.08, 0.12))
	_pause_btn.mouse_exited.connect(func():
		if not _pause_btn.button_pressed:
			create_tween().tween_property(_pause_btn, "scale", Vector2.ONE, 0.12))


# ---------------------------------------------------------------- hearts

func _build_hearts() -> void:
	_hearts = HBoxContainer.new()
	_hearts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hearts)


func _hook_player() -> void:
	_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		return
	if _player.has_signal("hp_changed"):
		_player.hp_changed.connect(_on_player_hp)
	_on_player_hp(_player.get("hp"), _player.get("max_hp"), false)


## One heart per point of the bug's health: full for what's left, empty for what's lost.
func _on_player_hp(hp, max_hp, animate := true) -> void:
	if hp == null or max_hp == null:
		return
	while _hearts.get_child_count() < max_hp:            # (re)build if max health changed
		var r := _sprite("heart_full", _hearts)
		r.custom_minimum_size = Vector2.ONE * heart_size * _k
		r.pivot_offset = r.custom_minimum_size * 0.5
	while _hearts.get_child_count() > max_hp:
		_hearts.get_child(_hearts.get_child_count() - 1).free()
	for i in _hearts.get_child_count():
		var heart: TextureRect = _hearts.get_child(i)
		var full: bool = i < hp
		var was_full: bool = heart.get_meta("full", true)
		heart.set_meta("full", full)
		heart.texture = _tex("heart_full" if full else "heart_empty")
		if not animate or full == was_full:
			continue
		heart.pivot_offset = heart.size * 0.5
		if full:                                            # healed: the heart pops back in
			heart.scale = Vector2.ONE * 1.5
			create_tween().tween_property(heart, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		else:                                               # lost: a red flash, a shake, then it empties
			heart.texture = _tex("heart_full")
			heart.modulate = Color(1.6, 0.6, 0.6)
			var t := create_tween()
			for k in 5:
				t.tween_property(heart, "rotation", deg_to_rad(14.0 if k % 2 == 0 else -14.0), 0.05)
			t.tween_property(heart, "rotation", 0.0, 0.05)
			t.tween_callback(func():
				heart.texture = _tex("heart_empty")
				heart.modulate = Color.WHITE
				heart.scale = Vector2.ONE * 0.6)
			t.tween_property(heart, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_layout.call_deferred()


# ---------------------------------------------------------------- house health bar

func _build_house_bar() -> void:
	_hbar = Control.new()
	_hbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hbar)
	_root.move_child(_hbar, 0)                           # drawn first = underneath the wave tab, score and hearts
	_hbar_fill = TextureProgressBar.new()
	_hbar_fill.texture_under = _tex("bar_under")
	_hbar_fill.texture_progress = _tex("bar_green")
	_hbar_fill.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	_hbar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbar_fill.max_value = 100
	_hbar_fill.value = 100
	_hbar_fill.step = 0.01
	_hbar.add_child(_hbar_fill)
	_hbar_icon = _sprite("icon_house", _hbar)
	_hbar.visible = false


func _hook_house() -> void:
	_house = main.get("house") if main.get("house") else get_tree().get_first_node_in_group("house")
	if _house == null:
		return
	# how tall is the house? (top of all its meshes, in its own space)
	var top := 0.0
	for mi in _house.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = mi.global_transform * mi.get_aabb()
		top = maxf(top, b.end.y - _house.global_position.y)
	if top > 0.0:
		_house_top = top
	if _house.has_signal("health_changed"):
		_house.health_changed.connect(_on_house_health)
	_on_house_health(_house.get("hp"), _house.get("max_hp"), false)


func _on_house_health(hp, max_hp, animate := true) -> void:
	if hp == null or max_hp == null or max_hp <= 0:
		return
	var old := _hbar_fill.value
	_hbar_fill.max_value = max_hp
	var frac: float = float(hp) / max_hp
	_hbar_fill.texture_progress = _tex("bar_green" if frac > 0.5 else ("bar_yellow" if frac > 0.25 else "bar_red"))
	if _hbar_tween:
		_hbar_tween.kill()
	if not animate:
		_hbar_fill.value = hp
		return
	_hbar_tween = create_tween()
	_hbar_tween.tween_property(_hbar_fill, "value", float(hp), 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if hp < old:                                          # bitten: shake
		var s := create_tween()
		for i in 4:
			s.tween_property(_hbar, "rotation", deg_to_rad(6.0 if i % 2 == 0 else -6.0), 0.04)
		s.tween_property(_hbar, "rotation", 0.0, 0.05)
	else:                                                 # healed between waves: pop
		_hbar.scale = Vector2.ONE * 1.2
		create_tween().tween_property(_hbar, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _place_house_bar() -> void:
	if _hbar == null:
		return
	var cam := get_viewport().get_camera_3d()
	if _book_open or cam == null or _house == null or not is_instance_valid(_house):
		_hbar.visible = false
		return
	var top := _house.global_position + Vector3.UP * (_house_top + 1.2)
	if cam.is_position_behind(top):
		_hbar.visible = false
		return
	_hbar.visible = true
	var p := cam.unproject_position(top)
	_hbar.position = p - Vector2(_hbar.size.x * 0.5, _hbar.size.y)


# ---------------------------------------------------------------- score

func _build_score() -> void:
	_plank = _sprite("score_plank", _root)
	_score_icon = _sprite("icon_star", _plank)
	_score_label = _label("0", 46, CREAM, _plank, 10)
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


func _set_shown_score(v: float) -> void:
	_shown_score = v
	_score_label.text = str(int(round(v)))


func _update_score() -> void:
	var real := _score()
	if real == int(round(_shown_score)) or (_score_tween and _score_tween.is_running()):
		return
	var from := _shown_score
	_score_tween = create_tween()
	_score_tween.tween_method(_set_shown_score, from, float(real), clampf(abs(real - from) * 0.03, 0.15, 0.6))
	# pop
	_score_icon.scale = Vector2.ONE * 1.35
	_score_icon.rotation = deg_to_rad(-15)
	var p := create_tween().set_parallel(true)
	p.tween_property(_score_icon, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	p.tween_property(_score_icon, "rotation", 0.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_plank.scale = Vector2.ONE * 1.06
	p.tween_property(_plank, "scale", Vector2.ONE, 0.25)


# ---------------------------------------------------------------- game over book

func _on_game_ended(reason: String) -> void:
	_book_open = true
	_ready_ms = Time.get_ticks_msec() + int(play_again_delay * 1000.0)
	await get_tree().create_timer(0.7, true, false, true).timeout   # let the moment land first
	if not is_inside_tree():
		return
	_show_book(reason)


func _show_book(reason: String) -> void:
	_book_reason = reason
	_score_label.text = str(_score())
	# fold the HUD away
	create_tween().tween_property(_tab, "position:y", -_tab.size.y * 1.2, 0.3)
	if _hearts:
		create_tween().tween_property(_hearts, "modulate:a", 0.0, 0.3)
	var combo_ui := get_tree().get_first_node_in_group("combo")
	if combo_ui and combo_ui.has_method("hide_all"):
		combo_ui.hide_all()
	_book_root = Control.new()
	_book_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_book_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_book_root)
	_build_book(false)


## The screen changed shape while the book was open (a phone turned): build it again to fit.
func _rebuild_book() -> void:
	_build_book(true)


## Landscape: the open book, score on the left page and the ants on the right.
## Portrait (phone held upright): one tall paper page with everything stacked.
func _build_book(again: bool) -> void:
	_stop_pulse()                                          # the old PLAY AGAIN's throb (a looping tween) goes first
	for c in _book_root.get_children():
		c.free()
	_book_built = true
	var vp := get_viewport()
	var vs := UIFit.size(vp)
	var hud_k := _k
	var portrait := UIFit.is_portrait(vp)
	_tb = 1.15 if UIFit.is_mobile() and not portrait else 1.0   # sideways phone: a little bigger text

	var dim := ColorRect.new()
	dim.color = Color(0.12, 0.08, 0.05, 0.5 if again else 0.0)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP           # the book blocks the game behind it
	_book_root.add_child(dim)
	if not again:
		create_tween().tween_property(dim, "color:a", 0.5, 0.4)

	var page: Control
	var left: Rect2
	var right: Rect2
	var page_w := 0.0                                      # design pixels
	if portrait:
		page_w = 600.0
		var page_h := 1240.0
		# the card art's paper stops this far above its bottom edge (below that: the curled corner and
		# the page's bottom strip), so QUIT / PLAY AGAIN sit above it, on the paper itself
		var paper_bottom := 130.0
		_k = UIFit.menu_k(vp, Vector2(page_w, page_h + 70.0), Vector2(0.94, 0.9))
		var ps := Vector2(page_w, page_h) * _k
		page = UIFit.card(_tex("card_frame"), ps)
		page.position = (vs - ps) * 0.5 + Vector2(0, 30 * _k)
		_book_root.add_child(page)
		var inner := Rect2(page.position + Vector2(70, 92) * _k, Vector2(page_w - 140.0, page_h - 92.0 - 70.0) * _k)
		left = Rect2(inner.position, Vector2(inner.size.x, 556.0 * _k))
		var right_top := 92.0 + 572.0
		right = Rect2(inner.position + Vector2(0, 572.0 * _k), Vector2(inner.size.x, (page_h - paper_bottom - right_top) * _k))
		page.scale = Vector2(0.7, 0.7)
		page.modulate.a = 0.0
		var pt := create_tween().set_parallel(true)
		pt.tween_property(page, "modulate:a", 1.0, 0.15)
		pt.tween_property(page, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		_k = UIFit.menu_k(vp, Vector2(1200.0, 713.0 + 110.0))
		page = _sprite("book", _book_root)
		page_w = minf(1200.0, vs.x / _k * 0.94)
		var bs := _size_w(page, page_w)
		page.position = (vs - bs) * 0.5 + Vector2(0, 30 * _k)
		left = Rect2(page.position + bs * Vector2(0.075, 0.09), bs * Vector2(0.38, 0.78))
		right = Rect2(page.position + bs * Vector2(0.545, 0.09), bs * Vector2(0.38, 0.78))
		# fly in closed (squashed to its spine), then pop open
		page.scale = Vector2(0.04, 0.6)
		page.modulate.a = 0.0
		var t := create_tween()
		t.tween_property(page, "modulate:a", 1.0, 0.15)
		t.parallel().tween_property(page, "scale", Vector2(0.06, 0.9), 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(page, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# title ribbon above the page
	var banner := _sprite("banner_red", _book_root)
	var rs := _size_w(banner, minf(640.0, page_w * (0.95 if portrait else 0.6)))
	banner.position = Vector2((vs.x - rs.x) * 0.5, page.position.y - rs.y * 0.55)
	var title := _label("GAME OVER", 50, CREAM, banner, 12)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size = Vector2(rs.x, rs.y * 0.62)
	banner.scale = Vector2.ZERO
	var bt0 := create_tween()
	bt0.tween_interval(0.4)
	bt0.tween_property(banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	_book_content(left, right, _book_reason, 0.6 if again else 1.0, portrait)
	_k = hud_k


## What's written in the book: the score and the run's highlights in `left`, the ants in `right`,
## with QUIT and PLAY AGAIN at the bottom of `right`.
## compact: the single tall page (portrait). The ant rows sit a little closer together so the
## buttons fit higher up, on the paper instead of the card's curled bottom edge.
func _book_content(left: Rect2, right: Rect2, reason: String, delay: float, compact := false) -> void:
	var score := _score()
	var combo := get_tree().get_first_node_in_group("combo")
	var msg := "The house was overrun!" if reason == "house" else "Your rolly polly was overwhelmed!"
	if reason == "win":
		msg = "Last house standing - YOU WIN!"
	elif Net.online:
		var place := int(Net.me().get("place", 0))
		if place > 0:
			msg += "  (%s of %d)" % [Net.ordinal(place), Net.match_size]

	# ---- left page: the score, then the run's highlights
	delay = _page_text(msg, 26, INK, Rect2(left.position, Vector2(left.size.x, left.size.y * 0.1)), delay)
	delay = _page_text("FINAL SCORE", 30, Color(0.62, 0.42, 0.2), Rect2(left.position + Vector2(0, left.size.y * 0.12), Vector2(left.size.x, left.size.y * 0.1)), delay)
	var big := Rect2(left.position + Vector2(0, left.size.y * 0.21), Vector2(left.size.x, left.size.y * 0.2))
	delay = _big_score(score, big, delay)
	var rows := [
		["icon_house", "Waves survived", _waves_survived()],
		["icon_bolt", "Best combo", combo.best_combo if combo else 0],
		["icon_medal_gold", "Strikes", combo.strikes if combo else 0],
		["icon_medal_silver", "Spares", combo.get("spares") if combo and combo.get("spares") != null else 0],
		["icon_berry", "Blubes eaten", stats.berries],
	]
	var row_h := left.size.y * 0.115
	var y := left.position.y + left.size.y * 0.44
	for r in rows:
		delay = _stat_row(r[0], r[1], r[2], Rect2(left.position.x, y, left.size.x, row_h), delay)
		y += row_h * 1.02

	# ---- right page: the ants
	delay = _page_text("ANTS BOWLED", 34, Color(0.62, 0.42, 0.2), Rect2(right.position, Vector2(right.size.x, right.size.y * 0.12)), delay)
	var arow := right.size.y * (0.19 if compact else 0.2)
	y = right.position.y + right.size.y * (0.15 if compact else 0.16)
	for r in [["icon_worker", "Worker ants", stats.workers], ["icon_soldier", "Soldier ants", stats.soldiers]]:
		delay = _stat_row(r[0], r[1], r[2], Rect2(right.position.x, y, right.size.x, arow), delay, true)
		y += arow * 1.05
	var line := ColorRect.new()
	line.color = Color(0.75, 0.55, 0.4, 0.7)
	line.size = Vector2(right.size.x * 0.9, 4 * _k)
	line.position = Vector2(right.position.x + right.size.x * 0.05, y + arow * 0.05)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_book_root.add_child(line)
	_fade_in(line, delay)
	delay = _stat_row("", "Total", stats.workers + stats.soldiers, Rect2(right.position.x, y + arow * 0.15, right.size.x, arow * 0.8), delay, true)

	# ---- play again button
	var btn := TextureButton.new()
	btn.texture_normal = _tex("button_green")
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	var bsz := Vector2(200, 200 * 161.0 / 362.0) * _k
	var gap := 18.0 * _k
	btn.size = bsz
	btn.pivot_offset = bsz * 0.5
	var bx := right.position.x + (right.size.x - bsz.x * 2.0 - gap) * 0.5
	btn.position = Vector2(bx + bsz.x + gap, right.end.y - bsz.y * 1.05)
	var quit := _add_quit_button(Vector2(bx, btn.position.y), bsz, delay)
	_book_root.add_child(btn)
	var bl := _label("WATCH" if Net.online else "PLAY AGAIN", 26.0 * _tb, CREAM, btn, 8, Color(0.1, 0.45, 0.1))
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bl.size = Vector2(bsz.x, bsz.y * 0.82)
	_play_btn = btn
	_btn_rest_y = btn.position.y
	btn.button_down.connect(_press_button)
	btn.button_up.connect(_release_button)
	btn.pressed.connect(_play_again)
	btn.mouse_entered.connect(func():
		if not btn.button_pressed and UIFit.hover_ok():       # no hover grow from a finger tap
			_stop_pulse()
			create_tween().tween_property(btn, "scale", Vector2.ONE * 1.08, 0.12))
	btn.mouse_exited.connect(func():
		if not btn.button_pressed and not _restarting:
			var back := create_tween()
			back.tween_property(btn, "scale", Vector2.ONE, 0.12)
			back.tween_callback(func(): _pulse(btn)))      # pick the throb back up after a hover
	btn.scale = Vector2.ZERO
	var bt := create_tween()
	bt.tween_interval(delay + 0.2)
	bt.tween_property(btn, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	bt.tween_callback(func(): _pulse(btn))
	PadUI.hook([quit, btn], btn, true)                   # controller: left / right, PLAY AGAIN selected first
	_ready_ms = maxi(_ready_ms, Time.get_ticks_msec() + int((delay + 0.4) * 1000.0))


## QUIT: back to the title screen (the main menu).
func _add_quit_button(pos: Vector2, bsz: Vector2, delay: float) -> TextureButton:
	var q := TextureButton.new()
	q.texture_normal = _tex("button_red")
	q.ignore_texture_size = true
	q.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	q.size = bsz
	q.pivot_offset = bsz * 0.5
	q.position = pos
	_book_root.add_child(q)
	var ql := _label("QUIT", 26.0 * _tb, CREAM, q, 8, Color(0.55, 0.1, 0.12))
	ql.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ql.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ql.size = Vector2(bsz.x, bsz.y * 0.82)
	var rest_y := pos.y
	q.button_down.connect(func():
		var t := create_tween().set_parallel(true)
		t.tween_property(q, "scale", Vector2(1.04, 0.86), 0.06)
		t.tween_property(q, "position:y", rest_y + 7.0 * _k, 0.06)
		t.tween_property(q, "modulate", Color(0.85, 0.85, 0.85), 0.06))
	q.button_up.connect(func():
		var t := create_tween().set_parallel(true)
		t.tween_property(q, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(q, "position:y", rest_y, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(q, "modulate", Color.WHITE, 0.1))
	q.pressed.connect(_quit_to_menu)
	q.mouse_entered.connect(func():
		if not q.button_pressed and UIFit.hover_ok():         # no hover grow from a finger tap
			create_tween().tween_property(q, "scale", Vector2.ONE * 1.08, 0.12))
	q.mouse_exited.connect(func():
		if not q.button_pressed:
			create_tween().tween_property(q, "scale", Vector2.ONE, 0.12))
	q.scale = Vector2.ZERO
	var t := create_tween()
	t.tween_interval(delay + 0.15)
	t.tween_property(q, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return q


func _quit_to_menu() -> void:
	if Time.get_ticks_msec() < _ready_ms or _restarting:
		return
	_restarting = true
	PadUI.clear()
	await get_tree().create_timer(0.18, true, false, true).timeout   # let the button spring back first
	Engine.time_scale = 1.0
	Net.leave()
	Net._go(Net.MENU_SCENE)                              # the connect menu is the front door now (solo and online)


func _page_text(text: String, size: float, color: Color, area: Rect2, delay: float) -> float:
	var l := _label(text, size, color, _book_root)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.position = area.position
	l.size = area.size
	_fade_in(l, delay)
	return delay + 0.12


func _big_score(score: int, area: Rect2, delay: float) -> float:
	var star := _sprite("icon_star", _book_root)
	var s := area.size.y * 0.9
	star.size = Vector2(s, s)
	star.pivot_offset = star.size * 0.5
	var num := _label("0", 96, Color(0.95, 0.55, 0.15), _book_root, 14)
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var text_w := _font.get_string_size(str(score), HORIZONTAL_ALIGNMENT_LEFT, -1, num.label_settings.font_size).x
	var total := s + 12 * _k + text_w
	star.position = Vector2(area.position.x + (area.size.x - total) * 0.5, area.position.y + (area.size.y - s) * 0.5)
	num.position = Vector2(star.position.x + s + 12 * _k, area.position.y)
	num.size = Vector2(text_w + 40 * _k, area.size.y)
	_fade_in(star, delay)
	_fade_in(num, delay)
	var t := create_tween()
	t.tween_interval(delay)
	t.tween_method(func(v: float): num.text = str(int(round(v))), 0.0, float(score), clampf(score * 0.004, 0.5, 1.6)).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_callback(func(): _pop(num); _pop(star))
	return delay + 0.5


## One line on a page: icon, name, and a number that counts up.
func _stat_row(icon: String, text: String, value: int, area: Rect2, delay: float, big := false) -> float:
	var h := area.size.y
	var x := area.position.x + area.size.x * 0.04
	if icon != "":
		var ic := _sprite(icon, _book_root)
		ic.size = Vector2(h, h) * 0.9
		ic.pivot_offset = ic.size * 0.5
		ic.position = Vector2(x, area.position.y + h * 0.05)
		_fade_in(ic, delay)
	var name_l := _label(text, (40.0 if big else 30.0) * _tb, INK, _book_root)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.position = Vector2(x + h * 1.05, area.position.y)
	name_l.size = Vector2(area.size.x * 0.6, h)
	var num := _label("0", (48.0 if big else 34.0) * _tb, Color(0.85, 0.42, 0.2), _book_root)
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	num.position = Vector2(area.position.x, area.position.y)
	num.size = Vector2(area.size.x * 0.94, h)
	_fade_in(name_l, delay)
	_fade_in(num, delay)
	var t := create_tween()
	t.tween_interval(delay + 0.1)
	t.tween_method(func(v: float): num.text = ("x%d" if text == "Best combo" else "%d") % int(round(v)), 0.0, float(value), clampf(value * 0.05, 0.2, 0.8))
	t.tween_callback(func(): _pop(num))
	return delay + 0.18


func _fade_in(c: CanvasItem, delay: float) -> void:
	c.modulate.a = 0.0
	var t := create_tween()
	t.tween_interval(delay)
	t.tween_property(c, "modulate:a", 1.0, 0.2)


func _pop(c: Control) -> void:
	c.pivot_offset = c.size * 0.5
	c.scale = Vector2.ONE * 1.25
	create_tween().tween_property(c, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## PLAY AGAIN pressed down: it squashes and sinks a little, like a real button.
func _press_button() -> void:
	if _play_btn == null:
		return
	_stop_pulse()
	if _btn_tween:
		_btn_tween.kill()
	_btn_tween = create_tween().set_parallel(true)
	_btn_tween.tween_property(_play_btn, "scale", Vector2(1.04, 0.86), 0.06)
	_btn_tween.tween_property(_play_btn, "position:y", _btn_rest_y + 7.0 * _k, 0.06)
	_btn_tween.tween_property(_play_btn, "modulate", Color(0.85, 0.85, 0.85), 0.06)


## ...and springs back up when let go.
func _release_button() -> void:
	if _play_btn == null:
		return
	if _btn_tween:
		_btn_tween.kill()
	_btn_tween = create_tween().set_parallel(true)
	_btn_tween.tween_property(_play_btn, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_btn_tween.tween_property(_play_btn, "position:y", _btn_rest_y, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_btn_tween.tween_property(_play_btn, "modulate", Color.WHITE, 0.1)


func _stop_pulse() -> void:
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null


func _pulse(c: Control) -> void:
	_stop_pulse()
	var t := create_tween().set_loops()
	_pulse_tween = t
	t.tween_property(c, "scale", Vector2.ONE * 1.05, 0.5).set_trans(Tween.TRANS_SINE)
	t.tween_property(c, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_SINE)


## Keyboard shortcut for the PLAY AGAIN button (Enter). A controller's A presses whichever button
## is selected (see pad_ui.gd), so it isn't handled here. Clicks and taps are
## ignored here on purpose: your "Accept" action includes the mouse button, so a tap anywhere
## used to restart. With the mouse or a finger, only the button itself restarts the game.
func _input(event: InputEvent) -> void:
	if not _book_open or Time.get_ticks_msec() < _ready_ms:
		return
	if not event is InputEventKey or get_viewport().gui_get_focus_owner() != null:
		return
	var accept: bool = InputMap.has_action("Accept") and event.is_action_pressed("Accept")
	if accept or event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_play_again()


func _play_again() -> void:
	if Time.get_ticks_msec() < _ready_ms or _restarting:
		return
	if Net.online:
		_close_book_to_watch()                           # online: no restarting alone, watch the others finish
		return
	_restarting = true
	PadUI.clear()
	if _play_btn and not _play_btn.button_pressed:       # Enter / A: show the press too
		_press_button()
		await get_tree().create_timer(0.08, true, false, true).timeout
		_release_button()
	await get_tree().create_timer(0.18, true, false, true).timeout   # let the button spring back first
	Engine.time_scale = 1.0
	get_tree().reload_current_scene()


## Online, after you're knocked out (or you won): fold the book away and watch the scoreboard and chat.
## The server brings everyone back to the lobby when the match ends.
func _close_book_to_watch() -> void:
	_book_open = false
	_stop_pulse()
	PadUI.clear()
	if _book_root:
		var t := create_tween()
		t.tween_property(_book_root, "modulate:a", 0.0, 0.25)
		t.tween_callback(_book_root.queue_free)
		_book_root = null
	_book_built = false
