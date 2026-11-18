extends Control
## First screen: pick a name, a server address and a port, then HOST, JOIN, SERVER ONLY or PLAY SOLO.
## (Book ch.1's MainMenu with its Server / Client buttons, grown up.)
##
## Everything can also be set from the command line, after a "--":
##   RollyBowly.exe -- --server --port=7777              dedicated server (no window needed with --headless)
##   RollyBowly.exe -- --host --port=7777 --name=Liam    host and play
##   RollyBowly.exe -- --join=192.168.1.20 --port=7777 --name=Sam
##   add --allow-solo to let a match start with one player (testing)

static var _args_done := false

var _name_edit: LineEdit
var _ip_edit: LineEdit
var _port_edit: LineEdit
var _status: Label
var _buttons: Array[TextureButton] = []


func _ready() -> void:
	theme = NetUI.theme()
	NetUI.backdrop(self)
	_build()
	if Net.has_meta("menu_message"):
		_say(str(Net.get_meta("menu_message")), true)
		Net.remove_meta("menu_message")
	if not _args_done:
		_args_done = true
		_apply_command_line.call_deferred()


func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	col.add_child(NetUI.title("ROLLY BOWLY"))
	var sub := NetUI.label("BACKYARD BRAWL  -  online, 2 to %d players" % Net.MAX_PLAYERS, 30, NetUI.CREAM, 8, NetUI.BROWN)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)

	var card := NetUI.panel()
	col.add_child(card)
	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 12)
	card.add_child(form)
	_name_edit = NetUI.line_edit("your name", Net.my_name)
	_name_edit.max_length = 14
	_ip_edit = NetUI.line_edit("server IP, e.g. 192.168.1.20", Net.last_ip)
	_port_edit = NetUI.line_edit("port", str(Net.last_port))
	_port_edit.max_length = 5
	form.add_child(NetUI.field_row("Name", _name_edit))
	form.add_child(NetUI.field_row("Server IP", _ip_edit))
	form.add_child(NetUI.field_row("Port", _port_edit))
	_ip_edit.text_submitted.connect(func(_t): _on_join())

	var addrs: PackedStringArray = Net.local_addresses()
	var hint := NetUI.label("Hosting? Friends join you at:  %s" % (", ".join(addrs) if addrs.size() > 0 else "127.0.0.1 (no network found)"), 20, Color(0.45, 0.3, 0.25))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 520
	form.add_child(hint)

	var row1 := HBoxContainer.new()
	row1.alignment = BoxContainer.ALIGNMENT_CENTER
	row1.add_theme_constant_override("separation", 16)
	col.add_child(row1)
	_buttons.append(NetUI.button("HOST & PLAY", "button_green", Color(0.1, 0.45, 0.1), 250, _on_host))
	_buttons.append(NetUI.button("JOIN", "button_blue", Color(0.1, 0.25, 0.55), 250, _on_join))
	for b in _buttons:
		row1.add_child(b)

	var row2 := HBoxContainer.new()
	row2.alignment = BoxContainer.ALIGNMENT_CENTER
	row2.add_theme_constant_override("separation", 16)
	col.add_child(row2)
	var server_only := NetUI.button("SERVER ONLY", "button_teal", Color(0.05, 0.35, 0.35), 200, _on_server_only, 22)
	var solo := NetUI.button("PLAY SOLO", "button_blue", Color(0.1, 0.25, 0.55), 200, _on_solo, 22)
	var quit := NetUI.button("QUIT", "button_red", Color(0.55, 0.1, 0.12), 200, func(): get_tree().quit(), 22)
	for b in [server_only, solo, quit]:
		row2.add_child(b)
		_buttons.append(b)

	_status = NetUI.label("", 24, NetUI.CREAM, 6, NetUI.BROWN)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 600
	col.add_child(_status)
	_buttons[0].grab_focus.call_deferred()


func _port() -> int:
	var p := _port_edit.text.strip_edges()
	if not p.is_valid_int() or int(p) < 1024 or int(p) > 65535:
		_say("Port must be a number from 1024 to 65535.", true)
		return -1
	return int(p)


func _on_host() -> void:
	var port := _port()
	if port < 0:
		return
	var err: Error = Net.host(port, _name_edit.text, true)
	if err != OK:
		_say("Couldn't open port %d (is another server already using it?)" % port, true)
		return
	Net._go(Net.LOBBY_SCENE)


func _on_server_only() -> void:
	var port := _port()
	if port < 0:
		return
	var err: Error = Net.host(port, "Server", false)
	if err != OK:
		_say("Couldn't open port %d (is another server already using it?)" % port, true)
		return
	Net._go(Net.LOBBY_SCENE)


func _on_join() -> void:
	var port := _port()
	if port < 0:
		return
	var ip := _ip_edit.text.strip_edges()
	if ip.is_empty():
		_say("Type the host's IP address.", true)
		return
	var err: Error = Net.join(ip, port, _name_edit.text)
	if err != OK:
		_say("Couldn't start a connection to %s:%d." % [ip, port], true)
		return
	_say("Connecting to %s:%d ..." % [ip, port])
	for b in _buttons:
		NetUI.set_button_enabled(b, false)
	# the lobby takes over once we're in; if it fails, Net brings us back here with a message
	await multiplayer.connected_to_server
	Net._go(Net.LOBBY_SCENE)


## The original single-player game, untouched.
func _on_solo() -> void:
	Net.leave()
	TitleScreen.shown_once = false
	Net._go(Net.GAME_SCENE)


func _say(text: String, bad := false) -> void:
	_status.text = text
	_status.label_settings.font_color = Color(1.0, 0.75, 0.7) if bad else NetUI.CREAM


func _apply_command_line() -> void:
	var args := {}
	for a in Array(OS.get_cmdline_args()) + Array(OS.get_cmdline_user_args()):
		var s := str(a)
		if not s.begins_with("--"):
			continue
		var kv := s.substr(2).split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.has("allow-solo"):
		Net.allow_solo = true
	if args.has("name"):
		_name_edit.text = args["name"]
	if args.has("port"):
		_port_edit.text = args["port"]
	if args.has("ip"):
		_ip_edit.text = args["ip"]
	if args.has("join") and args["join"] != "":
		_ip_edit.text = args["join"]
	if args.has("server") or (DisplayServer.get_name() == "headless" and not args.has("join") and not args.has("host")):
		_on_server_only()
	elif args.has("host"):
		_on_host()
	elif args.has("join"):
		_on_join()
