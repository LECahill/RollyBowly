extends CharacterBody3D
## Rolly polly player: click near it, drag back, release to launch (slingshot style).
## It curls into a ball, rolls and bounces with momentum, bowls through ants,
## and unrolls once it comes to a stop. This is the only way to move.
##
## Scene setup:
##   Player (CharacterBody3D, this script)
##   ├── Pivot (Node3D)
##   │   ├── Unrolled   <- pillbug_unrolled.glb
##   │   └── Rolled     <- pillbug_rolled.glb (position y = 0.5 so the ball sits on the ground)
##   ├── CollisionShape3D   <- SphereShape3D, radius 0.5, position y = 0.5
##   └── MobDetector (Area3D) <- unchanged from before

signal hit
signal hp_changed(hp: int, max_hp: int)
signal roll_started                   # launched (for the combo counter)
signal ant_bowled(mob: Node)          # knocked an ant over while rolling
signal roll_ended                     # stopped / popped open

@export_group("Models")
@export var unrolled_model: Node3D
@export var rolled_model: Node3D
@export var camera_rig: Node                  ## optional: the CameraRig, for aim framing + shake

@export_group("Launch")
@export var max_launch_speed := 26.0          ## speed at full power (m/s)
@export_range(0.05, 1.0) var drag_screen_fraction := 0.3   ## drag this fraction of the screen height for full power
@export var grab_radius := 3.0                ## how close to the bug you must click (only if Require Click On Bug is on)
@export var require_click_on_bug := false     ## false = press anywhere on screen and drag back to aim
@export var click_to_stop := true             ## click while rolling to stop dead and pop open
@export var max_aim_time := 3.0               ## hold the aim this long and it launches by itself (stops ghost-camping)
@export var aim_warning_time := 1.0          ## the arrow flashes for this long before the auto-launch
@export var ghost_tint := Color(0.7, 0.9, 1.0, 0.55)    ## glow colour over the bug while aiming (alpha = strength)

@export_group("Controller")
## Xbox-style pad: hold A and aim with the left stick, let go of A to launch.
## A while rolling = stop and pop open. B while aiming = cancel.
@export var stick_points_at_target := true    ## true = push the stick the way you want to roll. false = pull back like a slingshot
@export_range(0.0, 0.6) var stick_deadzone := 0.2
@export var stick_snapback_time := 0.12       ## if the stick springs back to the middle just before you let go of A, use the aim from this long ago

@export_group("Power-ups")
@export var size_up_scale := 1.8              ## size-up berry: the bug grows to this size
@export var size_up_time := 15.0              ## ...for this many seconds (another berry restarts the timer)
@export var size_up_warning := 2.5            ## it wobbles for this long before shrinking back, as a warning
@export var size_up_launch_mult := 0.9        ## a big bug launches a little slower (it's heavy)...
@export var size_up_plow := 0.4               ## ...but plows through ants: speed lost per ant x this
@export var grow_speed := 3.0                 ## how quickly it grows / shrinks (size per second)
@export_range(0.0, 1.0) var powerup_tint := 0.65   ## how strongly the bug takes on the power-up's colour (0 = not at all)
@export var tint_time := 0.4                  ## seconds to fade into / out of the colour

@export_group("Health")
@export var max_hp := 3                       ## ant bites the bug can take (only while unrolled) before it's game over
@export var touch_kills := false              ## old tutorial rule: any ant touching the unrolled bug kills it instantly
@export var bite_invulnerability := 1.0       ## after a bite, the bug can't be bitten again for this long (s)

@export_group("Sound")
@export var roll_sound: AudioStream            ## looping rolling sound (drag grass_roll.mp3 here)
@export var roll_volume_db := 0.0             ## loudness at full speed
@export var roll_min_pitch := 0.75            ## pitch when rolling slowly
@export var roll_max_pitch := 1.35            ## pitch at full speed
@export var roll_full_speed := 20.0           ## speed that counts as "full" loudness/pitch
@export var roll_bus := &"Master"             ## audio bus to play on
@export var roll_repeat_distance := 3.14     ## replay the sound every this many units rolled (3.14 = one turn of the ball).
											  ## Smaller = repeats more often. 0 = one continuous loop instead
