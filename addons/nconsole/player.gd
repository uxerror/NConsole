class_name NConsolePlayer
extends Node
## Runs an [NConsole] in real time for a view of it (the flat
## [NConsoleScreen] or the 3D [NConsole3D]): 60 frames a second, the
## controllers, the sound through an AudioStreamGenerator, the picture in
## [member texture]. F2 the debugger, F3 how busy the CPU and the emulator
## are, F5 reset, F6 saves the console's state and F4 goes back to it.
##
## A cartridge's save RAM is kept in [member save_dir], as the cartridge's
## file name with .sav; the saved state next to it with .state.
##
## The controllers are input actions, [code]nconsole_p1_up[/code] to
## [code]nconsole_p2_start[/code] (see [constant ACTIONS]). Those the
## project doesn't define get these: for controller 1 the keyboard (arrows
## or WASD, Z/J for A, X/K for B, Enter for start, Shift for select) and
## the first gamepad (d-pad or left stick, south button A, west button B,
## start, back for select); for controller 2 the second gamepad.
##
## The emulation keeps pace with the sound card: it runs a little faster
## or slower (by at most half a percent, too little to hear) to keep the
## sound buffer at [constant SOUND_LEAD] frames.
##
## The view adds [member debugger] and [member stats] where it wants them.

## The picture changed.
signal picture_updated
## The debugger was opened or closed.
signal debugger_toggled(open: bool)

## The button bit of each action, without its "nconsole_pN_" prefix.
const ACTIONS := {
	"up": NConsole.BTN_UP, "down": NConsole.BTN_DOWN,
	"left": NConsole.BTN_LEFT, "right": NConsole.BTN_RIGHT,
	"a": NConsole.BTN_A, "b": NConsole.BTN_B,
	"select": NConsole.BTN_SELECT, "start": NConsole.BTN_START,
}
const KEYS := {
	"up": [KEY_UP, KEY_W], "down": [KEY_DOWN, KEY_S],
	"left": [KEY_LEFT, KEY_A], "right": [KEY_RIGHT, KEY_D],
	"a": [KEY_Z, KEY_J], "b": [KEY_X, KEY_K],
	"select": [KEY_SHIFT], "start": [KEY_ENTER],
}
const JOY_BUTTONS := {
	"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN,
	"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
	"a": JOY_BUTTON_A, "b": JOY_BUTTON_X,
	"select": JOY_BUTTON_BACK, "start": JOY_BUTTON_START,
}
## The left stick: [axis, direction].
const JOY_AXES := {
	"up": [JOY_AXIS_LEFT_Y, -1.0], "down": [JOY_AXIS_LEFT_Y, 1.0],
	"left": [JOY_AXIS_LEFT_X, -1.0], "right": [JOY_AXIS_LEFT_X, 1.0],
}
## Frames of sound to keep queued ahead of the sound card.
const SOUND_LEAD := 3
## How far the emulation's speed may drift to keep that lead.
const MAX_SKEW := 0.005

var console := NConsole.new()
var texture := ImageTexture.create_from_image(console.video.image)
var monitor := NCMonitor.new(console)
var debugger := NConsoleDebugger.new(monitor)
var stats := Label.new()
## Where save RAM and saved states go.
var save_dir := "user://nconsole"
## Microseconds the last frame took to emulate.
var frame_usec := 0
var _time := 0.0
var _audio: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
## Samples the sound buffer holds when full.
var _capacity := 0
var _refresh_in := 0
var _save_name := ""
var _show_stats := false
var _notice := ""
var _notice_left := 0.0


func _init() -> void:
	add_default_actions()
	debugger.hide()
	debugger.picture_changed.connect(_show_picture)
	stats.visible = false
	stats.add_theme_color_override("font_color", Color.YELLOW)


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = NConsole.SAMPLE_RATE
	gen.buffer_length = 0.1
	_audio = AudioStreamPlayer.new()
	_audio.stream = gen
	add_child(_audio)
	_audio.play()
	_playback = _audio.get_stream_playback()
	_capacity = _playback.get_frames_available()


func _exit_tree() -> void:
	flush_save_ram()
	# Stop the stream first, or its playback outlives the player.
	_playback = null
	if _audio:
		_audio.stop()
		_audio.stream = null


## Puts in a cartridge (.nc8, or .asm to assemble) and switches on.
func load_cartridge(path: String) -> bool:
	var cart := NCAssembler.load_cartridge(path)
	if cart == null:
		return false
	flush_save_ram()
	console.insert(cart)
	_save_name = path.get_file().get_basename()
	if cart.sram_size > 0 and FileAccess.file_exists(_save_path("sav")):
		console.save_ram = FileAccess.get_file_as_bytes(_save_path("sav"))
	monitor.refresh_labels()
	_show_picture()
	return true


## Writes the save RAM to its file if the game changed it.
func flush_save_ram() -> void:
	if console.cartridge == null or console.cpu.sram_size == 0 or not console.cpu.sram_dirty:
		return
	if _write(_save_path("sav"), console.save_ram):
		console.cpu.sram_dirty = false


## Saves the console's state to the cartridge's .state file.
func save_state() -> bool:
	if console.cartridge == null:
		return false
	var ok := _write(_save_path("state"), console.save_state())
	notify("state saved" if ok else "can't write " + _save_path("state"))
	return ok


