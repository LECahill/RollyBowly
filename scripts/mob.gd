class_name Mob
extends CharacterBody3D
## Worker ant (real time).
##   MARCH  -> walk to the mushroom house
##   ATTACK -> at the house wall: bite it every attack_interval seconds
##   CHASE  -> the bug came within aggro_radius: chase it (and bite it) until it's further than leash_radius
##   KNOCKED-> bowled over by the rolling bug: flips on its back, then counts for score and disappears

@export_group("Movement")
@export var min_speed: float = 2.5            ## each ant gets a random speed between these (m/s)
@export var max_speed: float = 4.0
@export var chase_speed_multiplier := 1.25    ## ants hurry a little when chasing the bug
@export var turn_speed := 8.0                 ## how quickly they turn to face where they're going
@export var separation_radius := 1.5         ## ants keep about this much space from each other (no stacking)
@export var separation_strength := 1.2       ## how firmly they spread out

@export_group("Aggro")
@export var chases_player := false            ## worker ants: off (march straight to the house). Soldier ants: on
@export var aggro_radius := 6.0              ## bug this close -> chase it
@export var leash_radius := 12.0              ## bug further than this -> give up, go back to the house

@export_group("Attack")
@export var attack_damage := 2                ## damage per bite on the house
@export var attack_interval := 1.5            ## seconds between bites (house and bug)
@export var attack_reach := 0.6               ## bite the house from this close to its wall
@export var bite_range := 1.4                 ## bite the bug from this close

@export_group("Formation")
@export var formation_break_distance := 6.0   ## keep formation until this close to the house, then go for the wall

@export_group("Knocked over (bowling pins)")
@export var knocked_time: float = 1.6         ## how long it lies on its back before it counts and disappears
@export var flip_lift: float = 0.6            ## lift the model when flipped so it doesn't sink into the ground
@export var knock_speed := 0.65               ## flies off at this fraction of the speed that hit it
@export var knock_deflect := 0.5              ## 0 = flies the way the hitter was going, 1 = straight away from the hitter
@export var pin_slide_friction := 10.0        ## how quickly a flying ant slows down (m/s²)
@export var pin_hit_radius := 1.2             ## a flying ant knocks over standing ants this close to it
@export var pin_min_speed := 2.0              ## a flying ant slower than this can't knock others over
@export var pin_transfer := 0.8               ## an ant hit by a flying ant gets this fraction of its speed
@export var pin_hop := 0.35                   ## how high it pops up when hit (seconds of air per 10 m/s)
@export var pin_spin := 14.0                  ## how fast it spins when hit (radians/s at 10 m/s)
@export var dust := true                      ## little dirt puff when knocked over

@export_group("Armor (soldier ants)")
@export var hits_to_knock := 1                ## 1 = worker. 2+ = armored: the last hit knocks it over, the one before that knocks the helmet off,
											  ## and any hits before that just dent the helmet (it wobbles and stays on)
@export var helmet: Node3D                    ## the helmet node inside the model (drag "Helmet" here). Flies off on hit number (hits_to_knock - 1)
@export var armor_stun := 0.5                 ## seconds it staggers after losing its helmet
@export var armor_pushback := 4.0             ## how hard it's shoved back when the helmet comes off (m/s)

@export_group("Cleanup")
@export var despawn_distance: float = 250.0   ## remove if it wanders this far from the middle of the world
## Ants stick to the ground below them (flat field and bowl walls). Layer 3 is the tutorial's "world" layer.
@export_flags_3d_physics var ground_layers: int = 1 << 2
@export var ground_check_every := 3          ## check the ground height every N physics frames (spread across ants)

# Emitted when the mob is defeated (bowled over or jumped on).
signal squashed
signal knocked_down(ant: Node3D)       # knocked over (right away, before it disappears): power-up drops listen for this

