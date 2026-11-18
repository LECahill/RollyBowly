extends Node
## Net (autoload): everything that goes over the network lives here.
##
## Built from the book's patterns (The Essential Guide to Creating Multiplayer Games with Godot 4):
##   ch.1  ENetMultiplayerPeer create_server / create_client
##   ch.3  a lobby that gathers players (here: a roster dictionary the server broadcasts)
##   ch.4  chat over a reliable RPC
##   ch.5  the server starts the match and every client changes scene
##
## Because this is an autoload it sits at /root/Net on every machine, so RPCs always find the
## same node path no matter which scene each player is looking at.
##
## Network model: "own backyard, shared pressure".
##   Every player runs their OWN backyard simulation locally (ants, physics, the rolly polly).
##   Nothing 3D is synchronised. The server only relays small events:
##     - roster / ready state             (lobby)
##     - chat messages                    (lobby and in game)
##     - each player's stats, 4x a second (score, wave, house HP, bug HP) -> everyone's scoreboard
##     - attacks: a STRIKE / SPARE / big combo sends ants to someone else's backyard
##       (STRIKE -> soldiers, SPARE -> sprinters, 4+ combo -> a queen; see ATTACK_CAPS)
##     - blocks: an attack you earn while ants are on their way to you cancels them (just a feed message)
##     - eliminations and the winner
##   The server is authoritative for all of those: clients ask, the server decides and broadcasts.

signal roster_changed                                  # players / ready flags changed
signal chat_received(from_name: String, text: String, color: Color)
signal stats_changed(id: int)
signal attack_incoming(from_id: int, attack: Dictionary)   # {workers, soldiers, sprinters, queens}
signal player_eliminated(id: int, place: int)
signal match_over(winner_id: int)
signal connect_failed(reason: String)                  # client: couldn't reach the server / was turned away
signal countdown_changed(seconds_left: int)            # lobby: -1 = cancelled

const DEFAULT_PORT := 9999
const DEFAULT_IP := "127.0.0.1"
const MAX_PLAYERS := 8                                 # assignment: 2..n players, n >= 4
const MIN_PLAYERS := 2
const START_COUNTDOWN := 3                             # seconds between "everyone is ready" and the match
const BACK_TO_LOBBY_DELAY := 8.0                       # seconds the results stay up before everyone returns to the lobby
const STATS_INTERVAL := 0.25                           # how often a client sends its stats (only if they changed)

const MENU_SCENE := "res://net/connect_menu.tscn"
const LOBBY_SCENE := "res://net/lobby.tscn"
const GAME_SCENE := "res://scenes/main.tscn"
const CONFIG_FILE := "user://net.cfg"

## The biggest attack a client may send (a COUNTER-BOWL doubles an attack, so these are 2x a normal one).
const ATTACK_CAPS := {"workers": 10, "soldiers": 4, "sprinters": 8, "queens": 2}

const COLORS: Array[Color] = [
	Color(0.95, 0.35, 0.3),   # red
	Color(0.3, 0.6, 0.95),    # blue
	Color(0.98, 0.78, 0.2),   # yellow
	Color(0.45, 0.85, 0.4),   # green
	Color(0.75, 0.45, 0.95),  # purple
	Color(1.0, 0.55, 0.15),   # orange
	Color(0.35, 0.9, 0.85),   # teal
	Color(0.95, 0.5, 0.75),   # pink
]

var online := false              # true while connected (host, client or dedicated server)
var dedicated := false           # server only: hosts the match but doesn't play
var allow_solo := false          # let a match start with 1 player (testing). --allow-solo or running from the editor
var my_name := "Player"
var last_ip := DEFAULT_IP
var last_port := DEFAULT_PORT

## id -> {name, color, ready, alive, place, score, wave, house_hp, house_max, bug_hp, bug_max}
var players := {}
var in_match := false
var match_seed := 0
var match_size := 0              # how many started the current match
var last_attacker := 0           # who last sent ants to us (for the "Revenge" target)
var last_results: Array = []     # [[name, place, score], ...] of the last match, for the lobby

