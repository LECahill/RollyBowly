extends Node3D
## The mushroom house the rolly polly defends. Ants bite it; when its health hits 0 the game ends.
## Attach to the root node of your mushroom house scene. It finds itself for the ants automatically.

signal health_changed(hp: int, max_hp: int)
signal destroyed

@export var max_hp := 100
@export var radius := 1.3                     ## stem radius at scale 1: ants stand this far (× scale) from the centre to bite
@export var health_bar: Range                 ## optional: a ProgressBar (or any Range) to show the health

var hp := 0
var _wobble: Tween
var _base_scale := Vector3.ONE


func _ready() -> void:
	add_to_group("house")
	hp = max_hp
	_base_scale = scale
	_update_bar()


## How far from the house's centre an ant can bite from (follows the house's scale).
func get_attack_radius() -> float:
	return radius * global_transform.basis.get_scale().x


func take_damage(amount: int) -> void:
	if hp <= 0:
		return
	hp = maxi(hp - amount, 0)
	health_changed.emit(hp, max_hp)
	_update_bar()
	# little squash so you can see it getting bitten
	if _wobble:
		_wobble.kill()
	scale = _base_scale * Vector3(1.04, 0.95, 1.04)
	_wobble = create_tween()
	_wobble.tween_property(self, "scale", _base_scale, 0.2).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	if hp == 0:
		destroyed.emit()


func heal(amount: int) -> void:
	if hp <= 0:
		return
	hp = mini(hp + amount, max_hp)
	health_changed.emit(hp, max_hp)
	_update_bar()


func _update_bar() -> void:
	if health_bar:
		health_bar.max_value = max_hp
		health_bar.value = hp
