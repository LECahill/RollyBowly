extends CanvasLayer
## The online layer over a match. main.gd adds this when Net.online is true.
##   - scoreboard of every backyard (top right) and the chat (bottom left)
##   - sends our stats to the server a few times a second
##   - STRIKE / SPARE / big combos (combo.gd's attack_earned) become, in this order:
##       1. BLOCK:        ants are on their way to us -> cancel the attack that lands soonest
##       2. COUNTER-BOWL: we STRIKEd a group someone sent us -> it goes back to them, doubled
##       3. ATTACK:       otherwise -> sent to our target (STRIKE = soldiers, SPARE = sprinters, combo = queen)
##   - ants sent to us -> "INCOMING!" banner and a countdown (time to block!), then they march in
##   - our house / bug falls -> tell the server we're out; the server says we won -> victory book
##
## Keys: Enter or T = chat, Tab = change who your attacks go to (or click a name on the scoreboard).

const TARGET_RANDOM := 0
const TARGET_LEADER := -1
const TARGET_REVENGE := -2
const WARNING_TIME := 3.0             ## seconds between "INCOMING!" and the ants arriving: the window to block them

var main: Node
var board: Scoreboard
var chat: ChatBox
var _banner: Label
var _banner_tween: Tween
var _leave_btn: Button
var _leave_armed := false
var _target := TARGET_RANDOM          # one of the TARGET_ constants, or a player id
var _stats_left := 0.0
var _last_stats := {}
var _score_label: Node
var _pending: Array = []              # attacks on their way to us: {from, attack, left, uid}
var _pending_label: Label
var _next_uid := 0
var _bounced := {}                    # uid -> true: each sent group can only be bounced back once
var _k := 1.0


func _ready() -> void:
	layer = 25                                           # over the game HUD (game_ui is 30 for its book, which should win)
	main = get_parent()
	_score_label = main.get_node_or_null("UserInterface/ScoreLabel")

	board = Scoreboard.new(true)
	board.row_clicked.connect(_on_row_clicked)
	add_child(board)

	chat = ChatBox.new(true)
	add_child(chat)

	_leave_btn = Button.new()
	_leave_btn.text = "Leave match"
	_leave_btn.theme = NetUI.theme(18)
	_leave_btn.focus_mode = Control.FOCUS_NONE
	_leave_btn.add_to_group("blocks_bowling")
	_leave_btn.pressed.connect(_on_leave)
	add_child(_leave_btn)

	_banner = NetUI.label("", 54, Color.WHITE, 14, NetUI.BROWN)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0
	add_child(_banner)

	_pending_label = NetUI.label("", 30, Color(1.0, 0.55, 0.45), 9, NetUI.BROWN)
	_pending_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_pending_label)

	Net.attack_incoming.connect(_on_attack_incoming)
	Net.match_over.connect(_on_match_over)
	Net.chat_received.connect(_on_chat_for_feed)
	if main.has_signal("game_ended"):
		main.game_ended.connect(_on_game_ended)
	_hook_combo.call_deferred()
	get_viewport().size_changed.connect(_layout)
	_layout()
	_update_target_label()
	chat.add_message("", "STRIKE = send soldiers, SPARE = sprinters, 4+ combo = a queen. Earn one while ants are INCOMING to block them. STRIKE a group someone sent you to bounce it back doubled! Tab = target, Enter = chat.", Color(1, 0.85, 0.5))


func _hook_combo() -> void:
	var combo := get_tree().get_first_node_in_group("combo")
	if combo and combo.has_signal("attack_earned"):
		combo.attack_earned.connect(_on_attack_earned)
	else:
		push_warning("MpHud: combo.gd has no attack_earned signal, attacks are off")


func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	_k = clampf(UIFit.hud_k(get_viewport()) * 1.25, 0.75, 1.8)
	var top := UIFit.top_bar_bottom(get_viewport()) + 10.0
	# scoreboard: top right, under the hearts
	board.reset_size()
	board.scale = Vector2.ONE * _k
	board.position = Vector2(vs.x - board.size.x * _k - 16.0, top)
	_leave_btn.reset_size()
	_leave_btn.scale = Vector2.ONE * _k
	_leave_btn.position = Vector2(vs.x - _leave_btn.size.x * _k - 16.0, top + board.size.y * _k + 8.0)
	# chat: bottom left
	var cs := Vector2(430, 210)
	chat.size = cs
	chat.scale = Vector2.ONE * _k
	chat.position = Vector2(16.0, vs.y - cs.y * _k - 16.0)
	# banner: across the middle-top
	_banner.size = Vector2(vs.x, 140)
	_banner.position = Vector2(0, vs.y * 0.24)
	_pending_label.size = Vector2(vs.x, 120)
	_pending_label.position = Vector2(0, vs.y * 0.24 + 110)
	_pending_label.label_settings.font_size = int(30 * clampf(_k, 0.8, 1.4))