var _countdown := -1
var _countdown_timer: Timer


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_countdown_timer = Timer.new()
	_countdown_timer.wait_time = 1.0
	_countdown_timer.timeout.connect(_on_countdown_tick)
	add_child(_countdown_timer)
	allow_solo = OS.has_feature("editor")
	_load_config()


# ================================================================ starting / stopping

## Start a server. play = true: this machine also plays (it's player id 1).
func host(port: int, player_name: String, play := true) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	online = true
	dedicated = not play
	if play:
		my_name = _clean_name(player_name)
	last_port = port
	_save_config()
	players.clear()
	if play:
		_add_player(1, my_name)
	_log("Server listening on port %d (%s)" % [port, "host + player" if play else "dedicated"])
	roster_changed.emit()
	return OK


## Connect to a server. The result arrives later: connected_to_server -> we register,
## or connect_failed(reason).
func join(ip: String, port: int, player_name: String) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	online = true
	dedicated = false
	my_name = _clean_name(player_name)
	last_ip = ip
	last_port = port
	_save_config()
	return OK


## Close the connection (back to offline). Safe to call any time.
func leave() -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	online = false
	dedicated = false
	in_match = false
	players.clear()
	_cancel_countdown()


func is_server() -> bool:
	return online and multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id()


func me() -> Dictionary:
	return players.get(my_id(), {})


func color_of(id: int) -> Color:
	var p: Dictionary = players.get(id, {})
	return COLORS[int(p.get("color", 0)) % COLORS.size()] if not p.is_empty() else Color.WHITE


func name_of(id: int) -> String:
	var p: Dictionary = players.get(id, {})
	return str(p.get("name", "?"))


func alive_ids() -> Array:
	var out := []
	for id in players:
		if players[id].get("alive", false):
			out.append(id)
	return out


## The machine's LAN addresses, so the host can tell friends what to type.
func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


# ================================================================ things the game calls

