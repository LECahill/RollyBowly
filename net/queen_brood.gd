extends Node
## Rides on a queen ant (main.gd's _make_queen adds it). Every few seconds the queen pulses and lays
## an egg next to her, and a worker ant hatches out of it. She stops when she's bowled over (or after
## max_brood eggs), so the answer to a queen is to go and get her.

var main: Node                 # main.gd: spawn_mob_at() makes the ants
var every := 5.0
var max_brood := 6
var _left := 0.0
var _laid := 0
var _queen: Node3D


func _ready() -> void:
	_queen = get_parent() as Node3D
	_left = every * 0.6                                    # the first egg comes a little sooner


func _physics_process(delta: float) -> void:
	if _queen == null or main == null or not is_instance_valid(main):
		return
	if _queen.get("knocked") == true or _laid >= max_brood or main.get("game_over") == true:
		set_physics_process(false)
		return
	_left -= delta
	if _left > 0.0:
		return
	_left = every
	_laid += 1
	var back := _queen.global_transform.basis.z.normalized()    # behind her (ants face -Z)
	var side := Vector3(back.z, 0.0, -back.x) * randf_range(-1.0, 1.0)
	var spot := _queen.global_position + back * 1.8 + side
	spot.y = _queen.global_position.y
	var ant: Node3D = main.spawn_mob_at(spot)
	if ant:
		ant.rotation.y = _queen.rotation.y
		var body := ant.get_node_or_null("Pivot") as Node3D   # hatch: the model grows in from tiny
		if body:
			var full := body.scale
			body.scale = full * 0.2
			ant.create_tween().tween_property(body, "scale", full, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var pivot := _queen.get_node_or_null("Pivot") as Node3D
	if pivot:                                              # a little heave as she lays
		var base := pivot.scale
		var t := _queen.create_tween()
		t.tween_property(pivot, "scale", base * Vector3(1.12, 0.88, 1.12), 0.12)
		t.tween_property(pivot, "scale", base, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