enum State { MARCH, CHASE, ATTACK, KNOCKED }
var state := State.MARCH
var knocked := false
var speed := 3.0
var house: Node3D
var player: Node3D
var row_id := -1                      # which row it spawned in (set by Main; used for STRIKE / SPARE)
var row_count := 0                     # how many ants that row started with
var march_dir := Vector3.ZERO          # set by Main: the group marches this way in formation
var knock_roll := -1                   # which roll knocked it over (for the combo)
var _vy := 0.0                         # flying: upward speed
var _hop_y := 0.0                      # flying: height above the ground
var _spin := 0.0                       # flying: spin speed
var _bite_timer := 0.0
var _hits_left := 1
var _stun := 0.0                       # staggered after losing the helmet
var _armor_cooldown := 0.0             # a moment of grace so one roll can't pop the helmet AND knock it over
var _ground_timer := 0
var _ground_y := 0.0


func _ready() -> void:
	_hits_left = maxi(hits_to_knock, 1)
	add_to_group("mob")
	_ground_timer = randi() % maxi(ground_check_every, 1)     # spread the ground checks across frames
	_stick_to_ground()
	if house == null:
		house = get_tree().get_first_node_in_group("house")
	if player == null:
		player = get_tree().get_first_node_in_group("player")


# Called from the Main scene. Ants find the house and the bug by themselves.
func initialize(start_position: Vector3) -> void:
	position = start_position
	speed = randf_range(min_speed, max_speed)
	var to_centre := -Vector3(start_position.x, 0.0, start_position.z)
	if to_centre.length() > 0.1:
		rotation.y = atan2(-to_centre.x, -to_centre.z)     # start out facing into the arena


func _physics_process(delta: float) -> void:
	if state == State.KNOCKED:
		_fly(delta)
		return
	if global_position.y < -20.0 or Vector2(global_position.x, global_position.z).length() > despawn_distance:
		queue_free()
		return
	_armor_cooldown -= delta
	if _stun > 0.0:                                      # staggering after the helmet came off
		_stun -= delta
		velocity = velocity.move_toward(Vector3.ZERO, 12.0 * delta)
		_move(delta)
		return

	_update_state()
	_bite_timer -= delta
	match state:
		State.CHASE:
			var to_bug := _flat(player.global_position - global_position)
			if to_bug.length() <= bite_range:
				velocity = Vector3.ZERO                      # in reach: stop and bite
				_face(player.global_position, delta)
				if _bite_timer <= 0.0 and player.has_method("take_bite") and player.can_be_bitten():
					_bite_timer = attack_interval
					_lunge()
					player.take_bite(1)
			else:
				_walk_to(player.global_position, speed * chase_speed_multiplier, delta)
		State.MARCH:
			if _house_ok():
				if _flat(house.global_position - global_position).length() - house.get_attack_radius() <= attack_reach:
					state = State.ATTACK
					_bite_timer = attack_interval * randf_range(0.3, 1.0)   # stagger the first bites
					velocity = Vector3.ZERO
				elif march_dir != Vector3.ZERO and _flat(house.global_position - global_position).dot(march_dir) > formation_break_distance:
					velocity = march_dir * speed             # in formation: the whole group walks the same way
					_face(global_position + march_dir, delta)
				else:
					_walk_to(house.global_position, speed, delta)
		State.ATTACK:
			velocity = Vector3.ZERO
			if not _house_ok():
				state = State.MARCH
			else:
				_face(house.global_position, delta)
				if _bite_timer <= 0.0:
					_bite_timer = attack_interval
					_lunge()
					house.take_damage(attack_damage)
	_apply_separation()
	_move(delta)


## Ants don't collide with anything (their collision mask is empty), so instead of the full physics
## solver (the most expensive part of the ant before) they just step along their velocity.
## The rolling bug still hits them normally: it's the bug that does the collision check.
func _move(delta: float) -> void:
	global_position += Vector3(velocity.x, 0.0, velocity.z) * delta
	_ground_timer -= 1
	if _ground_timer <= 0:
		_ground_timer = ground_check_every
		_stick_to_ground()
	else:
		global_position.y = lerpf(global_position.y, _ground_y, 0.5)   # glide between ground checks


