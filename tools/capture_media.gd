extends SceneTree
## Records the images in docs/images. Each mode writes into OUT:
##
##   MODE=3d FRAMES=240 [STATIC=1]  frames of the 3D console playing Gem
##                                  Hopper (f0000.png...), and console.png;
##                                  needs a window: --resolution 960x540
##   MODE=2d FRAMES=240             frames of the game itself, hopper.png,
##                                  snake.png
##   MODE=debugger                  debugger.png; --resolution 1280x720
##
##   godot --path . --resolution 960x540 -s tools/capture_media.gd
##
## A bot plays: it runs right and tries the future (save the console,
## run ahead, restore) to jump only when walking on would cost a life.
## Frames are stepped here, three game frames per picture (20 per second),
## so the result doesn't depend on how fast the machine is. See the README
## for turning the frames into GIFs with ffmpeg.

var c: NConsole
var sym := {}
var out := ""
var _hold_a := 0
var _run := 0


func _initialize() -> void:
	out = OS.get_environment("OUT")
	match OS.get_environment("MODE"):
		"3d": await record_3d()
		"2d": record_2d()
		"debugger": await record_debugger()
	quit(0)


## Gem Hopper's hero runs right; before each move it tries the future
## (save, run ahead, restore) and jumps only when walking on would kill it.
func bot() -> int:
	if c.cpu.peek(sym.state) != 1:
		return 0
	if _hold_a > 0:
		_hold_a -= 1
		return NConsole.BTN_RIGHT | NConsole.BTN_A | _run
	if c.cpu.peek(sym.on_ground) == 0:
		return NConsole.BTN_RIGHT | _run
	_run = 0
	if survives(func(_i: int) -> int: return NConsole.BTN_RIGHT, 70):
		return NConsole.BTN_RIGHT
	for run in [0, NConsole.BTN_B]:
		for hold in [14, 6, 20, 10]:
			if lands_safely(hold, run):
				_hold_a = hold - 1
				_run = run
				return NConsole.BTN_RIGHT | NConsole.BTN_A | run
	if survives(func(_i: int) -> int: return NConsole.BTN_RIGHT, 6):
		return NConsole.BTN_RIGHT # closer to the edge, then jump
	return 0 # wait for a better moment


## A jump holding A for [param hold] frames comes down on solid ground alive.
func lands_safely(hold: int, run: int) -> bool:
	var saved := snapshot()
	var left_ground := false
	var ok := false
	for i in 120:
		c.set_pad(0, NConsole.BTN_RIGHT | run | (NConsole.BTN_A if i < hold else 0))
		c.run_frame()
		if c.cpu.peek(sym.state) != 1:
			ok = c.cpu.peek(sym.state) == 3 # reached the star
			break
		if c.cpu.peek(sym.on_ground) == 0:
			left_ground = true
		elif left_ground:
			ok = true
			for k in 4: # and stays alive a moment
				c.set_pad(0, NConsole.BTN_RIGHT)
				c.run_frame()
				ok = ok and c.cpu.peek(sym.state) == 1
			break
	restore(saved)
	return ok


func survives(pad_at: Callable, frames: int) -> bool:
	var saved := snapshot()
	var lives := c.cpu.peek(sym.lives)
	var ok := true
	for i in frames:
		c.set_pad(0, pad_at.call(i))
		c.run_frame()
		if c.cpu.peek(sym.state) == 2 or c.cpu.peek(sym.lives) < lives:
			ok = false
			break
	restore(saved)
	return ok


func snapshot() -> Array:
	var cpu := c.cpu
	return [cpu.memory(), cpu.a, cpu.x, cpu.y, cpu.sp, cpu.pc, cpu.flags(), cpu.waiting, cpu.halted, cpu.cycles,
		c.frame, c.vctrl, c.bg_color, c.scroll_x, c.scroll_y, c.fixed_rows, c.prg_bank, c.video.chr_bank]


func restore(s: Array) -> void:
	var cpu := c.cpu
	cpu.load_memory(0, s[0])
	cpu.a = s[1]
	cpu.x = s[2]
	cpu.y = s[3]
	cpu.sp = s[4]
	cpu.pc = s[5]
	cpu.set_flags(s[6])
	cpu.waiting = s[7]
	cpu.halted = s[8]
	cpu.cycles = s[9]
	c.frame = s[10]
	c.vctrl = s[11]
	c.bg_color = s[12]
	c.scroll_x = s[13]
	c.scroll_y = s[14]
	c.fixed_rows = s[15]
	c.prg_bank = s[16]
	c.video.chr_bank = s[17]


