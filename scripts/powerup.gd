extends Node3D
## A power-up drop: the item floats and spins inside a dew-drop bubble over a glowing ring on the grass.
## Roll the rolly polly through it to pick it up. It starts blinking near the end of its life, then pops.
##
## Scene setup (powerup_size.tscn):
##   SizeUp (Node3D, this script)      <- Kind = "size_up"
##   └── Item                          <- blueberry.glb (any model; it's what floats in the bubble)
## The bubble and the ring are made by this script, so every power-up looks like part of the same family:
## for a new kind, duplicate the scene, swap the Item model and change Kind.

signal collected(kind: String)

@export var kind := "size_up"                    ## what the player gets (player.gd's apply_powerup decides what that means)
@export var icon_color := Color(0.5, 0.38, 1.0)  ## colour of the bubble tint, glow ring and off-screen icon
@export var lifetime := 12.0                     ## seconds before it pops by itself
@export var blink_time := 4.0                    ## blinks for this long before it disappears
@export var pickup_radius := 1.8                 ## how close the bug's centre must get (grows with a big bug)
@export var float_height := 1.6                  ## how high the bubble floats over the grass
@export var bubble_radius := 1.15
@export var item_scale := 1.7                    ## size of the item inside the bubble
@export var beam := true                         ## a soft column of light above it, so you spot it from across the arena
@export var spawn_grace := 1.0                   ## can't be picked up for this long after it appears, so you can see what it is
@export var leave_to_arm := true                 ## also can't be picked up until the bug has been outside it once
                                                 ## (a drop that lands right under the bug isn't grabbed by accident)
@export var pickup_sound: AudioStream            ## optional: plays when it's collected

var time_left := 0.0
var _t := 0.0
var _bubble: MeshInstance3D
var _ring: MeshInstance3D
var _item: Node3D
var _bubble_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D
var _beam: MeshInstance3D
var _beam_mat: StandardMaterial3D
var _player: Node3D
var _done := false
var _armed := false              # can be picked up yet?
var _grace := 0.0
var prewarm_only := false        # set by the spawner: just drawn once while loading, no gameplay


