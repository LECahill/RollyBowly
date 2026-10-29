extends CanvasLayer
## Performance overlay that also works in the web export. Press F3 to show / hide.
## Add it to Main: right-click Main > Add Child Node > CanvasLayer, attach this script.
## (Or Project Settings > Globals > Autoload, add this script, so it's in every scene.)

@export var start_visible := true

var _label: Label
var _frame_ms: Array[float] = []
var _worst_ms := 0.0
var _timer := 0.0


func _ready() -> void:
	layer = 100
	_label = Label.new()
	_label.position = Vector2(8, 40)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(1, 1, 0.6))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	visible = start_visible


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible


func _process(delta: float) -> void:
	_frame_ms.append(delta * 1000.0)
	_timer += delta
	if _timer < 0.5:
		return
	_timer = 0.0
	_worst_ms = 0.0
	for ms in _frame_ms:
		_worst_ms = maxf(_worst_ms, ms)
	_frame_ms.clear()
	if not visible:
		return
	var ants := get_tree().get_nodes_in_group("mob").size()
	_label.text = "\n".join([
		"FPS %d   worst frame %.0f ms" % [Engine.get_frames_per_second(), _worst_ms],
		"process step %.1f ms   physics step %.1f ms" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0],
		"draw calls %d   objects %d   ants %d" % [
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), ants],
		"3D scale %.2f   window %s" % [get_viewport().scaling_3d_scale, str(get_viewport().get_visible_rect().size)],
		"GPU: %s" % RenderingServer.get_video_adapter_name(),
		"renderer: %s   physics ticks %d/s   interpolation %s" % [
			RenderingServer.get_current_rendering_method(), Engine.physics_ticks_per_second,
			"on" if get_tree().physics_interpolation else "off"],
	])
