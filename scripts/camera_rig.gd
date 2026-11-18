extends Node3D
## Bowling camera: angled top-down view following the rolly polly. Fixed direction by default;
## turn on Allow Rotation for Q / E (or controller) 90° turns.
## Pulled back while aiming (see the ants you're lining up), pushed in while rolling (feels fast),
## leads ahead of the roll, stays inside the arena, and can shake on impacts.
##
## Scene setup:
##   CameraRig (Node3D, this script)
##   └── Camera3D

@export var target: Node3D                       ## the rolly polly (RigidBody3D or CharacterBody3D)
@export_range(30.0, 85.0) var pitch_deg := 60.0  ## 90 = straight down, lower = more dramatic
@export var aim_distance := 26.0                 ## camera distance while aiming / idle
@export var roll_distance := 19.0                ## camera distance while rolling
@export var follow_speed := 4.0                  ## how quickly the camera catches up
@export var zoom_speed := 2.0                    ## how quickly it zooms between aim / roll
@export var lead_time := 0.35                    ## look ahead this many seconds along the roll
@export var max_lead := 6.0
@export var forward_bias := 4.0                  ## frame ahead (north) so the rolly polly sits low on screen
@export var clamp_fraction := 0.78               ## how far (as a fraction of the player's arena radius) the view centre may pan
@export var arena_clamp_margin := 7.0            ## stop panning this far inside that
@export var fallback_arena_clamp := 9.0          ## only used if no arena can be found
@export var max_target_offset := 6.0             ## the rolly polly never gets further than this from the view centre
@export_range(0.0, 1.0) var size_zoom := 0.5   ## zoom out when the rolly polly grows (0 = never, 1 = as much as it grows)
@export var rolling_speed := 1.5                 ## above this speed counts as rolling
@export var allow_rotation := false             ## Q / E (and controller) camera turning. Off: the view stays put, and the
												## house fades out of the way instead (occlusion_fader.gd)
@export var rotate_step_deg := 90.0             ## how far one tap of Q / E turns the view
@export var rotate_speed := 8.0                 ## how quickly the view swings round
@export var trigger_press := 0.6                ## controller: squeeze a trigger past this to turn
@export var trigger_release := 0.3              ## ...and let it back under this before it can turn again
@export var stick_flick := 0.6                  ## controller: push the right stick left / right past this to turn
@export var stick_recenter := 0.3               ## ...and let it come back under this before it can turn again
@export_group("Phone held upright")
## These are for a tall phone screen (about 9:19.5). Screens in between, like an iPad held upright (3:4),
## get a blend of these and the normal settings, so the view changes smoothly with the screen's shape.
@export var portrait_fov := 52.0                ## side-to-side view angle when the screen is taller than wide
@export var portrait_zoom := 0.95               ## camera this much further back, so the arena still fits across
@export_range(30.0, 85.0) var portrait_pitch_deg := 64.0   ## look down a bit more, so the top of the tall view stays on the lawn
@export var phone_aspect := 2.1                 ## height / width at which the settings above apply in full
@export_group("")
@export var rotate_left_key := KEY_Q
@export var rotate_right_key := KEY_E

@onready var cam: Camera3D = $Camera3D

var _distance := 0.0
var _aim_offset := Vector3.ZERO
var _shake := 0.0
var arena_clamp := INF                           # set at startup from the arena's scale (see Output panel)
var _clamp_known := false
var _clamp_frames := 0
var arena_center := Vector3.ZERO
var _yaw := 0.0                                  # current view direction (radians, 0 = looking north)
var _yaw_target := 0.0
var _trigger_held := {}                          # (device, trigger) -> currently squeezed
var _rstick_dir := {}
var _base_fov := 75.0
var _portrait := false
var _tall := 0.0                                  # 0 = square or wider, 1 = phone-tall (blends the portrait settings)