func _ready() -> void:
	if prewarm_only:
		_item = get_node_or_null("Item")
		_build_visuals()
		set_process(false)
		return
	add_to_group("powerup")
	time_left = lifetime
	_grace = spawn_grace
	_t = randf() * 10.0
	_item = get_node_or_null("Item")
	_build_visuals()
	# appear: pop up out of the grass
	scale = Vector3.ONE * 0.01
	create_tween().tween_property(self, "scale", Vector3.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _build_visuals() -> void:
	# glow ring flat on the grass, so you can see where it is even from straight above
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = bubble_radius * 0.95
	torus.outer_radius = bubble_radius * 1.3
	torus.rings = 24
	torus.ring_segments = 6
	_ring.mesh = torus
	_ring.scale = Vector3(1.0, 0.08, 1.0)
	_ring.position.y = 0.05
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(icon_color, 0.6)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	# the bubble: faceted, faintly tinted, see-through, with a bright highlight
	_bubble = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = bubble_radius
	sphere.height = bubble_radius * 2.0
	sphere.radial_segments = 14
	sphere.rings = 7
	_bubble.mesh = sphere
	_bubble_mat = StandardMaterial3D.new()
	# Unshaded on purpose: a lit (shaded) see-through material made the renderer stall for most of a
	# second every time the first one appeared on screen. The white glint below sells the "bubble" instead.
	_bubble_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bubble_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bubble_mat.albedo_color = Color(icon_color.lerp(Color.WHITE, 0.75), 0.14)   # barely tinted: the berry inside stays bold
	_bubble_mat.cull_mode = BaseMaterial3D.CULL_DISABLED      # see the back of the bubble through the front
	_bubble.material_override = _bubble_mat
	_bubble.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bubble.position.y = float_height
	add_child(_bubble)
	var shine := MeshInstance3D.new()                        # the little white glint that makes it read as a bubble
	var dot := SphereMesh.new()
	dot.radius = bubble_radius * 0.16
	dot.height = bubble_radius * 0.2
	dot.radial_segments = 8
	dot.rings = 4
	shine.mesh = dot
	var shine_mat := StandardMaterial3D.new()
	shine_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shine_mat.albedo_color = Color(1, 1, 1)
	shine.material_override = shine_mat
	shine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shine.position = Vector3(-0.38, 0.42, 0.38) * bubble_radius
	_bubble.add_child(shine)
	if _item:
		_item.reparent(_bubble, false)
		_item.position = Vector3.ZERO
		_item.scale = Vector3.ONE * item_scale
	if beam:
		_beam = MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = bubble_radius * 0.2
		cyl.bottom_radius = bubble_radius * 0.6
		cyl.height = 6.0
		cyl.radial_segments = 10
		cyl.rings = 1
		cyl.cap_top = false
		cyl.cap_bottom = false
		_beam.mesh = cyl
		_beam_mat = StandardMaterial3D.new()
		_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_beam_mat.albedo_color = Color(icon_color.lerp(Color.WHITE, 0.4), 0.18)
		_beam.material_override = _beam_mat
		_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_beam.position.y = float_height + bubble_radius + 3.0   # starts above the bubble, so it doesn't wash out the berry
		add_child(_beam)


func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	time_left -= delta
	# bob, spin, ring pulse
	_bubble.position.y = float_height + sin(_t * 2.2) * 0.12
	if _item:
		_item.rotation.y += delta * 1.6
		_item.rotation.z = sin(_t * 1.7) * 0.15
	var pulse := 0.5 + 0.5 * sin(_t * 4.0)
	_ring.scale = Vector3(1.0 + pulse * 0.12, 0.08, 1.0 + pulse * 0.12)
	_ring_mat.albedo_color.a = (0.35 + 0.35 * pulse) * (1.0 if _armed else 0.35)   # dim until it can be picked up
	if _beam_mat:
		_beam_mat.albedo_color.a = 0.10 + 0.10 * pulse
	# about to vanish: blink faster and faster
	if time_left < blink_time:
		var rate := lerpf(4.0, 14.0, 1.0 - time_left / blink_time)
		visible = fmod(_t * rate, 1.0) > 0.3
	if time_left <= 0.0:
		_vanish()
		return
	_check_pickup()


func _check_pickup() -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	var size: float = _player.get("size_mult") if _player.get("size_mult") != null else 1.0
	var bug := _player.global_position + Vector3.UP * 0.5 * size
	var d := Vector2(bug.x - global_position.x, bug.z - global_position.z).length()
	var touching := d <= pickup_radius * size and bug.y < global_position.y + float_height + bubble_radius + 1.0
	if not _armed:
		_grace -= get_process_delta_time()
		if _grace <= 0.0 and not (leave_to_arm and touching):
			_arm()
		return
	if touching:
		_collect()


## Ready to be picked up: the ring flashes bright once so the player sees it "switch on".
func _arm() -> void:
	_armed = true
	var t := create_tween()
	t.tween_property(_ring, "scale", Vector3(1.5, 0.08, 1.5), 0.12)
	t.tween_property(_ring, "scale", Vector3(1.0, 0.08, 1.0), 0.2)


func _collect() -> void:
	_done = true
	visible = true
	collected.emit(kind)
	if _player.has_method("apply_powerup"):
		_player.apply_powerup(kind, icon_color)
	if pickup_sound:
		var s := AudioStreamPlayer.new()
		s.stream = pickup_sound
		get_parent().add_child(s)
		s.play()
		s.finished.connect(s.queue_free)
	_burst()
	# pop: the bubble swells and vanishes, the berry zips into the bug
	var t := create_tween().set_parallel(true)
	t.tween_property(_bubble, "scale", Vector3.ONE * 1.6, 0.12)
	t.tween_property(_bubble_mat, "albedo_color:a", 0.0, 0.12)
	t.tween_property(_ring, "scale", Vector3(2.2, 0.08, 2.2), 0.25)
	t.tween_property(_ring_mat, "albedo_color:a", 0.0, 0.25)
	if _beam_mat:
		t.tween_property(_beam_mat, "albedo_color:a", 0.0, 0.2)
	if _item:
		t.tween_property(_item, "scale", Vector3.ZERO, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(queue_free)


## Little droplets spraying out when the bubble pops.
func _burst() -> void:
	var p := CPUParticles3D.new()
	var drop := SphereMesh.new()
	drop.radius = 0.08
	drop.height = 0.16
	drop.radial_segments = 6
	drop.rings = 3
	p.mesh = drop
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = icon_color.lerp(Color.WHITE, 0.5)
	p.material_override = m
	p.amount = 16
	p.lifetime = 0.5
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 6.0
	p.gravity = Vector3(0, -14, 0)
	var fade := Curve.new()
	fade.add_point(Vector2(0, 1))
	fade.add_point(Vector2(1, 0))
	p.scale_amount_curve = fade
	get_parent().add_child(p)
	p.global_position = _bubble.global_position
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)


## Ran out of time: shrinks into the grass.
func _vanish() -> void:
	_done = true
	visible = true
	var t := create_tween()
	t.tween_property(self, "scale", Vector3.ONE * 0.01, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.tween_callback(queue_free)
