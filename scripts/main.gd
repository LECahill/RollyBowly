extends Node
## Real-time bowling defense, in waves.
##   A wave sends rows of ants marching on the house from one or more sides.
##   Clear the wave -> short break, the house heals a little -> the next, bigger wave.
##   From wave 3, helmeted soldier ants escort the groups and go after the rolly polly.
##   Lose when the house or the rolly polly runs out of HP.

@export var mob_scene: PackedScene
@export var house: Node3D                      ## the mushroom house (with house.gd). Empty = found automatically

@export_group("Waves")
@export var first_wave_ants := 6              ## 6 = one 3-row rack
@export var extra_ants_per_wave := 3
@export var max_rows_per_wave := 3             ## a wave is split into this many rows (from different sides) at most
@export var row_size := 6                      ## ants per group: 3 = small triangle, 6 = 3-row rack, 10 = full bowling rack
@export var row_spacing := 1.8                 ## gap between neighbouring ants in the triangle
@export var row_marches_together := true      ## every ant in a group walks at the same speed, keeping the rack intact
@export var keep_formation := true            ## groups march as a triangle (straight at the house) until they're close
@export var row_delay := 3.0                  ## seconds between rows of the same wave
@export var break_time := 6.0                  ## breather between waves
@export var heal_between_waves := 15           ## house HP restored after each cleared wave
@export var bug_heal_between_waves := 1        ## bug HP restored after each cleared wave
@export var spawn_radius_fraction := 0.85      ## rows appear this far out (fraction of the arena radius)

@export_group("Soldiers")
@export var soldier_scene: PackedScene         ## soldier.tscn. Empty = no soldiers
@export var soldiers_from_wave := 3            ## first wave with soldiers in it
@export var first_soldiers := 1                ## soldiers in that wave
@export var extra_soldier_every := 2           ## one more soldier every this many waves after that
@export var max_soldiers := 4                  ## never more than this many per wave
@export var soldier_escort_distance := 3.0     ## soldiers march this far behind the back row of their group

@export_group("Testing")
## Pretend to be a phone or an iPad when you press Play in the editor: touch-size buttons and text, and
## the window takes the device's shape. Only works in the editor; exported games always use the real device.
@export_enum("Off", "Phone upright", "Phone sideways", "Phone sizing only", "iPad upright", "iPad sideways", "iPad sizing only") var test_mobile := 0
@export var test_phone_size := Vector2i(390, 844)   ## the phone's screen held upright (sideways swaps these)
@export var test_ipad_size := Vector2i(820, 1180)   ## the iPad's screen held upright (iPad Air / 10th gen; Pro 13" is 1032 x 1376)

signal game_ended(reason: String)            # "bug" or "house": the game-over book (game_ui.gd) listens for this

var wave := 0
var waves_on_hold := false                   # set by the title screen: the backyard runs, but no wave starts yet
var game_over := false
var _spawning := false
var _break_left := 0.0
var _next_row := 0
var player: Node3D


## Runs before any of Main's children are ready, so the UI is built for the test phone from the start.
func _enter_tree() -> void:
	if not OS.has_feature("editor"):
		return                                   # never in an exported game
	var ipad := test_mobile >= 4
	UIFit.force_mobile = test_mobile != 0 and not ipad
	UIFit.force_tablet = ipad
	var upright := test_mobile == 1 or test_mobile == 4
	var sideways := test_mobile == 2 or test_mobile == 5
	if upright or sideways:
		var base := test_ipad_size if ipad else test_phone_size
		var s := Vector2(base) if upright else Vector2(base.y, base.x)
		# too big for your monitor (an iPad is taller than most): shrink it, keeping its exact shape.
		# The UI is laid out by the screen's shape, so a smaller window shows the same layout.
		var usable := Vector2(DisplayServer.screen_get_usable_rect().size) * 0.9
		if usable.x > 0.0 and usable.y > 0.0:
			s *= minf(1.0, minf(usable.x / s.x, usable.y / s.y))
		var win := get_window()
		if win.mode != Window.MODE_WINDOWED:
			win.mode = Window.MODE_WINDOWED
		win.size = Vector2i(s)
		win.move_to_center()


func _ready() -> void:
	if house == null:
		house = get_tree().get_first_node_in_group("house")
	if house:
		house.destroyed.connect(_on_house_destroyed)
	else:
		push_warning("Main: no house found. Attach house.gd to the mushroom house.")
	player = get_node_or_null("Player")
	_break_left = 2.0                              # short pause before the first wave


func _process(delta: float) -> void:
	if game_over:
		return
	if waves_on_hold:
		return
	if not _spawning and _ants_left() == 0:
		if _break_left <= 0.0:
			_break_left = break_time
			if wave > 0 and house:
				house.heal(heal_between_waves)
			if wave > 0 and _player_ok():
				player.heal(bug_heal_between_waves)
		_break_left -= delta
		if _break_left <= 0.0:
			_start_wave()


