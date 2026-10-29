extends Node
## Makes the mushroom house (and anything else you choose) see-through while it blocks the camera's
## view of the rolly polly or of ants attacking it, so you never lose track of anything behind it.
##
## Setup: right-click Main > Add Child Node > Node, name it "OcclusionFader", attach this script.
## It finds the house by itself. To fade other big props too (rocks, flower pots...), add them to the
## group "fade_occluder" (Node panel > Groups) or drag them into Occluders below.
## Works in the browser too: it fades the materials' own alpha, not GeometryInstance3D.transparency
## (which the web renderer ignores).

@export var occluders: Array[Node3D] = []      ## extra things to fade. The house and the "fade_occluder" group are added automatically
@export_range(0.0, 1.0) var faded_alpha := 0.3 ## how solid a faded object stays (0 = invisible)
@export var fade_speed := 8.0                  ## how quickly it fades out / back in
@export var check_ants := true                 ## also fade when ants are hidden behind it (off = only for the rolly polly)
@export var ant_check_radius := 14.0           ## only ants this close to the occluder count (ants far behind it don't fade it)
@export var hold_time := 0.5                   ## stay faded this long after the last hidden thing comes out, so it doesn't flicker
@export var target_height := 0.4               ## look at this point above each target's feet
@export var prewarm := true                    ## draw the see-through version once at startup, hidden, so the browser
                                               ## compiles its shader then instead of freezing the first time it fades
@export_range(0.5, 1.0) var footprint := 0.85  ## shrink the occluder's box sideways a little so its empty corners don't trigger the fade

var _items := []                               # one per occluder: {node, surfaces: [{mesh, index, original, faded}], alpha, faded}


func _ready() -> void:
	_collect.call_deferred()


func _collect() -> void:
	var list: Array[Node3D] = occluders.duplicate()
	for n in get_tree().get_nodes_in_group("house"):
		if n is Node3D and not list.has(n):
			list.append(n)
	for n in get_tree().get_nodes_in_group("fade_occluder"):
		if n is Node3D and not list.has(n):
			list.append(n)
	for node in list:
		var surfaces := []
		var meshes: Array = node.find_children("*", "MeshInstance3D", true, false)
		if node is MeshInstance3D:
			meshes.append(node)
		for mi: MeshInstance3D in meshes:
			if mi.mesh == null:
				continue
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i)
				if not (mat is BaseMaterial3D):
					continue                            # custom shaders are left alone
				var faded: BaseMaterial3D = mat.duplicate()
				faded.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				faded.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS   # keeps its own parts sorted properly
				surfaces.append({"mesh": mi, "index": i, "original": mi.get_surface_override_material(i),
						"faded": faded, "base_alpha": mat.albedo_color.a})
		if surfaces.size() > 0:
			_items.append({"node": node, "surfaces": surfaces, "alpha": 1.0, "faded": false, "hold": 0.0})
	if prewarm:
		_prewarm()


## The first time a material is drawn see-through, the browser has to compile a new shader for it,
## which can freeze the game for a moment (seconds on some machines). So right at the start we draw
## a tiny copy of every faded surface just in front of the camera for a few frames, where nobody can
## see it, and the compiling happens during loading instead of mid-game.
func _prewarm() -> void:
	var cam := get_viewport().get_camera_3d()
	for i in 10:
		if cam:
			break
		await get_tree().process_frame
		cam = get_viewport().get_camera_3d()
	if cam == null:
		return
	var holder := Node3D.new()
	cam.add_child(holder)
	holder.position = Vector3(0.0, 0.0, -(cam.near + 0.3))
	holder.scale = Vector3.ONE * 0.0005                 # far too small to see
	var done := {}
	for item in _items:
		for s in item.surfaces:
			var mi: MeshInstance3D = s.mesh
			if done.has(mi):
				continue
			done[mi] = true
			var copy := MeshInstance3D.new()
			copy.mesh = mi.mesh
			copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			copy.extra_cull_margin = 16384.0               # never culled away before it's drawn
			holder.add_child(copy)
			for s2 in item.surfaces:
				if s2.mesh == mi:
					s2.faded.albedo_color.a = 0.5
					copy.set_surface_override_material(s2.index, s2.faded)
	for i in 3:
		await get_tree().process_frame
	holder.queue_free()


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _items.is_empty():
		return
	var players := get_tree().get_nodes_in_group("player")
	var ants: Array = []
	if check_ants:
		for a in get_tree().get_nodes_in_group("mob"):
			if a is Node3D and not a.get("knocked"):
				ants.append(a)
	var eye := cam.global_position
	for item in _items:
		var node: Node3D = item.node
		if not is_instance_valid(node):
			continue
		var box := _box(item, footprint)
		var full_box := _box(item, 1.0)                 # ants: even half-hidden at the edge counts
		var centre := full_box.get_center()
		var blocking := false
		for t in players:
			if t is Node3D and box.intersects_segment(eye, t.global_position + Vector3.UP * target_height):
				blocking = true
				break
		if not blocking:
			for a: Node3D in ants:
				var flat := Vector2(a.global_position.x - centre.x, a.global_position.z - centre.z)
				if flat.length() > ant_check_radius:
					continue                            # far away behind it: the arrows cover those
				if full_box.intersects_segment(eye, a.global_position + Vector3.UP * target_height):
					blocking = true
					break
		if blocking:
			item.hold = hold_time
		else:
			item.hold = maxf(item.hold - delta, 0.0)
		var want := faded_alpha if item.hold > 0.0 else 1.0
		item.alpha = move_toward(item.alpha, want, fade_speed * delta)
		_apply(item)


## The occluder's bounding box in the world, a bit narrower than its widest point.
func _box(item, keep := 1.0) -> AABB:
	var box := AABB()
	var first := true
	for s in item.surfaces:
		var mi: MeshInstance3D = s.mesh
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var shrink := box.size * (1.0 - keep) * 0.5
	shrink.y = 0.0
	return AABB(box.position + shrink, box.size - shrink * 2.0)


func _apply(item) -> void:
	var see_through: bool = item.alpha < 0.999
	if see_through != item.faded:                     # swap materials only when switching
		item.faded = see_through
		for s in item.surfaces:
			s.mesh.set_surface_override_material(s.index, s.faded if see_through else s.original)
	if see_through:
		for s in item.surfaces:
			s.faded.albedo_color.a = s.base_alpha * item.alpha
