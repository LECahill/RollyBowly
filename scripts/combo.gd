extends CanvasLayer
## Combo counter and STRIKE / SPARE pop-ups.
##
## Setup: right-click Main > Add Child Node > CanvasLayer, name it "Combo", attach this script. That's it:
## it finds the rolly polly and the ScoreLabel by itself.
##
##   Combo  - every ant bowled in the same roll is worth one more point than the last (1, 2, 3, 4...),
##            with a rising "+N" over each ant, a counter at the top and a higher clack each time.
##            Ants knocked over by other flying ants count too, like pins taking out pins.
##   STRIKE - bowl over a whole group of ants in a single roll: big banner, slow-mo, shake, bonus points.
##   SPARE  - clear a row in exactly two rolls (only rolls that hit that row count): smaller bonus.
##            Taking three or more rolls to clear it gives no bonus, like an open frame in bowling.

@export var score_label: Label               ## empty = finds the node called "ScoreLabel" automatically

@export_group("Points")
@export var combo_points := true             ## the nth ant in one roll is worth n points (off = every ant is 1)
@export var strike_bonus := 10
@export var spare_bonus := 3
@export var min_row_for_strike := 3          ## rows smaller than this don't count for STRIKE / SPARE

@export_group("Feel")
@export var hit_pitch_step := 0.08           ## each ant in a combo clacks this much higher (uses the ant's HitSound)
@export var max_hit_pitch := 2.0
@export var strike_slowmo := 0.3             ## game speed during the STRIKE moment (1 = no slow-mo)
@export var strike_slowmo_time := 0.45       ## how long the slow-mo lasts (real seconds)
@export var strike_shake := 0.8
@export var popup_height := 1.6              ## the "+N" appears this high above the ant
@export var popup_size := 0.012              ## world size of the "+N" text
@export var strike_sound: AudioStream        ## optional: plays on STRIKE
@export var spare_sound: AudioStream         ## optional: plays on SPARE
@export var combo_sound: AudioStream         ## optional: plays when a roll of 2+ ants ends
@export var settle_time := 0.5               ## after the roll ends, wait this long with no more ants falling before the combo banner

signal strike_scored(pos: Vector3)       # where the last pin of a STRIKE fell (power-up drops listen for this)

const STRIKE_COLOR := Color(1.0, 0.82, 0.15)
const SPARE_COLOR := Color(0.55, 0.9, 1.0)

var combo := 0                 # ants bowled in the current roll
var roll_points := 0           # points earned in the current roll
var best_combo := 0
var strikes := 0
var spares := 0
var _row_banner_ms := -100000  # when the last STRIKE / SPARE banner went up
var _pending_end := false      # roll ended, waiting for flying ants to settle before the banner
var _settle_left := 0.0
var _row_down := {}            # row id -> ants of that row bowled in total
var _row_rolls := {}           # row id -> how many different rolls have hit that row
var _row_last_roll := {}       # row id -> the roll that last hit it
var _roll_index := 0           # counts launches
var _player: Node
var _counter: Label
var _banner: Label
var _sub: Label
var _audio: AudioStreamPlayer
var _counter_tween: Tween
var _banner_tween: Tween
var _k := 1.0                                 # screen scale (1 = 1080p desktop; see ui_fit.gd)


func _ready() -> void:
	layer = 50
	add_to_group("combo")                     # flying ants report the ants they knock over here
	process_mode = Node.PROCESS_MODE_ALWAYS
	_reset_time_scale()
	_counter = _make_label(40, Color.WHITE)
	_counter.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_counter.offset_left = -200.0
	_counter.offset_right = 200.0
	_counter.offset_top = 175.0              # below the wave header
	_counter.offset_bottom = 235.0
	_banner = _make_label(84, STRIKE_COLOR)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.offset_bottom = -320.0           # upper middle of the screen, clear of the action
	_sub = _make_label(30, Color.WHITE)
	_sub.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sub.offset_top = -30.0                  # just under the banner
	_sub.offset_bottom = -150.0
	_layout()
	get_viewport().size_changed.connect(_layout)
	_audio = AudioStreamPlayer.new()
	add_child(_audio)
	if score_label == null:
		score_label = _scene_root().find_child("ScoreLabel", true, false) as Label
	_hook_player.call_deferred()


## Sizes and places the counter and the STRIKE banner for the screen (phones too, see ui_fit.gd).
func _layout() -> void:
	var vp := get_viewport()
	_k = UIFit.hud_k(vp)
	var portrait := UIFit.is_portrait(vp)
	# the counter sits under the wave tab (which hangs lower when the phone is upright)
	var top := (UIFit.top_bar_bottom(vp) + 175.0 * _k) if portrait else 175.0 * _k
	_counter.offset_left = -300.0 * _k
	_counter.offset_right = 300.0 * _k
	_counter.offset_top = top
	_counter.offset_bottom = top + 60.0 * _k
	_set_font(_counter, 40)
	_banner.offset_bottom = -320.0 * _k
	_sub.offset_top = -30.0 * _k
	_sub.offset_bottom = -150.0 * _k
	_set_font(_sub, 30)
	_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if portrait else TextServer.AUTOWRAP_OFF