## Goes back to the state in the cartridge's .state file.
func load_state() -> bool:
	if console.cartridge == null:
		return false
	var path := _save_path("state")
	if not FileAccess.file_exists(path):
		notify("no saved state")
		return false
	if not console.load_state(FileAccess.get_file_as_bytes(path)):
		notify("the saved state is from another cartridge")
		return false
	_time = 0.0
	_show_picture()
	if debugger.visible:
		debugger.refresh()
	notify("state loaded")
	return true


## Shows [param text] over the picture for a moment.
func notify(text: String) -> void:
	_notice = text
	_notice_left = 1.5
	_update_stats()


func _save_path(extension: String) -> String:
	return save_dir.path_join(_save_name + "." + extension)


func _write(path: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("NConsole: can't write %s" % path)
		return false
	f.store_buffer(data)
	return true


func _update_stats() -> void:
	if _notice_left > 0.0:
		stats.text = _notice
	elif _show_stats:
		stats.text = "CPU %d%%  emulation %.1f ms" % [console.last_cycles * 100 / NConsole.CYCLES_PER_FRAME, frame_usec / 1000.0]
	stats.visible = _notice_left > 0.0 or _show_stats


## The name of the action for [param button] ("up", "a", ...) on
## controller [param pad] (0 or 1).
static func action_name(pad: int, button: String) -> StringName:
	return StringName("nconsole_p%d_%s" % [pad + 1, button])


## Adds the default keys and gamepad buttons for the actions the project
## doesn't define itself.
static func add_default_actions() -> void:
	for pad in 2:
		for button: String in ACTIONS:
			var action := action_name(pad, button)
			if InputMap.has_action(action):
				continue
			InputMap.add_action(action, 0.5)
			if pad == 0:
				for key: int in KEYS[button]:
					var k := InputEventKey.new()
					k.device = -1 # any keyboard
					k.physical_keycode = key
					InputMap.action_add_event(action, k)
			var j := InputEventJoypadButton.new()
			j.device = pad
			j.button_index = JOY_BUTTONS[button]
			InputMap.action_add_event(action, j)
			if JOY_AXES.has(button):
				var m := InputEventJoypadMotion.new()
				m.device = pad
				m.axis = JOY_AXES[button][0]
				m.axis_value = JOY_AXES[button][1]
				InputMap.action_add_event(action, m)


## The buttons held for controller [param pad], as controller bits.
static func pad_buttons(pad: int) -> int:
	var buttons := 0
	for button: String in ACTIONS:
		if Input.is_action_pressed(action_name(pad, button)):
			buttons |= ACTIONS[button]
	return buttons


func toggle_debugger() -> void:
	if debugger.visible:
		debugger.hide()
	else:
		debugger.open()
	debugger_toggled.emit(debugger.visible)


func _show_picture() -> void:
	texture.update(console.video.image)
	picture_updated.emit()


func _process(delta: float) -> void:
	if _notice_left > 0.0:
		_notice_left -= delta
		if _notice_left <= 0.0:
			_update_stats()
	if console.cartridge == null:
		return
	if console.paused:
		_time = 0.0
		return
	var typing := debugger.is_typing()
	for pad in 2:
		console.set_pad(pad, 0 if typing else pad_buttons(pad))
	_time = minf(_time + delta * _speed(), 3.0 / NConsole.FPS) # don't try to catch up after a stall
	var ran := false
	while _time >= 1.0 / NConsole.FPS:
		_time -= 1.0 / NConsole.FPS
		var t := Time.get_ticks_usec()
		console.run_frame()
		frame_usec = Time.get_ticks_usec() - t
		ran = true
		if console.paused:
			if not debugger.visible:
				toggle_debugger()
			debugger.stopped()
			break
		if _playback and _playback.get_frames_available() >= console.sound.size():
			_playback.push_buffer(console.sound)
		if console.frame % NConsole.FPS == 0:
			flush_save_ram()
	if ran:
		_show_picture()
		_refresh_in -= 1
		if debugger.visible and _refresh_in <= 0:
			debugger.refresh()
			_refresh_in = 10
		_update_stats()


## How fast to run, 1 being real time: a little faster while the sound
## buffer runs short, a little slower while it fills up. After a stall
## leaves it nearly empty, silence makes up the lead.
func _speed() -> float:
	if _playback == null or _capacity == 0:
		return 1.0
	var lead := SOUND_LEAD * NConsole.SAMPLES_PER_FRAME
	var queued := _capacity - _playback.get_frames_available()
	if queued < NConsole.SAMPLES_PER_FRAME:
		var silence := PackedVector2Array()
		silence.resize(lead - queued)
		_playback.push_buffer(silence)
		queued = lead
	return 1.0 + clampf(float(lead - queued) / lead, -1.0, 1.0) * MAX_SKEW


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_F2:
			toggle_debugger()
		KEY_F3:
			_show_stats = not _show_stats
			_update_stats()
		KEY_F4:
			load_state()
		KEY_F5:
			console.reset()
		KEY_F6:
			save_state()
		_:
			return
	get_viewport().set_input_as_handled()
