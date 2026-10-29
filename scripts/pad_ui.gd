class_name PadUI
extends RefCounted
## Controller support for the menus (title, how-to book, pause menu, game-over book).
##
## Nothing to add to the scene: the menus call these functions themselves, and cursor.gd switches
## between "mouse mode" and "controller mode":
##   - touch the controller (any button, or a stick / trigger) -> the mouse cursor hides, and the menu
##     that's open gets a pointing hand on its default button. D-pad / left stick move it, A presses.
##   - move or click the mouse -> the cursor comes back and the hand goes away.

static var active := false                   ## true while the player is using a controller

static var _default: Control                 # the button a menu wants selected first
static var _hand: TextureRect                # the little pointing hand on the selected button
static var _hand_tween: Tween
const HAND_TEXTURE := "res://ui/cursor_point.png"


## Turns a menu's buttons into a controller-navigable list (in this order) and picks `default`.
## horizontal: left / right moves between them (otherwise up / down). Either way it wraps around.
static func hook(buttons: Array, default: Control = null, horizontal := false) -> void:
	var list: Array = buttons.filter(func(b): return b != null and is_instance_valid(b))
	var n := list.size()
	for i in n:
		var b: Control = list[i]
		var prev: Control = list[(i - 1 + n) % n]
		var next: Control = list[(i + 1) % n]
		b.focus_mode = Control.FOCUS_ALL
		var self_path := b.get_path_to(b)
		if horizontal:
			b.focus_neighbor_left = b.get_path_to(prev)
			b.focus_neighbor_right = b.get_path_to(next)
			b.focus_neighbor_top = self_path
			b.focus_neighbor_bottom = self_path
		else:
			b.focus_neighbor_top = b.get_path_to(prev)
			b.focus_neighbor_bottom = b.get_path_to(next)
			b.focus_neighbor_left = self_path
			b.focus_neighbor_right = self_path
		b.focus_previous = b.get_path_to(prev)
		b.focus_next = b.get_path_to(next)
		if not b.focus_entered.is_connected(_on_focus.bind(b)):
			b.focus_entered.connect(_on_focus.bind(b))
	focus_default(default if default else (list[0] if n > 0 else null))


## Buttons that are faded out (e.g. the title page behind the how-to book) can't be selected.
static func set_enabled(buttons: Array, on: bool) -> void:
	for b in buttons:
		if b is BaseButton and is_instance_valid(b):
			b.focus_mode = Control.FOCUS_ALL if on else Control.FOCUS_NONE
			if not on and b.has_focus():
				b.release_focus()


## The button to select when the controller is picked up (selected right away if it already is).
static func focus_default(b: Control) -> void:
	_default = b
	if active:
		grab_default()


## No menu open any more (game started / unpaused): nothing to select.
static func clear() -> void:
	_default = null
	_hide_hand()


## Selects the default button if nothing is selected. Returns true if it selected something.
static func grab_default() -> bool:
	if _default == null or not is_instance_valid(_default) or not _default.is_inside_tree():
		_default = null
		return false
	if not _default.is_visible_in_tree() or _default.focus_mode == Control.FOCUS_NONE:
		return false
	var owner := _default.get_viewport().gui_get_focus_owner()
	if owner and owner.is_visible_in_tree() and owner.focus_mode != Control.FOCUS_NONE:
		return false                                       # something's already selected
	_default.grab_focus()
	return true


## Called by cursor.gd when the player switches between mouse and controller.
static func set_active(on: bool, tree: SceneTree) -> void:
	if on == active:
		return
	active = on
	if on:
		grab_default()
		var f := tree.root.gui_get_focus_owner()
		if f:
			_on_focus(f)
	else:
		_hide_hand()
		var f := tree.root.gui_get_focus_owner()
		if f:
			f.release_focus()                              # so the mouse hover look takes over again


static func _on_focus(b: Control) -> void:
	if not active or not is_instance_valid(b):
		return
	if _hand == null or not is_instance_valid(_hand):
		_hand = TextureRect.new()
		_hand.texture = load(HAND_TEXTURE) if ResourceLoader.exists(HAND_TEXTURE) else null
		_hand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_hand.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_hand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _hand.get_parent():
		_hand.get_parent().remove_child(_hand)
	b.add_child(_hand)                                     # rides along with the button's own animations
	var k := UIFit.hud_k(b.get_viewport())
	var s := clampf(b.size.y * 0.75, 44.0 * k, 72.0 * k)
	_hand.size = Vector2(s, s)
	_hand.pivot_offset = Vector2.ZERO
	var rest := Vector2(b.size.x * 0.84, b.size.y * 0.45)  # fingertip on the button's lower right
	_hand.position = rest + Vector2(14, 14) * k
	_hand.visible = true
	if _hand_tween and _hand_tween.is_valid():
		_hand_tween.kill()
	_hand_tween = _hand.create_tween().set_loops()
	_hand_tween.set_ignore_time_scale(true)
	_hand_tween.tween_property(_hand, "position", rest, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_hand_tween.tween_property(_hand, "position", rest + Vector2(6, 6) * k, 0.45).set_trans(Tween.TRANS_SINE)
	_hand_tween.tween_property(_hand, "position", rest, 0.45).set_trans(Tween.TRANS_SINE)
	# a little hop on the newly selected button
	var hop := b.create_tween()
	hop.set_ignore_time_scale(true)
	hop.tween_property(b, "rotation", deg_to_rad(-3.0), 0.06)
	hop.tween_property(b, "rotation", 0.0, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func _hide_hand() -> void:
	if _hand_tween and _hand_tween.is_valid():
		_hand_tween.kill()
	if _hand and is_instance_valid(_hand):
		_hand.visible = false