## Game over: clear the counter and banner off the screen (the game-over book takes over).
func hide_all() -> void:
	for t in [_counter_tween, _banner_tween]:
		if t:
			t.kill()
	for l in [_counter, _banner, _sub]:
		l.modulate.a = 0.0


func _set_font(l: Label, design: float) -> void:
	var fs := maxi(int(design * _k), 10)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_constant_override("outline_size", maxi(fs / 6, 4))


func _exit_tree() -> void:
	_reset_time_scale()


func _hook_player() -> void:
	_player = get_tree().get_first_node_in_group("player")
	if _player == null or not _player.has_signal("ant_bowled"):
		push_warning("Combo: no rolly polly with the combo signals found (needs the latest player.gd).")
		return
	_player.roll_started.connect(_on_roll_started)
	_player.ant_bowled.connect(_on_ant_bowled)
	_player.roll_ended.connect(_on_roll_ended)


func _on_roll_started() -> void:
	if _pending_end:
		_finish_roll()                             # the last roll's pins never settled: wrap it up now
	_roll_index += 1
	combo = 0
	roll_points = 0


## The rolly polly hit an ant directly.
func _on_ant_bowled(mob: Node) -> void:
	if not (mob is Node3D) or mob.get("knocked"):
		return
	mob.set("knock_roll", _roll_index)             # pins this ant knocks over count for this roll too
	_count_hit(mob, _roll_index)


## An ant was knocked over by another flying ant (called by mob.gd through the "combo" group).
func on_chain_knock(mob: Node) -> void:
	var roll = mob.get("knock_roll")
	if roll == null or roll < 0:
		return
	if roll == _roll_index:
		_count_hit(mob, roll)
		_settle_left = settle_time                 # still clattering: wait before the end-of-roll banner
	else:
		_check_row(mob, roll)                      # left over from an older roll: no combo, but finishes its row


func _count_hit(mob: Node, roll: int) -> void:
	combo += 1
	best_combo = maxi(best_combo, combo)
	var pts := combo if combo_points else 1
	roll_points += pts
	_add_score(pts - 1)                            # the ScoreLabel already gives 1 point per ant itself

	var hs := mob.get_node_or_null("HitSound")
	if hs and "pitch_scale" in hs:                 # each ant in the combo clacks a little higher
		hs.pitch_scale = minf(1.0 + hit_pitch_step * (combo - 1), max_hit_pitch) * randf_range(0.97, 1.03)

	var heat := clampf((combo - 1) / 5.0, 0.0, 1.0)    # white -> yellow -> orange -> red
	var col := Color.from_hsv(lerpf(0.15, 0.0, heat), lerpf(0.1, 0.9, heat), 1.0)
	_popup_3d(mob.global_position, "+%d" % pts, col, 1.0 + 0.12 * mini(combo - 1, 6))
	if combo >= 2:
		_show_counter("x%d" % combo, col)
	_check_row(mob, roll)


func _on_roll_ended() -> void:
	_pending_end = true                            # flying ants may still knock more over: wait for them
	_settle_left = settle_time


func _process(delta: float) -> void:
	if _pending_end:
		_settle_left -= delta / maxf(Engine.time_scale, 0.05)    # real seconds
		if _settle_left <= 0.0:
			_finish_roll()


func _finish_roll() -> void:
	_pending_end = false
	if Time.get_ticks_msec() - _row_banner_ms < 1300:
		if combo >= 2:                             # STRIKE / SPARE still showing: add the combo under it
			_sub.text += "     x%d combo  +%d" % [combo, roll_points]
	elif combo >= 2:
		var title := {2: "DOUBLE!", 3: "TRIPLE!"}.get(combo, "%d-ANT COMBO!" % combo) as String
		_show_banner(title, "+%d" % roll_points, Color.from_hsv(lerpf(0.15, 0.0, clampf((combo - 1) / 5.0, 0.0, 1.0)), 0.8, 1.0), 0.75)
		_play(combo_sound)
	_hide_counter()


