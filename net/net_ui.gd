class_name NetUI
extends RefCounted
## Small UI kit for the online screens, in the same look as the rest of Rolly Bowly
## (Fredoka font, the UI pack's green / red / blue buttons, cream paper with a brown edge).
## Everything is built in code, like game_ui.gd and title_screen.gd.

const BROWN := Color(0.43, 0.19, 0.16)
const CREAM := Color(1.0, 0.98, 0.9)
const PAPER := Color(0.99, 0.93, 0.8)
const EDGE := Color(0.87, 0.6, 0.47)
const INK := Color(0.36, 0.2, 0.15)
const GRASS := Color(0.33, 0.55, 0.27)
const UI := "res://ui/"

static var _font: Font
static var _themes := {}                  # font size -> Theme


static func font() -> Font:
	if _font == null:
		var f = load(UI + "Fredoka-SemiBold.ttf")
		_font = f if f is Font else ThemeDB.fallback_font
	return _font


## A theme so LineEdits, RichTextLabels and plain Buttons use the game's font.
static func theme(size := 24) -> Theme:
	if not _themes.has(size):
		var _theme := Theme.new()
		_themes[size] = _theme
		_theme.default_font = font()
		_theme.default_font_size = size
		var field := StyleBoxFlat.new()
		field.bg_color = Color(1, 1, 1, 0.9)
		field.border_color = EDGE
		field.set_border_width_all(3)
		field.set_corner_radius_all(10)
		field.content_margin_left = 12
		field.content_margin_right = 12
		field.content_margin_top = 6
		field.content_margin_bottom = 6
		_theme.set_stylebox("normal", "LineEdit", field)
		var focus := field.duplicate() as StyleBoxFlat
		focus.border_color = BROWN
		_theme.set_stylebox("focus", "LineEdit", focus)
		_theme.set_color("font_color", "LineEdit", INK)
		_theme.set_color("font_placeholder_color", "LineEdit", Color(INK, 0.45))
		_theme.set_color("caret_color", "LineEdit", BROWN)
		_theme.set_color("default_color", "RichTextLabel", INK)
	return _themes[size]


static func tex(name: String) -> Texture2D:
	var path := UI + name + ".png"
	return load(path) if ResourceLoader.exists(path) else null


static func label(text: String, size: float, color := INK, outline := 0.0, outline_color := BROWN) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font = font()
	ls.font_size = maxi(int(size), 8)
	ls.font_color = color
	if outline > 0.0:
		ls.outline_size = int(outline)
		ls.outline_color = outline_color
	l.label_settings = ls
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Cream paper panel with a soft brown edge.
static func paper(bg := PAPER, alpha := 1.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(bg, alpha)
	s.border_color = Color(EDGE, maxf(alpha, 0.6))
	s.set_border_width_all(6)
	s.set_corner_radius_all(18)
	s.shadow_color = Color(0, 0, 0, 0.25 * alpha)
	s.shadow_size = 8
	s.shadow_offset = Vector2(0, 4)
	s.set_content_margin_all(16)
	return s


static func panel(bg := PAPER, alpha := 1.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", paper(bg, alpha))
	p.theme = theme()
	return p


## One of the UI pack's chunky buttons ("button_green", "button_red", "button_blue", "button_teal")
## with a label on it. width is in pixels; the height follows the picture.
static func button(text: String, sprite: String, edge: Color, width: float, on_press: Callable, font_size := 26.0) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = tex(sprite)
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.custom_minimum_size = Vector2(width, width * 161.0 / 362.0)
	b.focus_mode = Control.FOCUS_ALL
	var l := label(text, font_size, CREAM, 7, edge)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.offset_bottom = -width * 161.0 / 362.0 * 0.16        # sit on the button's face, not its shadow
	l.name = "Text"
	b.add_child(l)
	b.resized.connect(func(): b.pivot_offset = b.size * 0.5)
	b.button_down.connect(func(): b.create_tween().tween_property(b, "scale", Vector2(1.04, 0.88), 0.06))
	b.button_up.connect(func(): b.create_tween().tween_property(b, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))
	b.mouse_entered.connect(func():
		if not b.disabled:
			b.create_tween().tween_property(b, "scale", Vector2.ONE * 1.06, 0.1))
	b.mouse_exited.connect(func(): b.create_tween().tween_property(b, "scale", Vector2.ONE, 0.1))
	b.pressed.connect(on_press)
	return b


static func set_button_text(b: TextureButton, text: String) -> void:
	var l := b.get_node_or_null("Text") as Label
	if l:
		l.text = text


static func set_button_enabled(b: TextureButton, on: bool) -> void:
	b.disabled = not on
	b.modulate = Color.WHITE if on else Color(0.7, 0.7, 0.7, 0.6)


static func line_edit(placeholder: String, text := "", width := 320.0) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.custom_minimum_size = Vector2(width, 48)
	e.theme = theme()
	return e


## A labelled row: "Port   [ 9999 ]"
static func field_row(caption: String, field: Control, caption_width := 150.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := label(caption, 26)
	l.custom_minimum_size.x = caption_width
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	row.add_child(field)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


## Grass-green backdrop with a soft vignette, for the menu and the lobby.
static func backdrop(parent: Control) -> void:
	var bg := ColorRect.new()
	bg.color = GRASS
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	var g := Gradient.new()
	g.set_color(0, Color(0.45, 0.7, 0.35))
	g.set_color(1, Color(0.2, 0.38, 0.18))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.4)
	gt.fill_to = Vector2(1.1, 1.1)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tr)


## The game's title in bouncy letters (smaller cousin of the title screen's).
static func title(text: String, size := 84.0) -> Label:
	var l := label(text, size, Color(1.0, 0.86, 0.3), 18, BROWN)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l
