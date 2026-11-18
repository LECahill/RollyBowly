extends Control
## Lobby (book ch.3 + ch.4 + ch.5): who's here, chat, and READY.
## The match starts when everyone is ready (2+ players). A dedicated server stays on this screen
## for the whole match and watches the scoreboard; it can also START NOW without waiting.

var board: Scoreboard
var chat: ChatBox
var _ready_btn: TextureButton
var _start_btn: TextureButton
var _countdown: Label
var _results: Label
var _info: Label
var _is_ready := false


func _ready() -> void:
	theme = NetUI.theme()
	NetUI.backdrop(self)
	_build()
	Net.roster_changed.connect(_refresh)
	Net.countdown_changed.connect(_on_countdown)
	Net.match_over.connect(_on_match_over)
	_refresh()
	if not Net.online:                                   # got here without a connection: back to the menu
		Net._go(Net.MENU_SCENE)


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)

	col.add_child(NetUI.title("BACKYARD LOBBY", 64))
	_info = NetUI.label("", 22, NetUI.CREAM, 6, NetUI.BROWN)
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_info)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 20)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(split)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 12)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)
	board = Scoreboard.new(false)
	left.add_child(board)
	var how := NetUI.panel()
	var how_text := NetUI.label(
		"HOW TO PLAY\n" +
		"Drag back and let go to launch your rolly polly. Bowl the ants over before they eat your mushroom house.\n" +
		"Send ants to someone else's backyard: STRIKE = soldiers, SPARE = fast sprinters, 4+ combo = an egg-laying queen.\n" +
		"Ants INCOMING? Earn any attack within 3 seconds to BLOCK them. STRIKE a group someone sent you to COUNTER-BOWL it back, doubled!\n" +
		"Tab or click a name: choose who gets them.  Enter: chat.\n" +
		"Last house standing wins!", 20)
	how_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how_text.custom_minimum_size.x = 380
	how.add_child(how_text)
	left.add_child(how)
	_results = NetUI.label("", 22, NetUI.CREAM, 6, NetUI.BROWN)
	_results.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_results)

	chat = ChatBox.new(false)
	chat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat.custom_minimum_size = Vector2(380, 300)
	split.add_child(chat)

	_countdown = NetUI.label("", 40, Color(1, 0.86, 0.3), 10, NetUI.BROWN)
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_countdown)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	col.add_child(row)
	row.add_child(NetUI.button("LEAVE", "button_red", Color(0.55, 0.1, 0.12), 200, _on_leave))
	if Net.dedicated:
		_start_btn = NetUI.button("START NOW", "button_green", Color(0.1, 0.45, 0.1), 250, func(): Net.force_start())
		row.add_child(_start_btn)
	else:
		_ready_btn = NetUI.button("READY", "button_green", Color(0.1, 0.45, 0.1), 250, _on_ready)
		row.add_child(_ready_btn)


func _refresh() -> void:
	var where := ""
	if Net.is_server():
		var addrs: PackedStringArray = Net.local_addresses()
		where = "Hosting on port %d  -  join at %s" % [Net.last_port, ", ".join(addrs) if addrs.size() > 0 else "127.0.0.1"]
	else:
		where = "Connected to %s:%d" % [Net.last_ip, Net.last_port]
	var need: int = Net._min_players()
	var n: int = Net.players.size()
	if Net.in_match:
		_info.text = where + "   |   match in progress"
	elif n < need:
		_info.text = where + "   |   waiting for %d more player%s" % [need - n, "" if need - n == 1 else "s"]
	else:
		_info.text = where + "   |   everyone READY starts the match"
	if _ready_btn:
		_is_ready = bool(Net.me().get("ready", false))
		NetUI.set_button_text(_ready_btn, "NOT READY" if _is_ready else "READY")
		_ready_btn.texture_normal = NetUI.tex("button_blue" if _is_ready else "button_green")
	if _start_btn:
		NetUI.set_button_enabled(_start_btn, not Net.in_match and n >= need)
	if Net.last_results.size() > 0:
		var lines := PackedStringArray(["Last match:"])
		for r in Net.last_results:
			lines.append("%s  %s  (%d pts)" % [Net.ordinal(int(r[1])) if int(r[1]) > 0 else "-", r[0], int(r[2])])
		_results.text = "\n".join(lines)


func _on_match_over(_winner: int) -> void:
	_refresh()


func _on_ready() -> void:
	Net.set_ready(not _is_ready)


func _on_countdown(seconds_left: int) -> void:
	_countdown.text = "" if seconds_left < 0 else "Starting in %d..." % seconds_left


func _on_leave() -> void:
	Net.leave()
	Net._go(Net.MENU_SCENE)
