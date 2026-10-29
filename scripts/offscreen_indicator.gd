extends CanvasLayer
## Arrows at the edge of the screen pointing at groups of ants that are off screen,
## so you can line up your shot before they arrive.
##
## Setup: right-click Main > Add Child Node > CanvasLayer, name it "OffscreenIndicator", attach this script.
## Uses res://ui/ (arrow_yellow.png, arrow_red.png, icon_worker.png, icon_soldier.png, the Fredoka font).
##
## Each group of ants gets one arrow from the UI pack, with a little tag showing what's coming
## (worker ants, and soldier ants escorting them). New arrows pop in and nudge toward the group,
## the arrow warms from yellow to red as the group nears the house, and shakes when it's close.
## Power-up drops that are off screen get a round badge in their own colour, pointing the way,
## which blinks when the drop is about to disappear.

@export var ui_folder := "res://ui/"
@export var ui_scale := 1.0                  ## size of the arrows and tags (1 = designed for 1080p)
@export var edge_margin := 72.0              ## how far in from the screen edge the arrows sit (pixels at 1080p)
@export var top_margin := 150.0              ## keeps arrows at the top edge below the wave tab / score / hearts
@export var arrow_size := 96.0               ## arrow width when the group is far away (pixels at 1080p)
@export var near_size := 124.0               ## arrow width when the group is close to the house
@export var far_distance := 60.0             ## at this distance from the house the arrow is smallest and yellow
@export var near_distance := 15.0            ## at this distance from the house it's biggest, red, and shaking
@export var new_group_flash_time := 2.0      ## a new group's arrow keeps nudging toward it for this long
@export var show_count := true               ## tag with how many ants are in the group
@export var soldier_join_distance := 9.0     ## soldiers this close to a group share its arrow (they escort it)
@export var on_screen_padding := 30.0        ## a group counts as on screen once it's this far inside the edge
@export var show_powerups := true            ## badges for power-up drops that are off screen
@export var powerup_badge_size := 24.0

const BROWN := Color(0.43, 0.19, 0.16)
const CREAM := Color(1.0, 0.98, 0.9)

var _canvas: Control                         # power-up badges are drawn here
var _layer: Control                          # the group arrows live here
var _markers := {}                           # group key -> marker Dictionary
var _badges: Array = []                      # [{pos, dir, color, kind, blink}]
var _house: Node3D
var _time := 0.0
var _k := 1.0
var _font: Font
var _tex := {}


func _ready() -> void:
	layer = 40
	_font = load(ui_folder + "Fredoka-SemiBold.ttf") if ResourceLoader.exists(ui_folder + "Fredoka-SemiBold.ttf") else ThemeDB.fallback_font
	for n in ["arrow_yellow", "arrow_red", "icon_worker", "icon_soldier"]:
		_tex[n] = load(ui_folder + n + ".png") if ResourceLoader.exists(ui_folder + n + ".png") else null
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never blocks the click-and-drag
	_canvas.draw.connect(_draw_badges)
	add_child(_canvas)
	_layer = Control.new()
	_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_layer)


