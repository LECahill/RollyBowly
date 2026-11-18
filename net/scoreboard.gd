class_name Scoreboard
extends PanelContainer
## Everyone's progress at a glance (assignment: "status / progress of other players").
##   Lobby:    name + READY / not ready.
##   In match: score, wave, a house health bar and the bug's hearts. Knocked-out players show
##             their place. The row you're sending attacks to has a red arrow.
## Click a row (or press Tab in game) to pick who your STRIKEs go to.

signal row_clicked(id: int)

@export var compact := false          ## in-game version: smaller, see-through

var target_id := 0                    # 0 = random (shown on the header)
var target_mode := "Random"
var _list: VBoxContainer
var _header: Label
var _dirty := true


func _init(is_compact := false) -> void:
	compact = is_compact


func _ready() -> void:
	theme = NetUI.theme(18 if compact else 24)
	add_theme_stylebox_override("panel", NetUI.paper(NetUI.PAPER, 0.85 if compact else 1.0))
	add_to_group("blocks_bowling")
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4 if compact else 8)
	add_child(box)
	_header = NetUI.label("", 20 if compact else 30, NetUI.BROWN)
	box.add_child(_header)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 3 if compact else 6)
	box.add_child(_list)
	Net.roster_changed.connect(refresh)
	Net.stats_changed.connect(_on_stats_changed)
	refresh()


func _on_stats_changed(_id: int) -> void:
	_dirty = true


func _process(_delta: float) -> void:
	if _dirty:                                          # stats arrive ~4x a second per player: redraw at most once a frame
		refresh()


func set_target(id: int, mode: String) -> void:
	target_id = id
	target_mode = mode
	refresh()


func refresh() -> void:
	_dirty = false
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	if Net.in_match:
		_header.text = ("Target: %s  (Tab)" % target_mode) if compact else "Backyards"
	else:
		_header.text = "Players  %d / %d" % [Net.players.size(), Net.MAX_PLAYERS]
	for id in _sorted_ids():
		_list.add_child(_row(id))


## Still playing first (best score on top), then the knocked-out ones by place.
func _sorted_ids() -> Array:
	var ids: Array = Net.players.keys()
	ids.sort_custom(func(a, b):
		var pa: Dictionary = Net.players[a]
		var pb: Dictionary = Net.players[b]
		if not Net.in_match and pa.get("place", 0) == 0 and pb.get("place", 0) == 0:
			return int(a) < int(b)
		if pa.get("alive", false) != pb.get("alive", false):
			return pa.get("alive", false)
		if pa.get("alive", false):
			return int(pa.get("score", 0)) > int(pb.get("score", 0))
		return int(pa.get("place", 99)) < int(pb.get("place", 99)))
	return ids


func _row(id: int) -> Control:
	var p: Dictionary = Net.players[id]
	var me := id == Net.my_id()
	var fs := 18.0 if compact else 26.0
	var row := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1, 1, 1, 0.55) if me else Color(1, 1, 1, 0.0)
	st.set_corner_radius_all(8)
	st.content_margin_left = 6
	st.content_margin_right = 6
	row.add_theme_stylebox_override("panel", st)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			row_clicked.emit(id))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	row.add_child(h)

	var arrow := NetUI.label(">" if Net.in_match and id == target_id and not me else " ", fs, Color(0.85, 0.15, 0.1), 3, NetUI.CREAM)
	arrow.custom_minimum_size.x = fs * 0.6
	h.add_child(arrow)
	var chip := ColorRect.new()
	chip.color = Net.color_of(id)
	chip.custom_minimum_size = Vector2(fs * 0.7, fs * 0.7)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(chip)
	var who := NetUI.label(str(p.get("name", "?")) + (" (you)" if me else ""), fs)
	who.custom_minimum_size.x = fs * (7.5 if compact else 9.0)
	who.clip_text = true
	h.add_child(who)

	if not Net.in_match and p.get("place", 0) == 0:
		var r := NetUI.label("READY" if p.get("ready", false) else "not ready", fs, Color(0.2, 0.55, 0.15) if p.get("ready", false) else Color(0.55, 0.45, 0.4))
		h.add_child(r)
		return row

	if not p.get("alive", false) and int(p.get("place", 0)) > 0:
		var place := int(p.place)
		var txt := "WINNER!" if place == 1 else "OUT - %s" % Net.ordinal(place)
		h.add_child(NetUI.label(txt, fs, Color(0.75, 0.5, 0.0) if place == 1 else Color(0.6, 0.2, 0.15)))
		h.add_child(_icon("icon_star", fs))
		h.add_child(NetUI.label(str(p.get("score", 0)), fs))
		return row

	h.add_child(_icon("icon_star", fs))
	var sc := NetUI.label(str(p.get("score", 0)), fs)
	sc.custom_minimum_size.x = fs * 2.4
	h.add_child(sc)
	var wv := NetUI.label("W%d" % int(p.get("wave", 0)), fs, Color(0.3, 0.35, 0.6))
	wv.custom_minimum_size.x = fs * 1.8
	h.add_child(wv)
	h.add_child(_icon("icon_house", fs))
	h.add_child(_bar(int(p.get("house_hp", 0)), maxi(int(p.get("house_max", 1)), 1), fs))
	var hearts := HBoxContainer.new()
	hearts.add_theme_constant_override("separation", 1)
	for i in maxi(int(p.get("bug_max", 0)), 0):
		hearts.add_child(_icon("heart_full" if i < int(p.get("bug_hp", 0)) else "heart_empty", fs * 0.85))
	h.add_child(hearts)
	return row


func _icon(name: String, fs: float) -> TextureRect:
	var t := TextureRect.new()
	t.texture = NetUI.tex(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(fs, fs)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


func _bar(value: int, max_value: int, fs: float) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0
	b.max_value = max_value
	b.value = value
	b.show_percentage = false
	b.custom_minimum_size = Vector2(fs * (3.5 if compact else 4.5), fs * 0.55)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.3, 0.18, 0.12, 0.5)
	bg.set_corner_radius_all(6)
	var fill := StyleBoxFlat.new()
	var f := float(value) / max_value
	fill.bg_color = Color(0.85, 0.2, 0.15).lerp(Color(0.35, 0.75, 0.25), f)
	fill.set_corner_radius_all(6)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fill)
	return b