func _process(delta: float) -> void:
	_layout_follow()
	_tick_pending(delta)
	_stats_left -= delta
	if _stats_left <= 0.0:
		_stats_left = Net.STATS_INTERVAL
		_send_stats()


## The scoreboard grows and shrinks as rows change: keep it pinned to the right edge.
func _layout_follow() -> void:
	var vs := get_viewport().get_visible_rect().size
	board.reset_size()
	board.position.x = vs.x - board.size.x * _k - 16.0
	_leave_btn.position = Vector2(vs.x - _leave_btn.size.x * _k - 16.0, board.position.y + board.size.y * _k + 8.0)


# ---------------------------------------------------------------- stats

func _send_stats() -> void:
	var house = main.get("house")
	var player = main.get("player")
	var bug_ok: bool = player != null and is_instance_valid(player) and player.is_inside_tree()
	var stats := {
		"score": int(_score_label.score) if _score_label and "score" in _score_label else 0,
		"wave": int(main.get("wave")),
		"house_hp": int(house.hp) if house else 0,
		"house_max": int(house.max_hp) if house else 1,
		"bug_hp": int(player.hp) if bug_ok else 0,
		"bug_max": int(player.max_hp) if bug_ok else int(_last_stats.get("bug_max", 3)),
	}
	if stats != _last_stats:
		_last_stats = stats
		Net.report_stats(stats)


# ---------------------------------------------------------------- attacks

func _on_attack_earned(attack: Dictionary, reason: String, struck: Node) -> void:
	if main.get("game_over"):
		return
	# 1. BLOCK: anything we earn while ants are on their way cancels the attack that lands soonest
	if not _pending.is_empty():
		var soonest := 0
		for i in _pending.size():
			if _pending[i].left < _pending[soonest].left:
				soonest = i
		var p: Dictionary = _pending[soonest]
		_pending.remove_at(soonest)
		_update_pending_label()
		_show_banner("BLOCKED %s's %s!" % [Net.name_of(p.from), Net.describe_attack(p.attack)], Color(0.55, 0.9, 1.0))
		Net.report_block(p.from, p.attack)
		return
	# 2. COUNTER-BOWL: a STRIKE on a group another player sent us goes back to them, doubled
	if struck != null and is_instance_valid(struck) and struck.has_meta("sent_by"):
		var sender := int(struck.get_meta("sent_by"))
		var uid := int(struck.get_meta("sent_uid", 0))
		var alive: bool = Net.players.has(sender) and bool(Net.players[sender].get("alive", false))
		if sender != Net.my_id() and alive and not _bounced.has(uid):
			_bounced[uid] = true
			var original: Dictionary = struck.get_meta("sent_attack", {})
			var doubled := {}
			for k in original:
				doubled[k] = int(original[k]) * 2
			Net.send_attack(Net.clean_attack(doubled), sender, "COUNTER-BOWL")
			return
	# 3. ATTACK
	Net.send_attack(attack, _resolve_target(), reason)


## Turn the chosen mode into a player id (0 = let the server pick at random).
func _resolve_target() -> int:
	var others: Array = Net.alive_ids()
	others.erase(Net.my_id())
	if others.is_empty():
		return 0
	match _target:
		TARGET_RANDOM:
			return 0
		TARGET_LEADER:
			var best := 0
			var best_score := -1
			for id in others:
				var s := int(Net.players[id].get("score", 0))
				if s > best_score:
					best_score = s
					best = id
			return best
		TARGET_REVENGE:
			return Net.last_attacker if Net.last_attacker in others else 0
	return _target if _target in others else 0


