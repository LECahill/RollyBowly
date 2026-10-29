extends Node
## Cheaper shadows in the browser build only (the desktop/editor keeps full quality).
## Setup: right-click Main > Add Child Node > Node, name it "WebQuality", attach this script.
## (Or Project Settings > Globals > Autoload, add this script, so it applies to every scene.)
##
## In the browser almost all of the frame time goes on drawing, and the sun's shadows are the
## biggest part: by default they're drawn 4 times (4 cascades) into a 4096 × 4096 map, and every
## ant is drawn again into each of them. Measured in a browser test: about 1.8× faster with all
## of the options below on.

@export var only_in_browser := true          ## off = apply on desktop too
@export var single_shadow_cascade := true    ## draw the sun's shadow once instead of 4 times
@export var shadow_distance := 45.0          ## shadows only this far from the camera (0 = leave as is)
@export_enum("1024:1024", "2048:2048", "4096:4096") var shadow_map_size := 2048
@export var ants_cast_shadows := false       ## ant shadows cost the most for the least; off = ants have no shadow
@export var scale_3d := 0.0                  ## 3D render resolution (e.g. 0.75). 0 = leave as is
## Sharp, high-resolution screens (an iPad is 2360 x 1640 real pixels, an iPad Pro even more) make the
## browser draw far more 3D pixels than a laptop. Above this many, the 3D is drawn at a lower resolution
## and scaled up (the UI stays sharp). 0 = never. 2.5 million is about a 1080p laptop's worth.
@export var max_3d_pixels := 2500000

func _ready() -> void:
	if only_in_browser and not OS.has_feature("web"):
		return
	RenderingServer.directional_shadow_atlas_set_size(shadow_map_size, true)
	for sun in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		if single_shadow_cascade:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		if shadow_distance > 0.0:
			sun.directional_shadow_max_distance = shadow_distance
	if scale_3d > 0.0:
		get_viewport().scaling_3d_scale = scale_3d
	elif max_3d_pixels > 0:
		_fit_3d_resolution()
		get_viewport().size_changed.connect(_fit_3d_resolution)
	if not ants_cast_shadows:
		get_tree().node_added.connect(_on_node_added)
		for ant in get_tree().get_nodes_in_group("mob"):
			_no_shadow(ant)
	print("WebQuality: browser shadow settings applied")


func _fit_3d_resolution() -> void:
	var s := get_viewport().get_visible_rect().size
	var pixels := s.x * s.y
	var k := 1.0 if pixels <= max_3d_pixels else sqrt(max_3d_pixels / pixels)
	get_viewport().scaling_3d_scale = clampf(k, 0.5, 1.0)


func _on_node_added(node: Node) -> void:
	if node.is_in_group("mob") or node is CharacterBody3D and node.get_script() and node.has_method("knock_over"):
		_no_shadow.call_deferred(node)


func _no_shadow(ant: Node) -> void:
	if not is_instance_valid(ant):
		return
	for g in ant.find_children("*", "GeometryInstance3D", true, false):
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