func _start_wave() -> void:
	wave += 1
	_spawning = true
	var total := first_wave_ants + extra_ants_per_wave * (wave - 1)
	var rows := clampi(ceili(float(total) / row_size), 1, max_rows_per_wave)
	var base_angle := randf() * TAU
	var left := total
	var soldiers := soldiers_in_wave(wave)
	for r in rows:
		if game_over:
			break
		var count := ceili(float(left) / (rows - r))
		left -= count
		var escort := ceili(float(soldiers) / (rows - r))          # share the soldiers out between the groups
		soldiers -= escort
		var angle := base_angle + TAU * r / rows + randf_range(-0.4, 0.4)   # rows come from different sides
		_spawn_row(count, angle, escort)
		if r < rows - 1:
			await get_tree().create_timer(row_delay).timeout
	_spawning = false
	_break_left = 0.0


## A group of ants racked up like bowling pins on the rim: the point of the triangle (the head pin)
## faces the house, the way pins face the bowler. The group marches in formation until it's close.
func _spawn_row(count: int, angle: float, soldiers := 0) -> void:
	var centre := Vector3.ZERO
	var radius := 30.0
	if _player_ok() and player.get("_arena_known"):
		centre = player.arena_center
		radius = player.arena_radius * spawn_radius_fraction
	var out := Vector3(cos(angle), 0.0, sin(angle))
	var target := house.global_position if house else centre
	var spots := _rack(count)
	var depth := 0.0
	for s in spots:
		depth = maxf(depth, s.y)
	var head := centre + out * (radius - depth)                # the back row ends up on the spawn radius
	var forward := _flat(target - head).normalized()            # the way the group marches
	if forward == Vector3.ZERO:
		forward = -out
	var side := Vector3(-forward.z, 0.0, forward.x)
	var row_speed := -1.0
	_next_row += 1
	for s in spots:
		var mob: Mob = mob_scene.instantiate()
		mob.initialize(head + side * s.x - forward * s.y)
		mob.row_id = _next_row
		mob.row_count = count
		mob.march_dir = forward if keep_formation else Vector3.ZERO
		mob.rotation.y = atan2(-forward.x, -forward.z)
		if row_marches_together:                   # one speed for the whole group so the rack stays intact
			if row_speed < 0.0:
				row_speed = mob.speed
			mob.speed = row_speed
		add_child(mob)
		# We connect the mob to the score label to update the score upon squashing one.
		mob.squashed.connect($UserInterface/ScoreLabel._on_mob_squashed.bind())

	# soldiers escort the group from behind, side by side. They aren't pins of the rack (no part in
	# STRIKE / SPARE), and once the bug comes near they break off and go for it.
	for i in soldiers:
		var soldier: Mob = soldier_scene.instantiate()
		var across := (i - (soldiers - 1) * 0.5) * row_spacing * 1.6
		soldier.initialize(head - forward * (depth + soldier_escort_distance) + side * across)
		soldier.march_dir = forward if keep_formation else Vector3.ZERO
		soldier.rotation.y = atan2(-forward.x, -forward.z)
		if row_marches_together and row_speed > 0.0:
			soldier.speed = row_speed
		add_child(soldier)
		soldier.squashed.connect($UserInterface/ScoreLabel._on_mob_squashed.bind())


## How many soldiers come with a given wave.
func soldiers_in_wave(w: int) -> int:
	if soldier_scene == null or w < soldiers_from_wave:
		return 0
	return mini(first_soldiers + floori(float(w - soldiers_from_wave) / maxi(extra_soldier_every, 1)), max_soldiers)


## Bowling-pin triangle: 1, 2, 3, 4... per row. x = sideways, y = distance back from the head pin.
## A last row that isn't full is centred.
func _rack(count: int) -> Array[Vector2]:
	var spots: Array[Vector2] = []
	var row := 0
	while spots.size() < count:
		var n := mini(row + 1, count - spots.size())
		for i in n:
			spots.append(Vector2((i - (n - 1) * 0.5) * row_spacing, row * row_spacing * 0.866))
		row += 1
	return spots


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _ants_left() -> int:
	return get_tree().get_nodes_in_group("mob").size()


func _player_ok() -> bool:
	return player != null and is_instance_valid(player) and player.is_inside_tree()


func _on_player_hit() -> void:
	_end_game("bug")


func _on_house_destroyed() -> void:
	_end_game("house")


## The game-over book (game_ui.gd) listens for game_ended and handles PLAY AGAIN / QUIT.
func _end_game(reason: String) -> void:
	if game_over:
		return
	game_over = true
	get_tree().call_group("mob", "set_physics_process", false)   # ants freeze where they are
	if _player_ok():
		player.set_process_input(false)                          # no more launching
	game_ended.emit(reason)