## STRIKE: the whole group went down in one roll (pins knocking pins included).
## SPARE: cleared on exactly the second roll that hit it.
func _check_row(mob: Node, roll: int) -> void:
	var r = mob.get("row_id")
	var count = mob.get("row_count")
	if r == null or r < 0 or count == null or count < min_row_for_strike:
		return
	_row_down[r] = _row_down.get(r, 0) + 1
	if _row_last_roll.get(r, -1) != roll:          # first ant of this group in this roll = one more attempt at it
		_row_last_roll[r] = roll
		_row_rolls[r] = _row_rolls.get(r, 0) + 1
	if _row_down[r] < count:
		return
	var attempts: int = _row_rolls[r]
	_row_down.erase(r)
	_row_rolls.erase(r)
	_row_last_roll.erase(r)
	if attempts == 1:
		_strike(mob)
	elif attempts == 2:                            # like bowling: a spare only counts on the second ball
		spares += 1
		_add_score(spare_bonus)
		_row_banner_ms = Time.get_ticks_msec()
		_show_banner("SPARE!", "+%d" % spare_bonus, SPARE_COLOR, 0.8)
		_play(spare_sound)


func _strike(mob: Node) -> void:
	_row_banner_ms = Time.get_ticks_msec()
	strikes += 1
	strike_scored.emit(mob.global_position)
	_add_score(strike_bonus)
	_show_banner("STRIKE!", "+%d" % strike_bonus, STRIKE_COLOR, 1.0)
	_play(strike_sound)
	var rig = _player.get("camera_rig") if _player else null
	if rig and rig.has_method("add_shake"):
		rig.add_shake(strike_shake)
	_slow_mo()


func _slow_mo() -> void:
	if strike_slowmo >= 1.0:
		return
	await get_tree().create_timer(0.06, true, false, true).timeout   # let the hit-stop land first
	Engine.set_meta("base_time_scale", strike_slowmo)                # hit-stops during the slow-mo return to it
	Engine.time_scale = strike_slowmo
	await get_tree().create_timer(strike_slowmo_time, true, false, true).timeout
	_reset_time_scale()


func _reset_time_scale() -> void:
	Engine.set_meta("base_time_scale", 1.0)
	Engine.time_scale = 1.0


func _add_score(points: int) -> void:
	if points <= 0 or score_label == null or not ("score" in score_label):
		return
	score_label.score += points
	score_label.text = "Score: %s" % score_label.score


# ---------------------------------------------------------------- visuals

## A "+N" that floats up from the ant and fades. Drawn on top of everything so hills never hide it.
func _popup_3d(pos: Vector3, text: String, col: Color, size_mult := 1.0) -> void:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 10
	l.pixel_size = popup_size * size_mult
	l.font_size = 64
	l.outline_size = 18
	l.modulate = col
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_scene_root().add_child(l)
	l.global_position = pos + Vector3.UP * popup_height
	l.scale = Vector3.ONE * 1.6
	var t := l.create_tween().set_parallel(true).set_ignore_time_scale(true)
	t.tween_property(l, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "global_position:y", l.global_position.y + 1.6, 0.9).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(l, "modulate:a", 0.0, 0.35).set_delay(0.55)
	t.tween_property(l, "outline_modulate:a", 0.0, 0.35).set_delay(0.55)
	t.chain().tween_callback(l.queue_free)


func _show_counter(text: String, col: Color) -> void:
	if _counter_tween:
		_counter_tween.kill()
	_counter.text = text
	_counter.modulate = Color(col, 1.0)
	_counter.pivot_offset = _counter.size * 0.5
	_counter.scale = Vector2.ONE * 1.5
	_counter_tween = create_tween().set_ignore_time_scale(true)
	_counter_tween.tween_property(_counter, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _hide_counter() -> void:
	if _counter.modulate.a <= 0.0:
		return
	if _counter_tween:
		_counter_tween.kill()
	_counter_tween = create_tween().set_ignore_time_scale(true)
	_counter_tween.tween_property(_counter, "modulate:a", 0.0, 0.3).set_delay(0.3)


func _show_banner(title: String, sub: String, col: Color, size_mult: float) -> void:
	if _banner_tween:
		_banner_tween.kill()
	_banner.text = title
	_set_font(_banner, 84.0 * size_mult)
	_banner.modulate = col
	_sub.text = sub
	_sub.modulate = Color.WHITE
	_banner.pivot_offset = _banner.size * 0.5
	_banner.scale = Vector2.ONE * 2.2
	_banner.rotation = deg_to_rad(randf_range(-6.0, 6.0))
	_banner_tween = create_tween().set_ignore_time_scale(true)
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.parallel().tween_property(_banner, "rotation", 0.0, 0.25)
	_banner_tween.tween_interval(0.9)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.4)
	_banner_tween.parallel().tween_property(_sub, "modulate:a", 0.0, 0.4)


func _scene_root() -> Node:
	return get_tree().current_scene if get_tree().current_scene else get_parent()


func _make_label(font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE      # never blocks the click-and-drag
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", maxi(font_size / 6, 4))
	l.modulate = Color(col, 0.0)
	add_child(l)
	return l


func _play(stream: AudioStream) -> void:
	if stream:
		_audio.stream = stream
		_audio.play()