func _process(delta: float) -> void:
	_time += delta
	_badges.clear()
	var rect := _canvas.get_rect()
	_k = UIFit.hud_k(get_viewport()) * ui_scale
	var cam := get_viewport().get_camera_3d()
	if get_parent().get("game_over") == true or cam == null:   # the game-over book is up: no arrows over it
		for key in _markers.keys():
			_remove_marker(key)
		_canvas.queue_redraw()
		return
	if _house == null or not is_instance_valid(_house):
		_house = get_tree().get_first_node_in_group("house")

	var groups := _gather_groups()
	var centre := rect.size * 0.5
	var seen := {}
	for key in groups:
		var g: Dictionary = groups[key]
		var pos: Vector3 = g.sum / float(g.workers + g.soldiers) + Vector3.UP * 0.5
		var edge = _edge_point(cam, pos, rect, centre)
		if edge == null:
			continue                                          # on screen: no arrow needed
		seen[key] = true
		var closeness := 0.0
		if _house:
			var d := Vector2(pos.x - _house.global_position.x, pos.z - _house.global_position.z).length()
			closeness = clampf(inverse_lerp(far_distance, near_distance, d), 0.0, 1.0)
		var m: Dictionary = _markers[key] if _markers.has(key) else _add_marker(key)
		_update_marker(m, edge[0], edge[1], closeness, g)

	for key in _markers.keys():                             # gone, or back on screen: pop out
		if not seen.has(key):
			_remove_marker(key)

	if show_powerups:
		for pu in get_tree().get_nodes_in_group("powerup"):
			var pos: Vector3 = pu.global_position + Vector3.UP * 1.0
			var edge = _edge_point(cam, pos, rect, centre)
			if edge == null:
				continue
			var left = pu.get("time_left")
			var blink_at = pu.get("blink_time")
			_badges.append({"pos": edge[0], "dir": edge[1], "color": pu.get("icon_color") if pu.get("icon_color") != null else Color.WHITE,
					"kind": str(pu.get("kind")), "blink": left != null and blink_at != null and left < blink_at})
	_canvas.queue_redraw()


## Standing ants grouped by the triangle they spawned in. Soldiers escorting a group join its arrow.
func _gather_groups() -> Dictionary:
	var groups := {}
	var loners: Array = []
	for a in get_tree().get_nodes_in_group("mob"):
		if a.get("knocked"):
			continue
		var hits = a.get("hits_to_knock")
		var soldier: bool = hits != null and hits > 1
		var r = a.get("row_id")
		if soldier or r == null or r < 0:
			loners.append([a, soldier])
			continue
		if not groups.has(r):
			groups[r] = {"sum": Vector3.ZERO, "workers": 0, "soldiers": 0}
		groups[r].sum += a.global_position
		groups[r].workers += 1
	for l in loners:
		var a: Node3D = l[0]
		var best = null
		var best_d := soldier_join_distance
		for key in groups:
			var g: Dictionary = groups[key]
			var c: Vector3 = g.sum / float(g.workers + g.soldiers)
			var d := Vector2(c.x - a.global_position.x, c.z - a.global_position.z).length()
			if d < best_d:
				best_d = d
				best = key
		if best == null:
			best = "a%d" % a.get_instance_id()
			groups[best] = {"sum": Vector3.ZERO, "workers": 0, "soldiers": 0}
		groups[best].sum += a.global_position
		if l[1]:
			groups[best].soldiers += 1
		else:
			groups[best].workers += 1
	return groups


## Where on the screen edge to show something that's off screen: [position, direction], or null if it's on screen.
func _edge_point(cam: Camera3D, pos: Vector3, rect: Rect2, centre: Vector2):
	var behind := cam.is_position_behind(pos)
	var sp := cam.unproject_position(pos)
	var inside := Rect2(Vector2.ONE * on_screen_padding, rect.size - Vector2.ONE * on_screen_padding * 2.0)
	if not behind and inside.has_point(sp):
		return null
	var dir := sp - centre
	if behind:
		dir = -dir                                            # behind the camera, the projection comes out mirrored
	if dir.length() < 0.01:
		dir = Vector2.DOWN
	dir = dir.normalized()
	# slide out from the centre until we hit the margin (a bigger one at the top, under the HUD)
	var m := edge_margin * _k
	var lim_x := centre.x - m
	var lim_y := centre.y - (top_margin * _k if dir.y < 0.0 else m)
	var t := minf(lim_x / maxf(absf(dir.x), 0.0001), lim_y / maxf(absf(dir.y), 0.0001))
	return [centre + dir * t, dir]


# ---------------------------------------------------------------- group arrows