@export var roll_pitch_jitter := 0.06        ## small random pitch change per repeat so it never sounds robotic
@export var pop_min_pitch := 0.85            ## the pop sound plays at a random pitch between these each time
@export var pop_max_pitch := 1.25

@export_group("Rolling")
@export var move_every_frame := true          ## move in step with each drawn frame instead of fixed physics steps.
											  ## Browsers draw frames at uneven times, so this is what keeps the roll smooth there
@export var gravity := 30.0
@export var rolling_friction := 6.0           ## how fast it slows down on the ground (m/s²)
@export var bounce := 0.7                     ## 1 = perfect bounce off walls, 0 = dead stop
@export var ant_slowdown := 0.12              ## speed lost per ant bowled over
@export var armored_slowdown := 0.45          ## speed lost hitting a soldier's helmet (they're heavy)
@export var stop_speed := 0.8                 ## below this it stops and unrolls
@export var stuck_time := 0.6                 ## unroll if still rolled up but has barely moved for this long (s)
@export var stuck_distance := 0.3             ## "barely moved" = stayed within this distance
@export var ball_radius := 0.5                ## for the rolling spin visual
@export var arena: Node3D                     ## optional: limit the search to this node. Empty = search the whole scene
@export var wall_fraction := 0.976            ## safety wall as a fraction of the measured bowl radius (just inside the edge)
@export var fallback_arena_radius := 41.0     ## only used if no bowl collision can be found

var arena_radius := 41.0                      # measured at startup from the bowl collision (see Output panel)
var arena_center := Vector3.ZERO              # the wall is measured from the bowl's centre
var _arena_known := false                     # no safety wall until the arena size is known
var _arena_retry := false

enum State { IDLE, AIMING, ROLLING }
var state := State.IDLE
var hp := 3
var _safe_time := 0.0               # counts down after a bite

var _drag_point := Vector3.ZERO
var _aim_with_stick := false       # current aim comes from a controller instead of the mouse
var _pad := 0                      # which controller is aiming
var _stick := Vector2.ZERO         # launch direction on screen (x right, y down), length = power
var _stick_hist: Array = []        # recent [time, stick] pairs, for the snap-back fix
var _press_screen := Vector2.ZERO  # where the mouse went down (screen pixels): the pull is measured from here
var _drag_screen := Vector2.ZERO   # where the mouse is now (screen pixels)
var _last_dir := Vector3.FORWARD
var _still_time := 0.0
var _aim_time := 0.0
var _saved_layer := 0             # collision layer to restore after the ghost phase
var _ghost_mat: StandardMaterial3D
var _arrow_flash := 1.0           # 1 = normal, lower = dimmed (warning flash)
var _stuck_anchor := Vector3.ZERO   # where it was when the stuck timer last reset
var _stuck_timer := 0.0
var _arrow: MeshInstance3D
var _passed: Array[Node] = []     # ants we're currently rolling through
var _roll_player: AudioStreamPlayer
var _roll_level := 0.0            # smoothed 0..1 loudness of the rolling sound
var _roll_dist := 0.0             # distance rolled since the sound last started
var _pivot_scale := Vector3.ONE
var _pop_tween: Tween
var size_mult := 1.0               # current size (1 = normal). The camera zooms out with it
var _size_target := 1.0
var _size_time_left := 0.0
var _shape_node: CollisionShape3D
var _shape: SphereShape3D
var _base_radius := 0.5
var _base_shape_y := 0.5
var _tint_color := Color.WHITE
var _tint_amount := 0.0            # 0 = normal colours, 1 = fully tinted (scaled by powerup_tint)
var _tint_tween: Tween
var _tint_mats := []               # [{mat, base}] the bug's own materials (private copies), with their original colours
var _tinting := false              # size-up colour is on