func start_hopper() -> void:
	var cart := NCAssembler.load_cartridge("res://addons/nconsole/games/hopper.asm")
	sym = cart.symbols
	c.insert(cart)
	for k in 30:
		c.run_frame()
	c.set_pad(0, NConsole.BTN_START)
	c.run_frame()
	c.set_pad(0, 0)
	for k in 20:
		c.run_frame()


var _last_pads: Array[int] = []


func step(frames: int) -> void:
	for k in frames:
		var pad := bot()
		_last_pads.append(pad)
		if _last_pads.size() > 12:
			_last_pads.pop_front()
		var before := c.cpu.peek(sym.state)
		c.set_pad(0, pad)
		c.run_frame()
		if before == 1 and c.cpu.peek(sym.state) == 2:
			var bugs := []
			for b in 4:
				if c.cpu.peek(sym.est + b) != 0:
					bugs.append([c.cpu.peek(sym.ex_l + b) | (c.cpu.peek(sym.ex_h + b) << 8), c.cpu.peek(sym.ey + b), c.cpu.peek(sym.est + b)])
			push_warning("the bot's hero died: x=%d y=%d vy=%d ground=%d bugs=%s pads=%s" % [c.cpu.peek(sym.px_l) | (c.cpu.peek(sym.px_h) << 8), c.cpu.peek(sym.py), c.cpu.peek(sym.vy_h), c.cpu.peek(sym.on_ground), bugs, _last_pads])


func record_3d() -> void:
	root.size = Vector2i(960, 540)
	var scene: Node = load("res://addons/nconsole/demo/console_3d.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var c3d: NConsole3D = scene.get_node("NConsole3D")
	c3d.player.set_process(false) # frames are stepped here, not in real time
	c = c3d.console
	c3d._title.text = "GEM HOPPER"
	start_hopper()
	var count := int(OS.get_environment("FRAMES"))
	for n in count:
		var t := float(n) / count
		scene._yaw = -7.0 if OS.get_environment("STATIC") != "" else sin(t * TAU) * 14.0
		scene._pitch = -54.0 if OS.get_environment("STATIC") != "" else -52.0 + cos(t * TAU) * 3.0
		scene._distance = 20.0
		scene._apply()
		step(3)
		c3d.player._show_picture()
		c3d._update_parts()
		await process_frame
		await process_frame
		root.get_texture().get_image().save_png("%s/f%04d.png" % [out, n])
	scene._yaw = -8.0
	scene._pitch = -58.0
	scene._distance = 17.0
	scene._apply()
	root.size = Vector2i(1600, 900)
	for k in 4:
		await process_frame
	root.get_texture().get_image().save_png(out + "/console.png")


func record_2d() -> void:
	c = NConsole.new()
	start_hopper()
	var count := int(OS.get_environment("FRAMES"))
	for n in count:
		step(3)
		c.video.image.save_png("%s/f%04d.png" % [out, n])
	step(90)
	_save_scaled(out + "/hopper.png")
	# Snake, a few moves in.
	var snake := NCAssembler.load_cartridge("res://addons/nconsole/games/snake.asm")
	c = NConsole.new()
	c.insert(snake)
	for k in 10:
		c.run_frame()
	c.set_pad(0, NConsole.BTN_START)
	c.run_frame()
	c.set_pad(0, 0)
	for pad in [0, NConsole.BTN_DOWN, 0, NConsole.BTN_RIGHT, 0]:
		c.set_pad(0, pad)
		for k in 40:
			c.run_frame()
	_save_scaled(out + "/snake.png")


func _save_scaled(path: String) -> void:
	var img := c.video.image.duplicate()
	img.resize(640, 480, Image.INTERPOLATE_NEAREST)
	img.save_png(path)


func record_debugger() -> void:
	root.size = Vector2i(1280, 720)
	var scene: Node = load("res://addons/nconsole/demo/hopper.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var screen: NConsoleScreen = scene.get_node("Screen")
	screen.player.set_process(false)
	c = screen.console
	start_hopper()
	step(150)
	screen.player._show_picture()
	screen.player.toggle_debugger()
	var d := screen.debugger
	d.run("b bug_touch")
	d.run("c")
	for k in 120:
		c.set_pad(0, bot())
		c.run_frame()
		if c.paused:
			break
	d.stopped()
	d.run("r")
	d.run("m px_l 8")
	d.run("bd *")
	for k in 6:
		await process_frame
	root.get_texture().get_image().save_png(out + "/debugger.png")