## Shared spatial grid, rebuilt once per physics frame by whichever ant runs first, so each ant
## only compares itself with ants in the 9 cells around it instead of with every ant on the field.
static var _grid := {}
static var _grid_frame := -1


func _neighbours() -> Array:
	var frame := Engine.get_physics_frames()
	if frame != _grid_frame:
		_grid_frame = frame
		_grid.clear()
		for a in get_tree().get_nodes_in_group("mob"):
			if a.knocked:
				continue
			var key := Vector2i(floori(a.global_position.x / separation_radius), floori(a.global_position.z / separation_radius))
			if _grid.has(key):
				_grid[key].append(a)
			else:
				_grid[key] = [a]
	var out := []
	var cx := floori(global_position.x / separation_radius)
	var cz := floori(global_position.z / separation_radius)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var cell = _grid.get(Vector2i(cx + dx, cz + dz))
			if cell:
				out.append_array(cell)
	return out


## Personal space: steer away from nearby ants so they spread out instead of stacking on one spot.
## Ants biting the house slide around its wall into a ring; ones that drift out of reach march back in.
func _apply_separation() -> void:
	if separation_radius <= 0.0:
		return
	var push := Vector3.ZERO
	for other in _neighbours():
		if other == self or other.knocked:
			continue
		var away := _flat(global_position - other.global_position)
		var d := away.length()
		if d >= separation_radius:
			continue
		if d < 0.01:                                       # exactly on top: pick a random direction
			away = Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1))
			d = 0.01
		push += away.normalized() * (1.0 - d / separation_radius)
	if push == Vector3.ZERO:
		return
	push = push.limit_length(1.0) * speed * separation_strength
	if state == State.ATTACK and _house_ok():
		# keep hugging the house: only slide sideways around it, never away from or into it
		var out := _flat(global_position - house.global_position).normalized()
		push -= out * push.dot(out)
	velocity += push


## Aggro: chase the bug when it comes close; give up once it gets far enough away.
func _update_state() -> void:
	if not chases_player or not _player_ok():
		if state == State.CHASE:
			state = State.MARCH
		return
	var d := _flat(player.global_position - global_position).length()
	if state != State.CHASE and d < aggro_radius:
		state = State.CHASE
	elif state == State.CHASE and d > leash_radius:
		state = State.MARCH                              # back to the house (re-checks if it's in biting range)


func _walk_to(target: Vector3, walk_speed: float, delta: float) -> void:
	var dir := _flat(target - global_position)
	if dir.length() < 0.05:
		velocity = Vector3.ZERO
		return
	dir = dir.normalized()
	velocity = Vector3(dir.x * walk_speed, 0.0, dir.z * walk_speed)
	_face(target, delta)


func _face(target: Vector3, delta: float) -> void:
	var dir := _flat(target - global_position)
	if dir.length() < 0.05:
		return
	var want := atan2(-dir.x, -dir.z)                      # the ant's forward is -Z, like the tutorial's mob
	rotation.y = lerp_angle(rotation.y, want, 1.0 - exp(-turn_speed * delta))


func _lunge() -> void:
	if has_node("Pivot"):                                  # quick lunge forward and back
		var t := create_tween()
		t.tween_property($Pivot, "position:z", -0.35, 0.08)
		t.tween_property($Pivot, "position:z", 0.0, 0.15)


func _house_ok() -> bool:
	return house != null and is_instance_valid(house) and house.is_inside_tree() and house.hp > 0


func _player_ok() -> bool:
	return player != null and is_instance_valid(player) and player.is_inside_tree()