func _ready() -> void:
	add_to_group("player")               # so ants can find (and chase) the bug
	hp = max_hp
	_pivot_scale = $Pivot.scale
	_set_rolled(false)
	_arrow = _make_arrow()
	add_child(_arrow)
	_arrow.visible = false
	_update_arena_radius()
	_setup_roll_sound()
	for c in get_children():                        # the ball's collision sphere, so it can grow with the bug
		if c is CollisionShape3D and c.shape is SphereShape3D:
			_shape_node = c
			_shape = c.shape.duplicate()               # own copy: never resize a shared resource
			c.shape = _shape
			_base_radius = _shape.radius
			_base_shape_y = c.position.y
			break
	if move_every_frame:
		# moved every drawn frame by its exact frame time, so physics interpolation isn't needed (and would lag it)
		set("physics_interpolation_mode", 2)        # Node.PHYSICS_INTERPOLATION_MODE_OFF


## Sets the safety wall from the arena's scale, so rescaling the arena never needs a manual update.
func _update_arena_radius() -> void:
	# Measure the actual bowl the rolly polly rolls on: every trimesh collision shape on a body this
	# player collides with. Works however the arena, its mesh or its collision shape are scaled.
	var search_root: Node = arena
	if search_root == null:
		search_root = get_tree().current_scene if get_tree().current_scene else get_tree().root
	var best_radius := 0.0
	var best_center := Vector3.ZERO
	var best_name := ""
	for body in search_root.find_children("*", "StaticBody3D", true, false):
		if (body.collision_layer & collision_mask) == 0:
			continue                                   # a body we can't touch doesn't count
		for cs in body.get_children():
			if not (cs is CollisionShape3D and cs.shape is ConcavePolygonShape3D):
				continue
			var xf: Transform3D = cs.global_transform
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for v in (cs.shape as ConcavePolygonShape3D).get_faces():
				var w := xf * v
				lo = Vector2(minf(lo.x, w.x), minf(lo.y, w.z))
				hi = Vector2(maxf(hi.x, w.x), maxf(hi.y, w.z))
			var r := maxf(hi.x - lo.x, hi.y - lo.y) * 0.5
			if r > best_radius:
				best_radius = r
				best_center = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)
				best_name = "%s/%s" % [body.name, cs.name]
	if best_radius == 0.0:
		if not _arena_retry:                           # arena may not be in the scene yet: try once more next frame
			_arena_retry = true
			_update_arena_radius.call_deferred()
			return
		arena_radius = fallback_arena_radius
		_arena_known = true
		push_warning("Player: no bowl collision found, using fallback_arena_radius = %s" % arena_radius)
		return
	arena_radius = best_radius * wall_fraction
	arena_center = best_center
	_arena_known = true
	print("Player: bowl '%s' measures %.1f across -> safety wall radius %.1f around %s" % [best_name, best_radius * 2.0, arena_radius, arena_center])


# ---------------------------------------------------------------- input

# _input (not _unhandled_input) so full-screen UI like the score overlay can't swallow the clicks.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _over_ui_button(event.position):
			return                                       # e.g. the pause button: tapping it isn't a launch
		if event.pressed and state == State.IDLE:
			var p = _mouse_on_ground(event.position)
			if p != null and (not require_click_on_bug or _flat(p - global_position).length() <= grab_radius):
				_press_screen = event.position
				_drag_screen = event.position
				_drag_point = p
				_begin_aim(false)
		elif event.pressed and state == State.ROLLING and click_to_stop:
			_pop_open()                                  # click mid-roll: stop dead and pop open
		elif not event.pressed and state == State.AIMING and not _aim_with_stick:
			_release()
	elif event is InputEventMouseMotion and state == State.AIMING and not _aim_with_stick:
		_drag_screen = event.position
		_update_aim()
	elif event is InputEventJoypadButton:
		if event.button_index == JOY_BUTTON_A:
			if event.pressed and state == State.IDLE:
				_pad = event.device
				_stick = Vector2.ZERO
				_stick_hist.clear()
				_begin_aim(true)
			elif event.pressed and state == State.ROLLING and click_to_stop:
				_pop_open()                              # A mid-roll: stop dead and pop open
			elif not event.pressed and state == State.AIMING and _aim_with_stick and event.device == _pad:
				_stick = _stick_at_release()
				_release()
		elif event.button_index == JOY_BUTTON_B and event.pressed and state == State.AIMING and _aim_with_stick:
			_stick = Vector2.ZERO                        # B: cancel the shot (tiny aim = unroll, no launch)
			_release()