func _add_marker(key) -> Dictionary:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(root)
	# the arrow: a pivot turned to face the group, with the yellow and red arrows stacked on it
	var pivot := Control.new()
	pivot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pivot)
	var nudge := Control.new()                               # slides back and forth toward the group
	nudge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pivot.add_child(nudge)
	var shadow := _arrow_rect("arrow_yellow", nudge)         # soft drop shadow so it reads on the grass
	shadow.modulate = Color(0, 0, 0, 0.28)
	var yellow := _arrow_rect("arrow_yellow", nudge)
	var red := _arrow_rect("arrow_red", nudge)
	red.modulate.a = 0.0
	# the tag: what's coming, on a little cream plate
	var tag := PanelContainer.new()
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = CREAM
	sb.border_color = BROWN
	sb.set_border_width_all(maxi(int(3 * _k), 2))
	sb.set_corner_radius_all(int(18 * _k))
	sb.content_margin_left = 8 * _k
	sb.content_margin_right = 10 * _k
	sb.content_margin_top = 2 * _k
	sb.content_margin_bottom = 2 * _k
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = int(4 * _k)
	sb.shadow_offset = Vector2(0, 3 * _k)
	tag.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(4 * _k))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_child(row)
	var w_icon := _icon("icon_worker", row)
	var w_lbl := _count_label(row)
	var s_icon := _icon("icon_soldier", row)
	var s_lbl := _count_label(row)
	tag.visible = show_count
	root.add_child(tag)

	var m := {"root": root, "pivot": pivot, "nudge": nudge, "yellow": yellow, "red": red, "shadow": shadow, "tag": tag,
			"w_icon": w_icon, "w_lbl": w_lbl, "s_icon": s_icon, "s_lbl": s_lbl,
			"born": _time, "workers": -1, "soldiers": -1, "urgent": false, "closeness": 0.0}
	_markers[key] = m
	# pop in, overshooting a little
	root.scale = Vector2.ZERO
	var t := create_tween()
	t.tween_property(root, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return m


func _arrow_rect(tex_name: String, parent: Control) -> TextureRect:
	var r := TextureRect.new()
	r.texture = _tex[tex_name]
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r


func _icon(tex_name: String, parent: Control) -> TextureRect:
	var r := TextureRect.new()
	r.texture = _tex[tex_name]
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(44, 44) * _k
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r


func _count_label(parent: Control) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font = _font
	ls.font_size = maxi(int(33 * _k), 10)
	ls.font_color = BROWN
	l.label_settings = ls
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _update_marker(m: Dictionary, pos: Vector2, dir: Vector2, closeness: float, g: Dictionary) -> void:
	var root: Control = m.root
	var pivot: Control = m.pivot
	var nudge: Control = m.nudge
	root.position = pos
	m.closeness = lerpf(m.closeness, closeness, 0.1)         # smooth, so the colour doesn't flicker
	var c: float = m.closeness
	var urgent := closeness >= 1.0

	# arrow: turned to the group, tip on the edge point, bigger and redder as it closes in
	var w := lerpf(arrow_size, near_size, c) * _k
	var tex: Texture2D = _tex["arrow_yellow"]
	var h := w * (float(tex.get_height()) / tex.get_width()) if tex else w * 0.6
	pivot.rotation = dir.angle() + PI * 0.5                   # the sprite points up; up becomes "toward the group"
	for r in [m.yellow, m.red, m.shadow]:
		r.size = Vector2(w, h)
		r.position = Vector2(-w * 0.5, -h * 0.5)
	m.shadow.position += Vector2(0, 5 * _k).rotated(-pivot.rotation)   # shadow always falls downward on screen
	m.red.modulate.a = c
	# nudge toward the group: a quick eager bob for new groups, a slow one otherwise
	var age: float = _time - m.born
	var eager := age < new_group_flash_time
	var amp := (12.0 if eager else 6.0) * _k
	var speed := 9.0 if eager else 4.0
	nudge.position = Vector2(0, -absf(sin(_time * speed)) * amp)
	# close to the house: throb and shake
	var s := 1.0
	if urgent:
		s = 1.0 + 0.12 * absf(sin(_time * 8.0))
		nudge.position += Vector2(sin(_time * 47.0), 0) * 3.0 * _k
	pivot.scale = Vector2.ONE * s
	if urgent and not m.urgent:                              # just became urgent: one big pop
		_pop(pivot, 1.35)
	m.urgent = urgent

	# tag: sits just inside the arrow, toward the middle of the screen
	var tag: PanelContainer = m.tag
	if g.workers != m.workers or g.soldiers != m.soldiers:
		if m.workers >= 0:
			_pop(tag, 1.25)                                    # the count changed (one got bowled): bounce
		m.workers = g.workers
		m.soldiers = g.soldiers
		m.w_icon.visible = g.workers > 0
		m.w_lbl.visible = g.workers > 0
		m.w_lbl.text = "×%d" % g.workers
		m.s_icon.visible = g.soldiers > 0
		m.s_lbl.visible = g.soldiers > 0
		m.s_lbl.text = "×%d" % g.soldiers
		tag.reset_size()
	var ts := tag.get_combined_minimum_size()
	tag.size = ts
	tag.pivot_offset = ts * 0.5
	if dir.y < 0.0 and absf(dir.y) > absf(dir.x) * 0.6:
		# top edge: the house's health bar is just below, so the tag goes beside the arrow instead
		var side := 1.0 if dir.x <= 0.0 else -1.0
		tag.position = Vector2(side * (w * 0.5 + 12.0 * _k) - (ts.x if side < 0.0 else 0.0), -ts.y * 0.5)
	else:
		var back := (h * 0.5 + 14.0 * _k) + absf(dir.x) * ts.x * 0.5 + absf(dir.y) * ts.y * 0.5
		tag.position = -dir * back - ts * 0.5
	tag.self_modulate = Color.WHITE.lerp(Color(1.0, 0.85, 0.82), c)


func _pop(c: Control, amount: float) -> void:
	var t := create_tween()
	t.tween_property(c, "scale", Vector2.ONE * amount, 0.08)
	t.tween_property(c, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _remove_marker(key) -> void:
	var m: Dictionary = _markers[key]
	_markers.erase(key)
	var root: Control = m.root
	var t := create_tween()
	t.tween_property(root, "scale", Vector2.ZERO, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.tween_callback(root.queue_free)


# ---------------------------------------------------------------- power-up badges

## A round badge in the power-up's colour with a little picture of what's inside, and a pointer toward it.
func _draw_badges() -> void:
	for b in _badges:
		_draw_badge(b)


func _draw_badge(b: Dictionary) -> void:
	if b.blink and fmod(_time * 6.0, 1.0) < 0.35:
		return                                                  # about to disappear: blink
	var pos: Vector2 = b.pos
	var dir: Vector2 = b.dir
	var r := powerup_badge_size * (1.0 + 0.08 * sin(_time * 5.0))
	var col: Color = b.color
	var side := dir.orthogonal()
	# pointer
	var tip := pos + dir * (r + 12.0)
	_canvas.draw_colored_polygon(PackedVector2Array([tip, pos + dir * r * 0.7 + side * r * 0.5, pos + dir * r * 0.7 - side * r * 0.5]), Color.WHITE)
	# bubble badge
	_canvas.draw_circle(pos, r + 3.0, Color(0, 0, 0, 0.55))
	_canvas.draw_circle(pos, r, col.lerp(Color.WHITE, 0.55))
	_canvas.draw_circle(pos + Vector2(-r * 0.4, -r * 0.4), r * 0.16, Color(1, 1, 1, 0.9))   # bubble glint
	match b.kind:
		"size_up":                                          # a little blueberry with its leaf
			_canvas.draw_circle(pos + Vector2(0, r * 0.1), r * 0.55, col.darkened(0.25))
			_canvas.draw_circle(pos + Vector2(0, -r * 0.3), r * 0.14, col.darkened(0.7))
			_canvas.draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -r * 0.35), pos + Vector2(r * 0.35, -r * 0.7),
					pos + Vector2(r * 0.6, -r * 0.5), pos + Vector2(r * 0.25, -r * 0.3)]), Color(0.4, 0.75, 0.25))
		_:
			_canvas.draw_circle(pos, r * 0.5, col.darkened(0.2))