## Puts the ant's feet on the ground right below it, so it never floats or sinks,
## whatever height the arena is at and wherever the ground slopes.
func _stick_to_ground() -> void:
	var from := global_position + Vector3.UP * 8.0
	var query := PhysicsRayQueryParameters3D.create(from, global_position + Vector3.DOWN * 30.0, ground_layers, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		_ground_y = hit.position.y
		global_position.y = _ground_y


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## True while it still has armor left: the next hit only takes armor off instead of knocking it over.
func armor_up() -> bool:
	return not knocked and (_hits_left > 1 or _armor_cooldown > 0.0)


## Called by the rolly polly (or a flying ant) when it hits this ant.
## from_pos = where the hitter was, so the ant flies off away from it like a bowling pin.
## smash = ignore armor (a grown rolly polly): a soldier loses its helmet AND goes over in one hit.
func knock_over(hit_velocity: Vector3, from_pos = null, smash := false) -> void:
	if knocked:
		return
	if smash and _hits_left > 1:
		_hits_left = 1
		if helmet and is_instance_valid(helmet):
			if has_node("HelmetSound"):
				$HelmetSound.play()
			_fling_helmet(_away_from(hit_velocity, from_pos))
	elif _armor_cooldown > 0.0:
		return
	elif _hits_left > 1:
		_lose_armor(hit_velocity, from_pos)
		return
	knocked = true
	state = State.KNOCKED
	knocked_down.emit(self)
	if has_node("HitSound"):
		$HitSound.play()
	collision_layer = 0          # nothing can hit it again
	collision_mask = 0
	var hv := _flat(hit_velocity)
	var spd := hv.length() * knock_speed
	var dir := hv.normalized() if hv.length() > 0.01 else -global_transform.basis.z
	if from_pos is Vector3:
		var away := _flat(global_position - from_pos)
		if away.length() > 0.01:
			dir = dir.lerp(away.normalized(), knock_deflect).normalized()
	dir = dir.rotated(Vector3.UP, randf_range(-0.15, 0.15))      # a little chaos, like real pins
	velocity = dir * spd
	_vy = 9.81 * pin_hop * clampf(spd / 10.0, 0.3, 1.5) + 2.0     # pop up off the ground
	_hop_y = 0.0
	_spin = pin_spin * clampf(spd / 10.0, 0.3, 1.5) * (1.0 if randf() < 0.5 else -1.0)
	# flip onto its back
	if has_node("Pivot"):
		var t := create_tween().set_parallel(true)
		t.tween_property($Pivot, "rotation:z", PI, 0.3).set_trans(Tween.TRANS_BACK)
		t.tween_property($Pivot, "position:y", $Pivot.position.y + flip_lift, 0.3)
	if dust:
		_dust_puff()
	get_tree().create_timer(knocked_time).timeout.connect(squash)


## Flying / sliding on its back: hops, spins, slides to a stop, and bowls over any ants in its way.
func _fly(delta: float) -> void:
	velocity = velocity.move_toward(Vector3.ZERO, pin_slide_friction * delta)
	global_position += velocity * delta
	_spin = move_toward(_spin, 0.0, 20.0 * delta)
	rotation.y += _spin * delta
	_vy -= 30.0 * delta
	_hop_y += _vy * delta
	if _hop_y <= 0.0:                         # land, with a small bounce
		_hop_y = 0.0
		_vy = -_vy * 0.3 if _vy < -3.0 else 0.0
	if velocity.length() > 0.5 or _hop_y > 0.0:
		_stick_to_ground()                    # every frame while moving, it's only a handful of ants
	global_position.y = _ground_y + _hop_y
	if velocity.length() >= pin_min_speed:
		_hit_pins()


func _hit_pins() -> void:
	for other in _neighbours():
		if other == self or other.knocked:
			continue
		var d := _flat(other.global_position - global_position)
		if d.length() > pin_hit_radius:
			continue
		if other.armor_up():                  # a soldier: the flying ant only pops its helmet and stops dead
			other.knock_over(velocity, global_position)
			velocity *= 0.2
			continue
		other.knock_roll = knock_roll
		get_tree().call_group("combo", "on_chain_knock", other)   # count it before it plays its sound
		other.knock_over(velocity * pin_transfer / other.knock_speed, global_position)
		velocity *= 0.75                      # loses some speed to each ant it hits


## An armor hit on a soldier: the ant staggers back, still standing. On hit number (hits_to_knock - 1)
## the helmet flies off spinning; any earlier armor hits just knock the helmet askew for a moment.
func _lose_armor(hit_velocity: Vector3, from_pos) -> void:
	_hits_left -= 1
	var helmet_off := _hits_left == 1          # the next hit will knock it over
	_armor_cooldown = 0.35
	_stun = armor_stun
	var away := _away_from(hit_velocity, from_pos)
	velocity = away * armor_pushback
	if state == State.ATTACK:
		state = State.MARCH
	if has_node("HelmetSound"):
		$HelmetSound.play()
	elif has_node("HitSound"):
		$HitSound.play()
	if has_node("Pivot"):                                 # squash-and-stretch flinch
		var p: Node3D = $Pivot
		var base := p.scale
		p.scale = base * Vector3(1.25, 0.75, 1.25)
		create_tween().tween_property(p, "scale", base, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if dust:
		_dust_puff()
	if helmet == null or not is_instance_valid(helmet):
		return
	if not helmet_off:
		_dent_helmet()
		return
	_fling_helmet(away)


## Which way a hit pushes this ant: half the hitter's direction, half straight away from the hitter.
func _away_from(hit_velocity: Vector3, from_pos) -> Vector3:
	var away := _flat(hit_velocity).normalized()
	if from_pos is Vector3 and _flat(global_position - from_pos).length() > 0.01:
		away = away.lerp(_flat(global_position - from_pos).normalized(), 0.5).normalized()
	return away


## Detaches the helmet into the world and sends it spinning through the air onto the grass.
func _fling_helmet(away: Vector3) -> void:
	var h := helmet
	helmet = null
	var xf := h.global_transform
	h.get_parent().remove_child(h)
	get_parent().add_child(h)
	h.global_transform = xf
	var start := h.global_position
	var land := start + (away * 2.5 + Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8)))
	land.y = _ground_y + 0.1
	var air := 0.55
	var t := h.create_tween().set_parallel(true)
	t.tween_method(func(k: float): h.global_position = start.lerp(land, k) + Vector3.UP * sin(k * PI) * 2.0, 0.0, 1.0, air)
	t.tween_property(h, "rotation", h.rotation + Vector3(randf_range(6, 10), randf_range(-4, 4), randf_range(-3, 3)), air)
	t.chain().tween_interval(0.8)                         # lies on the grass for a moment
	t.chain().tween_property(h, "scale", Vector3.ZERO, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(h.queue_free)


## Helmet takes a hit but stays on: it gets knocked askew and wobbles back into place.
func _dent_helmet() -> void:
	var h := helmet
	var rest := h.rotation
	var base_scale := h.scale
	h.rotation = rest + Vector3(randf_range(-0.6, 0.6), randf_range(-0.4, 0.4), randf_range(-0.6, 0.6))
	h.scale = base_scale * 1.2
	var t := h.create_tween().set_parallel(true)
	t.tween_property(h, "rotation", rest, 0.45).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	t.tween_property(h, "scale", base_scale, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static var _dust_mesh: Mesh
static var _dust_mat: StandardMaterial3D


func _dust_puff() -> void:
	if _dust_mesh == null:
		var box := BoxMesh.new()
		box.size = Vector3.ONE * 0.16
		_dust_mesh = box
		_dust_mat = StandardMaterial3D.new()
		_dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_dust_mat.vertex_color_use_as_albedo = true
		_dust_mat.albedo_color = Color(0.62, 0.5, 0.33)
	var p := CPUParticles3D.new()
	p.mesh = _dust_mesh
	p.material_override = _dust_mat
	p.amount = 10
	p.lifetime = 0.5
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 4.5
	p.gravity = Vector3(0, -12, 0)
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.3
	var fade := Curve.new()
	fade.add_point(Vector2(0, 1))
	fade.add_point(Vector2(1, 0))
	p.scale_amount_curve = fade
	get_parent().add_child(p)
	p.global_position = global_position + Vector3.UP * 0.3
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)


func squash() -> void:
	if not is_inside_tree():
		return
	squashed.emit()
	queue_free()