func _ready() -> void:
	# This rig is moved every rendered frame, so it must not be physics-interpolated itself
	# (it follows the player's *interpolated* position instead; see _target_pos()).
	set("physics_interpolation_mode", 2)            # Node.PHYSICS_INTERPOLATION_MODE_OFF
	if cam:
		cam.set("physics_interpolation_mode", 2)
	if cam:
		_base_fov = cam.fov
	_update_aspect()
	_distance = aim_distance * lerpf(1.0, portrait_zoom, _tall)
	if target:
		global_position = Vector3(target.global_position.x, 0.0, target.global_position.z - forward_bias)
	_place_camera()


## The player's position as drawn on screen this frame. With physics interpolation on
## (Project Settings > Physics > Common), this is smooth even when the monitor refresh
## rate doesn't match the 60 Hz physics rate, which is common in browsers.
func _target_pos() -> Vector3:
	if target.is_inside_tree() and target.has_method("get_global_transform_interpolated") \
			and get_tree().physics_interpolation:
		return target.get_global_transform_interpolated().origin
	return target.global_position


## Takes the arena size the player measured, so rescaling the arena needs no manual update.
func _update_arena_clamp() -> void:
	if target and is_instance_valid(target) and target.get("_arena_known"):
		arena_clamp = maxf(target.arena_radius * clamp_fraction - arena_clamp_margin, 0.0)
		arena_center = target.arena_center
		_clamp_known = true
		print("CameraRig: arena clamp %.1f around %s (from player's arena radius %.1f)" % [arena_clamp, arena_center, target.arena_radius])
	elif _clamp_frames > 10:                         # target never measured an arena: use the fallback
		arena_clamp = fallback_arena_clamp
		_clamp_known = true
		push_warning("CameraRig: player has no arena size, using fallback_arena_clamp = %s" % arena_clamp)


## Call every frame while the player is dragging. dir = launch direction, power = 0..1.
## Slides the view toward where they're aiming so they can see the targets.
func set_aim(dir: Vector3, power: float) -> void:
	dir.y = 0.0
	_aim_offset = dir.normalized() * 6.0 * clampf(power, 0.0, 1.0) if dir.length() > 0.01 else Vector3.ZERO


# _input (not _unhandled_input) so UI can't swallow the key presses.
func _input(event: InputEvent) -> void:
	if not allow_rotation:
		return
	if event is InputEventJoypadMotion and event.axis == JOY_AXIS_RIGHT_X:
		# controller: flick the right stick left / right to turn the view (one turn per flick;
		# it has to come back toward the middle before it can turn again)
		var dir: int = _rstick_dir.get(event.device, 0)
		if dir == 0 and absf(event.axis_value) >= stick_flick:
			_rstick_dir[event.device] = signi(roundi(signf(event.axis_value)))
			_yaw_target += deg_to_rad(rotate_step_deg) * (1.0 if event.axis_value < 0.0 else -1.0)   # left = Q, right = E
		elif dir != 0 and absf(event.axis_value) <= stick_recenter:
			_rstick_dir[event.device] = 0
		return
	if event is InputEventJoypadMotion and (event.axis == JOY_AXIS_TRIGGER_LEFT or event.axis == JOY_AXIS_TRIGGER_RIGHT):
		# controller: LT / RT turn the view. Triggers are analog, so one squeeze = one turn
		# (it has to be let go past trigger_release before it can turn again)
		var key := Vector2i(event.device, event.axis)
		var held: bool = _trigger_held.get(key, false)
		if not held and event.axis_value >= trigger_press:
			_trigger_held[key] = true
			_yaw_target += deg_to_rad(rotate_step_deg) * (1.0 if event.axis == JOY_AXIS_TRIGGER_LEFT else -1.0)
		elif held and event.axis_value <= trigger_release:
			_trigger_held[key] = false
		return
	if event is InputEventJoypadButton and event.pressed:   # controller: LB / RB turn the view
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_yaw_target += deg_to_rad(rotate_step_deg)
		elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_yaw_target -= deg_to_rad(rotate_step_deg)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if get_viewport().gui_get_focus_owner() is LineEdit:
			return                                           # typing in the chat: Q and E are letters, not camera keys
		if event.keycode == rotate_left_key or event.physical_keycode == rotate_left_key:
			_yaw_target += deg_to_rad(rotate_step_deg)
		elif event.keycode == rotate_right_key or event.physical_keycode == rotate_right_key:
			_yaw_target -= deg_to_rad(rotate_step_deg)