func send_chat(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty() or not online:
		return
	_to_server("_srv_chat", [text.left(200)])


func set_ready(is_ready: bool) -> void:
	_to_server("_srv_ready", [is_ready])


## Called by the in-game HUD a few times a second (it only calls when something changed).
func report_stats(stats: Dictionary) -> void:
	if online and in_match:
		_to_server("_srv_stats", [stats])


## Called when this player earns an attack (STRIKE, SPARE, combo, COUNTER-BOWL).
## attack = {workers, soldiers, sprinters, queens}. target 0 = let the server pick.
func send_attack(attack: Dictionary, target: int, reason: String) -> void:
	if online and in_match:
		_to_server("_srv_attack", [attack, target, reason])


## We cancelled ants that were on their way to us (only for the chat feed: they never left our machine).
func report_block(from_id: int, attack: Dictionary) -> void:
	if online and in_match:
		_to_server("_srv_block", [from_id, attack])


## Only the ant types we know, each clamped to its cap: never trust the client with the size of an attack.
static func clean_attack(a: Dictionary) -> Dictionary:
	var out := {}
	for k in ATTACK_CAPS:
		out[k] = clampi(int(a.get(k, 0)), 0, ATTACK_CAPS[k])
	return out


static func attack_size(a: Dictionary) -> int:
	var n := 0
	for k in ATTACK_CAPS:
		n += int(a.get(k, 0))
	return n


## "3 sprinters + 1 queen" for the chat feed and banners.
static func describe_attack(a: Dictionary) -> String:
	var parts := PackedStringArray()
	var names := {"workers": ["ant", "ants"], "soldiers": ["soldier", "soldiers"],
		"sprinters": ["sprinter", "sprinters"], "queens": ["queen", "queens"]}
	for k in ["queens", "soldiers", "sprinters", "workers"]:
		var n := int(a.get(k, 0))
		if n > 0:
			parts.append("%d %s" % [n, names[k][0] if n == 1 else names[k][1]])
	return " + ".join(parts) if parts.size() > 0 else "nothing"


## Called when our house falls or our bug is beaten.
func report_eliminated(reason: String) -> void:
	if online and in_match:
		_to_server("_srv_eliminated", [reason])


## Dedicated server's "start now" button (skips the ready check, still needs MIN_PLAYERS).
func force_start() -> void:
	if is_server() and not in_match and players.size() >= _min_players():
		_start_countdown()


# ================================================================ multiplayer signals

func _on_peer_connected(id: int) -> void:
	if is_server():
		_log("peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	if not is_server() or not players.has(id):
		return
	var who := name_of(id)
	if in_match and players[id].get("alive", false):
		_eliminate(id, "left")                          # leaving mid-match counts as being knocked out
	players.erase(id)
	_broadcast_roster()
	_system("%s left." % who)
	_check_countdown()


func _on_connected_to_server() -> void:
	rpc_id(1, "_srv_register", my_name)


func _on_connection_failed() -> void:
	_fail("Couldn't reach the server at %s:%d." % [last_ip, last_port])


func _on_server_disconnected() -> void:
	_fail("The server closed the connection.")


func _fail(reason: String) -> void:
	leave()
	set_meta("menu_message", reason)                    # the menu shows this after it loads
	connect_failed.emit(reason)
	_go(MENU_SCENE)


# ================================================================ server side (any_peer -> server)
# Clients call these with rpc_id(1, ...). The host calls them directly (see _to_server).

@rpc("any_peer", "call_remote", "reliable")
func _srv_register(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := _sender()
	if in_match:
		_reject(id, "A match is already running. Try again when it ends.")
		return
	if players.size() >= MAX_PLAYERS:
		_reject(id, "The server is full (%d players)." % MAX_PLAYERS)
		return
	_add_player(id, _clean_name(player_name))
	_broadcast_roster()
	_system("%s joined." % name_of(id))
	_check_countdown()


@rpc("any_peer", "call_remote", "reliable")
func _srv_chat(text: String) -> void:
	if not multiplayer.is_server():
		return
	var id := _sender()
	if not players.has(id):
		return
	rpc("_chat", name_of(id), text.strip_edges().left(200), color_of(id))


@rpc("any_peer", "call_remote", "reliable")
func _srv_ready(is_ready: bool) -> void:
	var id := _sender()
	if not multiplayer.is_server() or in_match or not players.has(id):
		return
	players[id].ready = is_ready
	_broadcast_roster()
	_check_countdown()


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _srv_stats(stats: Dictionary) -> void:
	var id := _sender()
	if not multiplayer.is_server() or not in_match or not players.has(id):
		return
	var p: Dictionary = players[id]
	for k in ["score", "wave", "house_hp", "house_max", "bug_hp", "bug_max"]:
		if stats.has(k):
			p[k] = int(stats[k])
	rpc("_stats", id, _public_stats(p))


@rpc("any_peer", "call_remote", "reliable")
func _srv_attack(attack: Dictionary, target: int, reason: String) -> void:
	var id := _sender()
	if not multiplayer.is_server() or not in_match or not players.has(id) or not players[id].alive:
		return
	attack = clean_attack(attack)
	if attack_size(attack) == 0:
		return
	reason = reason.replace("[", "").replace("]", "").left(20)
	var options := alive_ids()
	options.erase(id)
	if options.is_empty():
		return
	if not target in options:
		target = options[randi() % options.size()]
	_send_to(target, "_incoming", [id, attack])
	_system("%s %s! %s -> %s" % [name_of(id), reason, describe_attack(attack), name_of(target)])


@rpc("any_peer", "call_remote", "reliable")
func _srv_block(from_id: int, attack: Dictionary) -> void:
	var id := _sender()
	if multiplayer.is_server() and in_match and players.has(id):
		_system("%s BLOCKED %s's %s!" % [name_of(id), name_of(from_id), describe_attack(clean_attack(attack))])


@rpc("any_peer", "call_remote", "reliable")
func _srv_eliminated(reason: String) -> void:
	var id := _sender()
	if multiplayer.is_server() and in_match and players.has(id) and players[id].alive:
		_eliminate(id, reason)


# ================================================================ server helpers

func _add_player(id: int, player_name: String) -> void:
	var taken := []
	var names := []
	for p in players.values():
		taken.append(p.color)
		names.append(p.name)
	var unique := player_name
	var n := 2
	while unique in names:                               # two "Liam"s become "Liam" and "Liam2"
		unique = "%s%d" % [player_name, n]
		n += 1
	var color := 0
	while color in taken and color < COLORS.size() - 1:
		color += 1
	players[id] = {
		"name": unique, "color": color, "ready": false, "alive": false, "place": 0,
		"score": 0, "wave": 0, "house_hp": 0, "house_max": 0, "bug_hp": 0, "bug_max": 0,
	}


func _reject(id: int, reason: String) -> void:
	rpc_id(id, "_rejected", reason)
	await get_tree().create_timer(0.5).timeout          # let the message get there first
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer:
		peer.disconnect_peer(id)


func _min_players() -> int:
	return 1 if allow_solo else MIN_PLAYERS


## Everyone ready and enough players -> count down. Anything changes -> cancel.
func _check_countdown() -> void:
	if not is_server() or in_match:
		return
	var all_ready := players.size() >= _min_players()
	for p in players.values():
		if not p.ready:
			all_ready = false
	if all_ready and _countdown < 0:
		_start_countdown()
	elif not all_ready and _countdown >= 0 and not get_meta("forced", false):
		_cancel_countdown()
		_system("Start cancelled.")


func _start_countdown() -> void:
	set_meta("forced", players.values().any(func(p): return not p.ready))
	_countdown = START_COUNTDOWN
	rpc("_countdown_update", _countdown)
	_countdown_timer.start()


func _cancel_countdown() -> void:
	if _countdown_timer:
		_countdown_timer.stop()
	if _countdown >= 0 and is_server():
		rpc("_countdown_update", -1)
	_countdown = -1
	set_meta("forced", false)


func _on_countdown_tick() -> void:
	_countdown -= 1
	if _countdown > 0:
		rpc("_countdown_update", _countdown)
		return
	_countdown_timer.stop()
	_countdown = -1
	set_meta("forced", false)
	_begin_match()


func _begin_match() -> void:
	if players.size() < _min_players():
		return
	in_match = true
	match_size = players.size()
	var seed_value := randi()
	for p in players.values():
		p.alive = true
		p.ready = false
		p.place = 0
		p.score = 0
		p.wave = 0
	_log("Match starting with %d players" % match_size)
	rpc("_start_match", seed_value, players)             # rpc before any scene change (see book errata, ch.5)


func _eliminate(id: int, reason: String) -> void:
	var place := alive_ids().size()                      # 4 alive and you fall -> 4th place
	players[id].alive = false
	players[id].place = place
	rpc("_eliminated", id, place, reason)
	var left := alive_ids()
	if left.size() <= 1 and (match_size > 1 or left.is_empty()):
		var winner: int = left[0] if left.size() == 1 else 0
		if winner != 0:
			players[winner].alive = false
			players[winner].place = 1
		rpc("_match_over", winner, players)
		await get_tree().create_timer(BACK_TO_LOBBY_DELAY).timeout
		if online and in_match:
			in_match = false
			for p in players.values():
				p.alive = false
				p.place = 0
			rpc("_back_to_lobby", players)


func _broadcast_roster() -> void:
	if is_server():
		rpc("_set_roster", players, in_match)


## Server -> everyone: a line in the chat from nobody in particular.
func _system(text: String) -> void:
	if is_server():
		rpc("_chat", "", text, Color(1.0, 0.85, 0.5))


## Call a server function: over the network from a client, directly on the host.
func _to_server(method: String, args: Array) -> void:
	if not online:
		return
	if multiplayer.is_server():
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)


## Server -> one player (works when that player is the host itself, id 1).
func _send_to(id: int, method: String, args: Array) -> void:
	if id == multiplayer.get_unique_id():
		callv(method, args)
	else:
		callv("rpc_id", [id, method] + args)


## Who called this RPC. 0 means "called directly on this machine", which is the host (id 1).
func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return multiplayer.get_unique_id() if id == 0 else id


func _public_stats(p: Dictionary) -> Dictionary:
	return {
		"score": p.score, "wave": p.wave, "house_hp": p.house_hp, "house_max": p.house_max,
		"bug_hp": p.bug_hp, "bug_max": p.bug_max,
	}


# ================================================================ client side (server -> everyone)
# "call_local" so the host / dedicated server runs them too.

@rpc("authority", "call_local", "reliable")
func _set_roster(roster: Dictionary, running: bool) -> void:
	players = roster
	in_match = running
	roster_changed.emit()


@rpc("authority", "call_local", "reliable")
func _chat(from_name: String, text: String, color: Color) -> void:
	if dedicated or DisplayServer.get_name() == "headless":
		_log(("[%s] %s" % [from_name, text]) if from_name != "" else text)
	chat_received.emit(from_name, text, color)


@rpc("authority", "call_local", "reliable")
func _countdown_update(seconds_left: int) -> void:
	countdown_changed.emit(seconds_left)


@rpc("authority", "call_local", "reliable")
func _start_match(seed_value: int, roster: Dictionary) -> void:
	players = roster
	in_match = true
	match_seed = seed_value
	match_size = roster.size()
	last_attacker = 0
	roster_changed.emit()
	if not dedicated:
		_go(GAME_SCENE)


@rpc("authority", "call_local", "unreliable_ordered")
func _stats(id: int, stats: Dictionary) -> void:
	if not players.has(id):
		return
	for k in stats:
		players[id][k] = stats[k]
	stats_changed.emit(id)


@rpc("authority", "call_local", "reliable")
func _incoming(from_id: int, attack: Dictionary) -> void:
	last_attacker = from_id
	attack_incoming.emit(from_id, attack)


@rpc("authority", "call_local", "reliable")
func _eliminated(id: int, place: int, reason: String) -> void:
	if players.has(id):
		players[id].alive = false
		players[id].place = place
	var reason_text := {"house": "house was overrun", "bug": "rolly polly was beaten", "left": "left the match"}
	chat_received.emit("", "%s is out (%s) - %s place" % [name_of(id), reason_text.get(reason, reason), ordinal(place)], Color(1, 0.6, 0.5))
	player_eliminated.emit(id, place)
	roster_changed.emit()


@rpc("authority", "call_local", "reliable")
func _match_over(winner_id: int, roster: Dictionary) -> void:
	players = roster
	last_results.clear()
	for id in players:
		var p: Dictionary = players[id]
		last_results.append([p.name, int(p.place), int(p.score)])
	last_results.sort_custom(func(a, b): return a[1] < b[1])
	if winner_id != 0:
		chat_received.emit("", "%s WINS! Last house standing." % name_of(winner_id), Color(1, 0.85, 0.2))
	chat_received.emit("", "Back to the lobby in %d seconds..." % int(BACK_TO_LOBBY_DELAY), Color(1, 0.85, 0.5))
	match_over.emit(winner_id)
	roster_changed.emit()


@rpc("authority", "call_local", "reliable")
func _back_to_lobby(roster: Dictionary) -> void:
	players = roster
	in_match = false
	for p in players.values():
		p.ready = false
		p.alive = false
		p.place = 0
	roster_changed.emit()
	if not dedicated:
		_go(LOBBY_SCENE)


@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	_fail(reason)


# ================================================================ misc

func _go(scene: String) -> void:
	Engine.time_scale = 1.0                              # a STRIKE's slow-mo must never carry over
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(scene)


func _clean_name(n: String) -> String:
	n = n.strip_edges().replace("[", "(").replace("]", ")")   # no BBCode tricks in the chat
	return n.left(14) if n != "" else "Player"


func _log(text: String) -> void:
	print("[Net] ", text)


static func ordinal(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "%dth" % n
	return "%d%s" % [n, {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")]


func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_FILE) == OK:
		my_name = str(cfg.get_value("net", "name", my_name))
		last_ip = str(cfg.get_value("net", "ip", last_ip))
		last_port = int(cfg.get_value("net", "port", last_port))


func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "name", my_name)
	cfg.set_value("net", "ip", last_ip)
	cfg.set_value("net", "port", last_port)
	cfg.save(CONFIG_FILE)