## On-screen buttons that sit over the game (the pause button) are in the "blocks_bowling" group.
func _over_ui_button(pos: Vector2) -> bool:
	for c in get_tree().get_nodes_in_group("blocks_bowling"):
		if c is Control and c.is_visible_in_tree() and c.get_global_rect().has_point(pos):
			return true
	return false


func _begin_aim(with_stick: bool) -> void:
	state = State.AIMING
	_aim_with_stick = with_stick
	_aim_time = 0.0
	_set_rolled(true)
	_set_ghost(true)


## Reads the left stick every frame while aiming with a controller.
func _read_stick() -> void:
	var raw := Vector2(Input.get_joy_axis(_pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(_pad, JOY_AXIS_LEFT_Y))
	var v := Vector2.ZERO
	if raw.length() > stick_deadzone:                     # rescale so power starts at 0 right outside the deadzone
		v = raw.normalized() * clampf((raw.length() - stick_deadzone) / (1.0 - stick_deadzone), 0.0, 1.0)
	_stick = v if stick_points_at_target else -v
	var now := Time.get_ticks_msec() / 1000.0
	_stick_hist.append([now, _stick])
	while _stick_hist.size() > 0 and now - (_stick_hist[0][0] as float) > stick_snapback_time:
		_stick_hist.pop_front()
	_update_aim()


## Letting go of the stick and A at the same moment: the stick springs back to the middle a few
## frames before A is released, which would weaken or cancel the shot. Use the strongest recent aim.
func _stick_at_release() -> Vector2:
	var best := _stick
	for h in _stick_hist:
		if (h[1] as Vector2).length() > best.length():
			best = h[1]
	return best


## Slingshot measured on screen: drag back from wherever you pressed, launch the opposite way.
## Using screen pixels means the same flick gives the same power anywhere on the screen,
## and "up on screen" is always "up on screen", whichever way the camera is turned.
func _launch_vector() -> Vector3:
	var pull := _press_screen - _drag_screen
	var power := 0.0
	if _aim_with_stick:                                  # controller: the stick is already direction + power
		pull = _stick
		power = _stick.length()
		if power < 0.01:
			return Vector3.ZERO
	else:
		if pull.length() < 1.0:
			return Vector3.ZERO
		var vs := get_viewport().get_visible_rect().size
		var max_px := minf(vs.x, vs.y) * drag_screen_fraction   # short side: the same drag whichever way a phone is held
		power = clampf(pull.length() / max_px, 0.0, 1.0)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.ZERO
	# turn the on-screen direction into a direction on the ground, starting from the bug
	var bug_on_screen := cam.unproject_position(global_position)
	var ahead = _mouse_on_ground(bug_on_screen + pull.normalized() * 40.0)
	if ahead == null:
		return Vector3.ZERO
	var dir := _flat(ahead - global_position)
	return dir.normalized() * power if dir.length() > 0.001 else Vector3.ZERO


func _update_aim() -> void:
	var v := _launch_vector()
	var power := v.length()
	_arrow.visible = power > 0.05
	if _arrow.visible:
		var dir := v.normalized()
		var length := 1.0 + power * 5.0
		_arrow.global_transform = Transform3D(Basis.looking_at(dir), global_position + Vector3(0, 0.08, 0) + dir * (0.8 + length * 0.5))
		_arrow.scale = Vector3(1.0, 1.0, length)
		(_arrow.material_override as StandardMaterial3D).albedo_color = Color(1.0, 1.0 - power * 0.7, 0.2, 0.85 * _arrow_flash)
	if camera_rig:
		camera_rig.set_aim(v.normalized(), power)


func _release() -> void:
	_set_ghost(false)
	_arrow.visible = false
	if camera_rig:
		camera_rig.clear_aim()
	var v := _launch_vector()
	if v.length() < 0.08:                                    # tiny drag = cancel
		state = State.IDLE
		_set_rolled(false)
		return
	velocity = v * max_launch_speed * (size_up_launch_mult if size_mult > 1.05 else 1.0)
	_roll_dist = roll_repeat_distance                     # first roll sound plays right away
	_stuck_anchor = global_position
	_stuck_timer = 0.0
	_last_dir = v.normalized()
	_still_time = 0.0
	state = State.ROLLING
	roll_started.emit()
	if has_node("Launch"):
		$Launch.play()


# ---------------------------------------------------------------- physics

func _physics_process(delta: float) -> void:
	if not move_every_frame:
		_step(delta)


func _process(delta: float) -> void:
	if state == State.AIMING and _aim_with_stick:
		_read_stick()
	_update_size(delta)
	if not move_every_frame:
		return
	# Use the real time since the last drawn frame. A long frame is split into small steps so
	# collisions and bounces stay accurate even if the browser hiccups.
	var steps := ceili(delta / (1.0 / 60.0))
	for i in steps:
		_step(delta / steps)
		if not is_inside_tree():
			return


func _step(delta: float) -> void:
	if state == State.AIMING:
		# Pinned in place while winding up: nothing can push it off the launch spot.
		velocity = Vector3.ZERO
		_aim_time += delta
		var left := max_aim_time - _aim_time
		if _ghost_mat:                                       # gentle pulse while untouchable
			_ghost_mat.albedo_color.a = ghost_tint.a * (0.75 + 0.25 * sin(_aim_time * 8.0))
		if left < aim_warning_time and _arrow.visible:      # flash the arrow as a warning
			# fade via the material's own colour: works in every renderer, including the browser's
			_arrow_flash = 1.0 if fmod(left, 0.2) > 0.1 else 0.25
			(_arrow.material_override as StandardMaterial3D).albedo_color.a = 0.85 * _arrow_flash
		if _aim_time >= max_aim_time:
			_release()                                       # auto-launch with the current aim (or unroll if barely pulled)
		_update_roll_sound(0.0, false, delta)
		return
	_safe_time -= delta
	velocity.y -= gravity * delta
	var on_floor := false
	var touching := false                                    # on any surface we roll along (incl. bowl walls)
	var motion := velocity * delta

	for i in 4:                                              # resolve up to 4 contacts per frame
		var col := move_and_collide(motion)
		if col == null:
			break
		var n := col.get_normal()
		var other := col.get_collider()

		if other is Node and other.is_in_group("mob"):
			if state == State.ROLLING:
				_bowl(other)                                 # only a rolling bug knocks ants over
			add_collision_exception_with(other)              # pass through it (never ride on or get carried by ants)
			_passed.append(other)
			motion = col.get_remainder()
			continue

		if n.y > 0.25:                                       # ground, slopes and bowl walls: roll along them
			on_floor = on_floor or n.y > 0.6                 # friction/stopping only on gentle ground
			touching = true
			velocity = velocity.slide(n)
			motion = col.get_remainder().slide(n)
		else:                                                # near-vertical wall (house etc.): bounce off
			var into := -velocity.dot(n)
			velocity = velocity.bounce(n) * bounce if into > 2.0 else velocity.slide(n)
			motion = col.get_remainder().bounce(n) * bounce
			if into > 6.0 and camera_rig:
				camera_rig.add_shake(0.25)

	_keep_in_arena()

	var flat_v := _flat(velocity)
	if on_floor and flat_v.length() > 0.0:
		flat_v = flat_v.move_toward(Vector3.ZERO, rolling_friction * delta)
		velocity.x = flat_v.x
		velocity.z = flat_v.z

	if state == State.ROLLING:
		_spin_ball(flat_v, delta)
		if flat_v.length() > 0.5:
			_last_dir = flat_v.normalized()
		_still_time = _still_time + delta if (on_floor and flat_v.length() < stop_speed) else 0.0
		# backup: if it's still rolled up but hasn't really gone anywhere (wedged in a crease,
		# jiggling against a wall, resting on a steep slope), unroll anyway
		if global_position.distance_to(_stuck_anchor) > stuck_distance:
			_stuck_anchor = global_position
			_stuck_timer = 0.0
		else:
			_stuck_timer += delta
		if _still_time > 0.2 or _stuck_timer > stuck_time:
			_stop_rolling()
	elif on_floor:
		velocity.x = 0.0
		velocity.z = 0.0

	_update_roll_sound(_flat(velocity).length(), touching, delta)

	if global_position.y < -20.0:                            # fell out of the world: reset
		global_position = Vector3(0, 2, 6)
		velocity = Vector3.ZERO
		reset_physics_interpolation()                        # teleport: don't smear across the jump


# ---------------------------------------------------------------- rolling sound

func _setup_roll_sound() -> void:
	if roll_sound == null:
		return
	var stream: AudioStream = roll_sound.duplicate()
	var loop := roll_repeat_distance <= 0.0                  # continuous mode loops; repeat mode replays it
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = loop
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	_roll_player = AudioStreamPlayer.new()
	_roll_player.stream = stream
	_roll_player.bus = roll_bus
	_roll_player.volume_db = -80.0
	add_child(_roll_player)


## Louder and higher-pitched the faster it rolls; fades out in the air and when stopped.
## Repeat mode: replays the sound every roll_repeat_distance units, so it repeats faster at speed.
func _update_roll_sound(speed: float, touching: bool, delta: float) -> void:
	if _roll_player == null:
		return
	var rolling_on_ground := state == State.ROLLING and touching
	var want := clampf(speed / roll_full_speed, 0.0, 1.0) if rolling_on_ground else 0.0
	var rate := 12.0 if want > _roll_level else 6.0         # react fast to speed-ups, ease out on slow-downs
	_roll_level = lerpf(_roll_level, want, 1.0 - exp(-rate * delta))
	var pitch := lerpf(roll_min_pitch, roll_max_pitch, _roll_level)

	if roll_repeat_distance > 0.0:
		if rolling_on_ground:
			_roll_dist += speed * delta
			if _roll_dist >= roll_repeat_distance and speed > stop_speed:
				_roll_dist = fmod(_roll_dist, roll_repeat_distance)
				_roll_player.pitch_scale = pitch * (1.0 + randf_range(-roll_pitch_jitter, roll_pitch_jitter))
				_roll_player.play()                          # restarts the sound from the beginning
		if _roll_player.playing:
			_roll_player.volume_db = roll_volume_db + linear_to_db(maxf(_roll_level, 0.001))
			if _roll_level < 0.01:
				_roll_player.stop()
		return

	# continuous loop mode
	if _roll_level > 0.01:
		if not _roll_player.playing:                         # start somewhere random so it never sounds identical
			_roll_player.play(randf() * maxf(_roll_player.stream.get_length() - 0.1, 0.0))
		_roll_player.volume_db = roll_volume_db + linear_to_db(_roll_level)
		_roll_player.pitch_scale = pitch
	elif _roll_player.playing:
		_roll_player.stop()


func _bowl(mob: Node) -> void:
	var big := size_mult > 1.05                    # grown by the berry: armor doesn't stop it
	if mob.has_method("armor_up") and mob.armor_up() and not big:
		mob.knock_over(velocity, global_position)   # soldier: only knocks the helmet off
		velocity *= 1.0 - armored_slowdown
		if camera_rig:
			camera_rig.add_shake(0.5)
		_hit_stop(0.08)
		return
	ant_bowled.emit(mob)                 # before knock_over, so the combo can raise the hit sound's pitch first
	if mob.has_method("knock_over"):
		# pins fly off away from the ball. A big bug smashes soldiers in one hit: helmet off AND flipped
		mob.knock_over(velocity, global_position, big)
	elif mob.has_method("squash"):
		mob.squash()
	velocity *= 1.0 - ant_slowdown * (size_up_plow if size_mult > 1.05 else 1.0)
	if camera_rig:
		camera_rig.add_shake(0.4)
	_hit_stop(0.05)


func _keep_in_arena() -> void:
	if not _arena_known:
		return
	var flat := _flat(global_position - arena_center)
	if flat.length() > arena_radius:
		var out := flat.normalized()
		global_position -= out * (flat.length() - arena_radius)
		var outward := velocity.dot(out)
		if outward > 0.0:
			velocity -= out * outward          # glide along the edge instead of bouncing off


## Stop right where it is and pop open, with a quick squash-and-spring.
func _pop_open() -> void:
	velocity = Vector3(0.0, minf(velocity.y, 0.0), 0.0)
	_stop_rolling()
	if _pop_tween:
		_pop_tween.kill()
	$Pivot.scale = _pivot_scale * size_mult * Vector3(1.3, 0.7, 1.3)
	_pop_tween = create_tween()
	_pop_tween.tween_property($Pivot, "scale", _pivot_scale * size_mult, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if has_node("Pop"):
		$Pop.pitch_scale = randf_range(pop_min_pitch, pop_max_pitch)   # different every time
		$Pop.play()


func _stop_rolling() -> void:
	var was_rolling := state == State.ROLLING
	state = State.IDLE
	velocity = Vector3(0, velocity.y, 0)
	for m in _passed:
		if is_instance_valid(m):
			remove_collision_exception_with(m)
	_passed.clear()
	_set_rolled(false)
	if was_rolling:
		roll_ended.emit()


# ---------------------------------------------------------------- visuals

func _set_rolled(rolled: bool) -> void:
	if unrolled_model:
		unrolled_model.visible = not rolled
	if rolled_model:
		rolled_model.visible = rolled
		rolled_model.basis = Basis.IDENTITY
	if not rolled and _last_dir.length() > 0.1:
		# face the way it was rolling. Keep the current size: setting the rotation on its own would
		# reset the scale, which made a grown bug snap back to normal size whenever it unrolled
		$Pivot.basis = Basis.looking_at(_last_dir, Vector3.UP, true) * Basis.from_scale(_pivot_scale * size_mult)


## Ghost phase while aiming: see-through, and nothing collides with it, so ants walk
## straight through instead of pushing it. Ends as soon as it launches or cancels.
func _set_ghost(on: bool) -> void:
	if on:
		_saved_layer = collision_layer
		collision_layer = 0
	else:
		collision_layer = _saved_layer if _saved_layer != 0 else collision_layer
		_arrow_flash = 1.0
	# A glow drawn over the solid bug (not see-through, which shows the overlapping shell plates inside).
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.albedo_color = ghost_tint
	for m in find_children("*", "GeometryInstance3D", true, false):
		if m != _arrow:
			m.material_overlay = _ghost_mat if on else null


func _spin_ball(flat_v: Vector3, delta: float) -> void:
	if rolled_model == null or flat_v.length() < 0.05:
		return
	var axis := Vector3.UP.cross(flat_v.normalized())
	rolled_model.global_rotate(axis, flat_v.length() / (ball_radius * size_mult) * delta)


func _hit_stop(duration: float) -> void:
	Engine.time_scale = 0.05
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = Engine.get_meta("base_time_scale", 1.0)   # back to normal (or to a STRIKE slow-mo)


func _make_arrow() -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.35, 0.05, 1.0)
	m.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true          # always draw on top, so slopes and grass can't hide it
	mat.render_priority = 10
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.top_level = true
	m.set("physics_interpolation_mode", 2)   # placed every frame from the mouse: don't interpolate
	return m


# ---------------------------------------------------------------- power-ups

## Called by a power-up drop when the bug rolls through it.
## Called by a power-up drop when the bug rolls through it. color = the drop's colour.
func apply_powerup(kind: String, color := Color(0.5, 0.38, 1.0)) -> void:
	match kind:
		"size_up":
			_size_target = size_up_scale
			_size_time_left = size_up_time
			_tint_to(color, 1.0)
			if camera_rig:
				camera_rig.add_shake(0.35)
		_:
			push_warning("Player: unknown power-up '%s'" % kind)


func _update_size(delta: float) -> void:
	if _size_time_left > 0.0:
		_size_time_left -= delta
		if _size_time_left <= 0.0:
			_size_target = 1.0                                   # time's up: shrink back
			_tint_to(_tint_color, 0.0)                           # ...and fade back to normal colours
		elif _size_time_left < size_up_warning and not (_tint_tween and _tint_tween.is_running()):
			_set_tint(0.55 + 0.45 * cos(_size_time_left * 18.0))   # colour flickers with the wobble
	var want := _size_target
	if _size_time_left > 0.0 and _size_time_left < size_up_warning:
		want += sin(_size_time_left * 18.0) * 0.1 * (_size_target - 1.0)   # wobble: "about to shrink!"
	if is_equal_approx(size_mult, want):
		return
	size_mult = move_toward(size_mult, want, grow_speed * delta)
	if _shape:
		_shape.radius = _base_radius * size_mult
		_shape_node.position.y = _base_shape_y * size_mult       # bottom of the ball stays on the ground
	if not (_pop_tween and _pop_tween.is_running()):
		$Pivot.scale = _pivot_scale * size_mult


## Tweens the bug's colour toward `color` (amount 1) or back to normal (amount 0).
func _tint_to(color: Color, amount: float) -> void:
	_tint_color = color
	if _tint_tween:
		_tint_tween.kill()
	_tint_tween = create_tween()
	_tint_tween.tween_method(_set_tint, _tint_amount, amount, tint_time).set_trans(Tween.TRANS_SINE)


## Recolours the bug's own materials. Works on the opaque materials it already has (no see-through
## overlay), so it never costs the renderer anything extra.
func _set_tint(amount: float) -> void:
	_tint_amount = amount
	if _tint_mats.is_empty():
		_collect_tint_materials()
	var k := amount * powerup_tint
	for t in _tint_mats:
		t.mat.albedo_color = (t.base as Color).lerp(Color(_tint_color, (t.base as Color).a), k)


## Gives the bug's models their own copies of their materials (so tinting the bug can never
## recolour anything else that shares them) and remembers the original colours.
func _collect_tint_materials() -> void:
	for model in [unrolled_model, rolled_model]:
		if model == null:
			continue
		var meshes: Array = model.find_children("*", "MeshInstance3D", true, false)
		if model is MeshInstance3D:
			meshes.append(model)
		for mi: MeshInstance3D in meshes:
			if mi.mesh == null:
				continue
			for i in mi.mesh.get_surface_count():
				var m := mi.get_active_material(i)
				if not (m is BaseMaterial3D):
					continue
				var own: BaseMaterial3D = m.duplicate()
				mi.set_surface_override_material(i, own)
				_tint_mats.append({"mat": own, "base": own.albedo_color})


## Seconds of size-up left (0 = normal size). For UI.
func size_up_left() -> float:
	return maxf(_size_time_left, 0.0)


# ---------------------------------------------------------------- helpers

func _mouse_on_ground(screen_pos: Vector2):
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var plane := Plane(Vector3.UP, global_position.y)
	return plane.intersects_ray(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos))


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


