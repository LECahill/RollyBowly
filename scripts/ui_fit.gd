class_name UIFit
extends RefCounted
## Screen-size helpers shared by all the UI scripts, so the HUD and menus fit phones (portrait and
## landscape) as well as desktop windows. Nothing to add to the scene.
##
## "Design pixels" are the sizes the UI was drawn for: a 1920 x 1080 desktop window.

## Phones get everything a fair bit bigger (small screen in your hand); tablets a little bigger
## (bigger screen, but still touch: buttons need to be easy to hit with a finger).
static var mobile_boost := 1.4
static var tablet_boost := 1.15
## Test the phone / tablet layouts on desktop (main.gd's Testing > Test Mobile sets these).
static var force_mobile := false
static var force_tablet := false

static var _device := ""                      # "phone", "tablet" or "desktop", worked out once

## Finger or mouse? A tap on a touch screen also pretends to be the mouse (Godot does it, and Safari on
## iPad sends its own fake mouse events right after the finger lifts). Without this, a tapped button
## "hovers" (grows a little) and stays that way until you tap somewhere else.
## cursor.gd reports every touch and every real mouse move here; buttons ask hover_ok() before growing.
static var _touch_pointer := false
static var _last_touch_ms := -100000
## Mouse moves this soon after a touch are the browser's fake ones, not a real mouse.
const FAKE_MOUSE_AFTER_TOUCH_MS := 1000


## A finger touched the screen: switch the hover look off.
static func note_touch() -> void:
	_touch_pointer = true
	_last_touch_ms = Time.get_ticks_msec()


## The mouse moved. Only counts as a real mouse (a desktop, or an iPad trackpad) if it isn't the
## browser's fake move right after a tap.
static func note_mouse() -> void:
	if Time.get_ticks_msec() - _last_touch_ms > FAKE_MOUSE_AFTER_TOUCH_MS:
		_touch_pointer = false


## Whether a button may do its "mouse is over me" grow. False while the player is using their finger.
static func hover_ok() -> bool:
	return not _touch_pointer


## A touch device: phone or tablet (iPad included). Bigger buttons, no CLOSE button, "Tap" wording.
static func is_mobile() -> bool:
	return device() != "desktop"


static func is_tablet() -> bool:
	return device() == "tablet"


## What we're running on. iPads are the tricky one: Safari on iPad pretends to be a Mac, so the
## browser's own "is this iOS" check says no. Instead we ask the browser whether the screen is
## touch-first (a finger, not a mouse) and how big it is.
static func device() -> String:
	if force_tablet:
		return "tablet"
	if force_mobile:
		return "phone"
	if _device != "":
		return _device
	_device = "desktop"
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var touch_points = JavaScriptBridge.eval("navigator.maxTouchPoints || 0", true)
		var coarse = JavaScriptBridge.eval("window.matchMedia('(pointer: coarse)').matches", true)
		var short_side = JavaScriptBridge.eval("Math.min(screen.width, screen.height)", true)  # CSS pixels
		var mobile_os := OS.has_feature("web_ios") or OS.has_feature("web_android")
		if (mobile_os or coarse == true) and touch_points != null and int(touch_points) > 0:
			_device = "phone" if short_side != null and float(short_side) < 600.0 else "tablet"
	elif OS.has_feature("mobile"):
		# native app: measure the screen in inches
		var px := DisplayServer.screen_get_size()
		var dpi := maxf(float(DisplayServer.screen_get_dpi()), 1.0)
		_device = "phone" if minf(px.x, px.y) / dpi < 3.6 else "tablet"
	return _device


static func size(vp: Viewport) -> Vector2:
	return vp.get_visible_rect().size


## Taller than it is wide (a phone or iPad held upright).
static func is_portrait(vp: Viewport) -> bool:
	var s := size(vp)
	return s.y > s.x * 1.05


## Scale for the HUD (score, hearts, wave tab, arrows): 1.0 on a 1080p desktop window.
## Based on the screen's short side, so it's the same size whichever way a phone is held.
static func hud_k(vp: Viewport) -> float:
	var s := size(vp)
	var k := minf(s.x, s.y) / 1080.0
	if is_tablet():
		k *= tablet_boost
	elif is_mobile():
		k *= mobile_boost
	# never wider than the screen: score + hearts + pause button must fit side by side
	return minf(k, s.x / 760.0)


## Scale for a menu panel that needs `design` design pixels: as big as it can be while still
## fitting in `fill` of the screen, but never bigger than the desktop look (a bit bigger on phones).
static func menu_k(vp: Viewport, design: Vector2, fill := Vector2(0.94, 0.88)) -> float:
	var s := size(vp)
	var fit := minf(s.x * fill.x / design.x, s.y * fill.y / design.y)
	var cap := minf(s.x, s.y) / 1080.0 * (1.3 if is_tablet() else (1.8 if is_mobile() else 1.0))
	if not is_mobile() and not is_portrait(vp):
		cap = s.y / 1080.0                     # desktop: exactly the look it always had
	return minf(fit, cap)


## How far down the screen the top HUD row (score / hearts / pause) reaches, in screen pixels.
static func top_bar_bottom(vp: Viewport) -> float:
	return 96.0 * hud_k(vp)


## A paper card (card_frame.png) that stretches to any size without distorting its frame or the
## curled corner: drawn as a nine-patch at the texture's own resolution, then scaled down to fit.
## Returns a plain Control of `size_px` (screen pixels) holding it, so it can be animated like any sprite.
static func card(texture: Texture2D, size_px: Vector2) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size = size_px
	holder.pivot_offset = size_px * 0.5
	var n := NinePatchRect.new()
	n.texture = texture
	n.patch_margin_left = 120
	n.patch_margin_right = 110
	n.patch_margin_top = 260
	n.patch_margin_bottom = 160
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex_w := float(texture.get_width()) if texture else 600.0
	var s := size_px.x / tex_w                 # screen pixels per texture pixel
	n.size = Vector2(tex_w, size_px.y / s)
	n.scale = Vector2(s, s)
	holder.add_child(n)
	return holder