func _cycle_target() -> void:
	var order: Array = [TARGET_RANDOM, TARGET_LEADER, TARGET_REVENGE]
	for id in Net.alive_ids():
		if id != Net.my_id():
			order.append(id)
	var i := order.find(_target)
	_target = order[(i + 1) % order.size()]
	_update_target_label()


func _on_row_clicked(id: int) -> void:
	if id == Net.my_id() or not Net.players.has(id) or not Net.players[id].get("alive", false):
		return
	_target = TARGET_RANDOM if _target == id else id    # click again to go back to random
	_update_target_label()


func _update_target_label() -> void:
	var mode := "Random"
	match _target:
		TARGET_LEADER:
			mode = "Leader"
		TARGET_REVENGE:
			mode = "Revenge"
		TARGET_RANDOM:
			mode = "Random"
		_:
			mode = Net.name_of(_target)
	board.set_target(_target if _target > 0 else 0, mode)


func _on_attack_incoming(from_id: int, attack: Dictionary) -> void:
	if main.get("game_over"):
		return
	_next_uid += 1
	_pending.append({"from": from_id, "attack": attack, "left": WARNING_TIME, "uid": _next_uid})
	_show_banner("INCOMING!  %s from %s" % [Net.describe_attack(attack), Net.name_of(from_id)], Net.color_of(from_id))
	_update_pending_label()


## Count down the attacks on their way; when one arrives, its ants march in (main.spawn_incoming).
func _tick_pending(delta: float) -> void:
	if _pending.is_empty():
		return
	for p in _pending.duplicate():
		p.left -= delta
		if p.left <= 0.0:
			_pending.erase(p)
			if not main.get("game_over") and main.has_method("spawn_incoming"):
				main.spawn_incoming(p.attack, p.from, Net.name_of(p.from), Net.color_of(p.from), p.uid)
	_update_pending_label()


func _update_pending_label() -> void:
	if _pending.is_empty():
		_pending_label.text = ""
		return
	var lines := PackedStringArray()
	for p in _pending:
		lines.append("%s: %s in %.1fs" % [Net.name_of(p.from), Net.describe_attack(p.attack), maxf(p.left, 0.0)])
	lines.append("Bowl a STRIKE, SPARE or 4+ combo to BLOCK!")
	_pending_label.text = "\n".join(lines)


func _show_banner(text: String, color: Color) -> void:
	_banner.text = text
	_banner.label_settings.font_color = color.lightened(0.15)
	_banner.pivot_offset = _banner.size * 0.5
	if _banner_tween:
		_banner_tween.kill()
	_banner.modulate.a = 1.0
	_banner.scale = Vector2.ONE * 0.4
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_interval(1.4)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.5)


## Our own attacks show up as a banner too ("STRIKE! 4 ants + 1 soldier -> Sam"), so you know it went out.
func _on_chat_for_feed(from_name: String, text: String, _color: Color) -> void:
	var mine: String = Net.name_of(Net.my_id()) + " "
	if from_name == "" and text.begins_with(mine) and "->" in text:
		_show_banner(text.substr(mine.length()), Net.color_of(Net.my_id()))


# ---------------------------------------------------------------- end of the match

func _on_game_ended(reason: String) -> void:
	_pending.clear()                                     # nothing more lands on a finished backyard
	_update_pending_label()
	if reason != "win":
		Net.report_eliminated(reason)


func _on_match_over(winner_id: int) -> void:
	if winner_id == Net.my_id() and not main.get("game_over"):
		main._end_game("win")


func _on_leave() -> void:
	if not _leave_armed:
		_leave_armed = true
		_leave_btn.text = "Click again to leave"
		await get_tree().create_timer(2.5).timeout
		if is_instance_valid(_leave_btn):
			_leave_armed = false
			_leave_btn.text = "Leave match"
		return
	Net.leave()
	Net._go(Net.MENU_SCENE)


# ---------------------------------------------------------------- keys

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if chat.is_typing():
		return                                           # the chat line has the keyboard
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_T:
		if _book_is_open():
			return                                       # Enter is PLAY AGAIN / WATCH on the game-over book
		get_viewport().set_input_as_handled()
		chat.start_typing()
	elif event.keycode == KEY_TAB:
		get_viewport().set_input_as_handled()
		_cycle_target()


func _book_is_open() -> bool:
	var ui := get_tree().get_first_node_in_group("game_over_screen")
	return ui != null and ui.get("_book_open") == true