# ---------------------------------------------------------------- death (unchanged behaviour)

func die() -> void:
	hit.emit()
	queue_free()


## Ants can only bite the bug while it's unrolled (curled up, its shell protects it).
func can_be_bitten() -> bool:
	return state == State.IDLE and hp > 0 and _safe_time <= 0.0


func heal(amount: int = 1) -> void:
	if hp <= 0:
		return
	hp = mini(hp + amount, max_hp)
	hp_changed.emit(hp, max_hp)


func take_bite(amount: int = 1) -> void:
	if not can_be_bitten():
		return
	hp = maxi(hp - amount, 0)
	_safe_time = bite_invulnerability
	hp_changed.emit(hp, max_hp)
	if camera_rig:
		camera_rig.add_shake(0.3)
	var red := StandardMaterial3D.new()                  # quick red flash
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	red.albedo_color = Color(1, 0.15, 0.1, 0.6)
	for m in find_children("*", "GeometryInstance3D", true, false):
		if m != _arrow:
			m.material_overlay = red
	get_tree().create_timer(0.25).timeout.connect(func():
		if not is_instance_valid(self):
			return
		for m in find_children("*", "GeometryInstance3D", true, false):
			if m != _arrow and m.material_overlay == red:
				m.material_overlay = null)
	if hp == 0:
		die()


func _on_mob_detector_body_entered(_body: Node3D) -> void:
	if touch_kills and state == State.IDLE:   # old instant-death rule, off by default (ants bite instead)
		die()
