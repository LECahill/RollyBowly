extends Node
## Hand cursor from the UI sheet: pointing finger normally, pressed finger while the mouse button is held,
## for the menus and the game alike. Also keeps the mouse inside the game window (desktop build).
##
## Controller: as soon as a controller is used (any button, stick or trigger) the cursor hides and the
## menus switch to controller navigation (see pad_ui.gd). Moving or clicking the mouse brings it back.
##
## Setup: right-click Main > Add Child Node > Node, name it "Cursor", attach this script.
## Uses res://ui/cursor_point.png and res://ui/cursor_press.png.

@export var ui_folder := "res://ui/"
@export var hotspot := Vector2(4, 3)              ## the fingertip (pixels from the image's top-left corner)
@export var confine_to_window := true             ## keep the mouse inside the game window (desktop only)
@export var stick_wake := 0.5                     ## how far a stick / trigger has to move to count as "using the controller"
@export var mouse_wake := 6.0                     ## how far (pixels) the mouse has to move to bring the cursor back

var _point: Texture2D
var _press: Texture2D
var _pad_pressing: BaseButton                     # the menu button A is holding down


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS              # the hand still presses while the game is paused
	_point = load(ui_folder + "cursor_point.png")
	_press = load(ui_folder + "cursor_press.png")
	_use(_point)
	_apply_mouse_mode()
	if PadUI.active:                                     # carried over from before a restart
		PadUI.grab_default.call_deferred()


func _use(tex: Texture2D) -> void:
	if tex == null:
		return
	# the normal arrow and the "pointing hand" shown over buttons both become the hand
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, hotspot)
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_POINTING_HAND, hotspot)


func _input(event: InputEvent) -> void:
	# finger or real mouse? (stops tapped buttons staying enlarged on touch screens, see UIFit.hover_ok)
	# Runs before the buttons see the event, so they already know when their hover signal fires.
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		UIFit.note_touch()
	elif event is InputEventMouse:
		if event.device == InputEvent.DEVICE_ID_EMULATION:  # Godot's pretend mouse made from a touch
			UIFit.note_touch()
		elif event is InputEventMouseMotion:
			UIFit.note_mouse()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_use(_press if event.pressed else _point)
		if event.pressed:
			_set_pad(false)
	elif event is InputEventMouseMotion:
		if event.relative.length() > mouse_wake:
			_set_pad(false)
	elif event is InputEventScreenTouch:
		_set_pad(false)
	elif event is InputEventJoypadButton:
		if event.pressed:
			var was := PadUI.active
			_set_pad(true)
			# the first press only picks up the menu (selects its button) instead of pressing something blind
			if not was and event.button_index == JOY_BUTTON_A and get_viewport().gui_get_focus_owner() != null:
				get_viewport().set_input_as_handled()
				_pad_pressing = null
				return
		if event.button_index == JOY_BUTTON_A:
			_pad_a(event.pressed)
	elif event is InputEventJoypadMotion and absf(event.axis_value) > stick_wake:
		_set_pad(true)


## A on the selected menu button: pushes it down on press and clicks it on release, same as the mouse.
func _pad_a(down: bool) -> void:
	if down:
		var f := get_viewport().gui_get_focus_owner()
		if f is BaseButton and not f.disabled and f.is_visible_in_tree():
			get_viewport().set_input_as_handled()
			_pad_pressing = f
			f.button_down.emit()
	elif _pad_pressing:
		get_viewport().set_input_as_handled()
		var b: BaseButton = _pad_pressing
		_pad_pressing = null
		if is_instance_valid(b):
			b.button_up.emit()
			b.pressed.emit()


func _set_pad(on: bool) -> void:
	if on == PadUI.active:
		return
	PadUI.set_active(on, get_tree())
	_apply_mouse_mode()


## Browsers don't allow a page to trap the mouse (only to hide it completely), so confining only
## applies to the desktop build. Alt+Tab still works, and the mouse is confined again when you come back.
func _apply_mouse_mode() -> void:
	var confine := confine_to_window and not OS.has_feature("web")
	if PadUI.active:
		Input.mouse_mode = Input.MOUSE_MODE_CONFINED_HIDDEN if confine else Input.MOUSE_MODE_HIDDEN
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CONFINED if confine else Input.MOUSE_MODE_VISIBLE


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_apply_mouse_mode()
