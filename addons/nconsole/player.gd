class_name NConsolePlayer
extends Node
## Runs an [NConsole] in real time for a view of it (the flat
## [NConsoleScreen] or the 3D [NConsole3D]): 60 frames a second, the
## controllers, the sound through an AudioStreamGenerator, the picture in
## [member texture]. F2 the debugger, F3 how busy the CPU and the emulator
## are, F5 reset.
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
## Microseconds the last frame took to emulate.
var frame_usec := 0
var _time := 0.0
var _audio: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
## Samples the sound buffer holds when full.
var _capacity := 0
var _refresh_in := 0


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
	console.insert(cart)
	monitor.refresh_labels()
	_show_picture()
	return true


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
	if ran:
		_show_picture()
		_refresh_in -= 1
		if debugger.visible and _refresh_in <= 0:
			debugger.refresh()
			_refresh_in = 10
		if stats.visible:
			stats.text = "CPU %d%%  emulation %.1f ms" % [console.last_cycles * 100 / NConsole.CYCLES_PER_FRAME, frame_usec / 1000.0]


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
			stats.visible = not stats.visible
		KEY_F5:
			console.reset()
		_:
			return
	get_viewport().set_input_as_handled()