## Turn the view by code (e.g. from on-screen buttons): +1 = left, -1 = right.
func rotate_view(steps: int) -> void:
	if not allow_rotation:
		return
	_yaw_target += deg_to_rad(rotate_step_deg) * steps


func clear_aim() -> void:
	_aim_offset = Vector3.ZERO


## Call when the rolly polly hits something. 0.3 = small bump, 0.7 = big hit.
func add_shake(amount: float = 0.4) -> void:
	_shake = maxf(_shake, amount)


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):   # player may have been freed
		return
	if not _clamp_known:
		_clamp_frames += 1
		_update_arena_clamp()

	var vel := Vector3.ZERO
	if target is RigidBody3D:
		vel = (target as RigidBody3D).linear_velocity
	elif target is CharacterBody3D:
		vel = (target as CharacterBody3D).velocity
	vel.y = 0.0
	var rolling := vel.length() > rolling_speed

	var tpos := _target_pos()
	_yaw = lerp_angle(_yaw, _yaw_target, 1.0 - exp(-rotate_speed * delta))
	var screen_up := Vector3(-sin(_yaw), 0.0, -cos(_yaw))  # "ahead" on screen, whichever way the view faces
	var focus := tpos + screen_up * forward_bias \
			+ (vel * lead_time).limit_length(max_lead) + _aim_offset
	var flat := Vector2(focus.x - arena_center.x, focus.z - arena_center.z).limit_length(arena_clamp)
	focus = Vector3(arena_center.x + flat.x, 0.0, arena_center.z + flat.y)
	# never let the arena clamp push the rolly polly off screen
	var to_target := Vector3(tpos.x, 0.0, tpos.z) - focus
	if to_target.length() > max_target_offset:
		focus += to_target - to_target.normalized() * max_target_offset

	var t := 1.0 - exp(-follow_speed * delta)       # frame-rate independent smoothing
	global_position = global_position.lerp(focus, t)
	var grow = target.get("size_mult")
	var zoom := lerpf(1.0, grow, size_zoom) if grow != null else 1.0   # bigger bug -> camera further back
	_update_aspect()
	zoom *= lerpf(1.0, portrait_zoom, _tall)
	_distance = lerpf(_distance, (roll_distance if rolling else aim_distance) * zoom, 1.0 - exp(-zoom_speed * delta))
	_shake = maxf(_shake - delta * 1.8, 0.0)
	_place_camera()


## Phone held upright: keep the view's width instead of its height, so the arena doesn't become a
## thin slice down the middle of the screen.
func _update_aspect() -> void:
	if cam == null:
		return
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.y / maxf(vs.x, 1.0)
	_portrait = aspect > 1.0
	_tall = clampf(inverse_lerp(1.0, phone_aspect, aspect), 0.0, 1.0)
	if not _portrait:
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.fov = _base_fov
		return
	# upright: keep the width. At a square screen this matches the normal view exactly
	# (same angle across), then it eases toward the phone settings as the screen gets taller.
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = lerpf(_base_fov, portrait_fov, _tall)


func _place_camera() -> void:
	var p := deg_to_rad(lerpf(pitch_deg, portrait_pitch_deg, _tall))
	cam.position = Basis(Vector3.UP, _yaw) * (Vector3(0.0, sin(p), cos(p)) * _distance)   # orbit around the focus point
	cam.rotation = Vector3(-p, _yaw, 0.0)
	var s := _shake * _shake
	cam.h_offset = randf_range(-1.0, 1.0) * s
	cam.v_offset = randf_range(-1.0, 1.0) * s
