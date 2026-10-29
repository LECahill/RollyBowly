extends Node
## Drops power-ups during live play, like Zombies power-ups: a knocked-over ant sometimes leaves one
## behind where it fell, and a STRIKE can drop one too. Roll through it to grab it, or ignore it.
## It's only there for a while, so going for it is a quick risk-or-not decision.
##
## Setup: right-click Main > Add Child Node > Node, name it "PowerupSpawner", attach this script,
## and drag your power-up scene(s) (e.g. powerup_size.tscn) into Powerup Scenes.

@export var powerup_scenes: Array[PackedScene] = []  ## one is picked at random for each drop
@export_range(0.0, 1.0) var drop_chance := 0.06      ## chance that a knocked-over ant drops one
@export_range(0.0, 1.0) var strike_drop_chance := 0.5  ## chance that a STRIKE drops one (where the last pin fell)
@export var from_wave := 2                           ## no drops before this wave
@export var max_on_field := 2                        ## never more than this many waiting at once
@export var cooldown := 8.0                          ## at least this many seconds between drops
@export var arena_fraction := 0.85                   ## keep drops inside this fraction of the arena (not up the bowl wall)
@export var prewarm := true                          ## draw each drop once, hidden, while the game loads (see _prewarm)

var _cooldown_left := 0.0


func _ready() -> void:
	add_to_group("powerup_spawner")
	get_tree().node_added.connect(_on_node_added)
	_hook_combo.call_deferred()
	if prewarm:
		_prewarm.call_deferred()


func _hook_combo() -> void:
	var combo := get_tree().get_first_node_in_group("combo")
	if combo and combo.has_signal("strike_scored"):
		combo.strike_scored.connect(_on_strike)


func _on_node_added(node: Node) -> void:
	if node.has_signal("knocked_down") and not node.knocked_down.is_connected(_on_ant_down):
		node.knocked_down.connect(_on_ant_down)


func _process(delta: float) -> void:
	_cooldown_left -= delta


func _on_ant_down(ant: Node3D) -> void:
	if randf() < drop_chance:
		_drop(ant.global_position)


func _on_strike(pos: Vector3) -> void:
	if randf() < strike_drop_chance:
		_drop(pos)


func _drop(pos: Vector3) -> void:
	if powerup_scenes.is_empty() or _cooldown_left > 0.0:
		return
	var main := get_parent()
	if main and main.get("wave") != null and main.wave < from_wave:
		return
	if get_tree().get_nodes_in_group("powerup").size() >= max_on_field:
		return
	_cooldown_left = cooldown
	var player := get_tree().get_first_node_in_group("player")
	if player and player.get("_arena_known"):
		var c: Vector3 = player.arena_center
		var flat := Vector2(pos.x - c.x, pos.z - c.z).limit_length(player.arena_radius * arena_fraction)
		pos = Vector3(c.x + flat.x, pos.y, c.z + flat.y)
	var drop: Node3D = powerup_scenes.pick_random().instantiate()
	main.add_child(drop)
	drop.global_position = _ground(pos)


func _ground(pos: Vector3) -> Vector3:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 10.0, pos + Vector3.DOWN * 30.0, 1 << 2)
	var hit := space.intersect_ray(q)
	return hit.position if hit else pos


## The first time a drop appears, the graphics card has to prepare (compile) the shaders for its
## bubble, glowing ring, light beam, berry and pop droplets, which froze the game for a moment.
## So right at the start, one copy of every drop is drawn for a few frames hidden under the ground
## in the middle of the view (the ground covers it, but it still gets prepared), then removed.
func _prewarm() -> void:
	var cam := get_viewport().get_camera_3d()
	for i in 10:
		if cam:
			break
		await get_tree().process_frame
		cam = get_viewport().get_camera_3d()
	if cam == null or powerup_scenes.is_empty():
		return
	var holder := Node3D.new()
	holder.name = "PowerupPrewarm"
	get_tree().root.add_child(holder)
	var ahead := cam.global_position - cam.global_transform.basis.z * 20.0
	holder.global_position = Vector3(ahead.x, -12.0, ahead.z)   # deep enough that even the light beam stays underground
	var x := 0.0
	for scene in powerup_scenes:
		var pu: Node3D = scene.instantiate()
		pu.set("prewarm_only", true)
		holder.add_child(pu)
		pu.position = Vector3(x, 0, 0)
		if pu.has_method("_burst"):
			pu._burst()                                  # the pop droplets too
		x += 3.0
	for i in 4:
		await get_tree().process_frame
	holder.queue_free()
