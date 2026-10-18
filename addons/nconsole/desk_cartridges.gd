class_name NConsoleDeskCartridges
extends Node
## The cartridges of an [NConsole3D] with its desk: one in the console's
## port and one on each of two places on the desk behind it, by the port.
## Clicking a cartridge on the desk swaps it with the one in the port: that
## one comes out and goes to the clicked one's place, the clicked one goes
## in, and the console starts its game. A cartridge without a game is a
## blank: with it in, the console stays off.
##
## The cartridges are built from the model's spare ones
## (CartridgeSpare_A_GRP, CartridgeSpare_B_GRP), the one for the port with
## the label of the console's own cartridge (Cartridge_Label), which this
## hides.

## A cartridge went into the port; [param path] is its game ("" for none).
signal swapped(path: String)

## Where a cartridge's middle is, in the model's space: in the port (in as
## far as up to its label), pulled out of it, and on the desk.
const PORT := Vector3(0.0, 0.0, -5.3)
const PULLED := Vector3(0.0, 0.0, -7.6)
const SPOTS: Array[Vector3] = [Vector3(-7.0, -0.825, -11.5), Vector3(7.0, -0.825, -11.5)]
## How each place on the desk turns a cartridge, in degrees.
const SPOT_TURN: Array[float] = [9.0, -7.0]
## How high the cartridges go as they pass each other.
const OUT_ARC := 3.5
const IN_ARC := 1.8
## How far the mouse may move between press and release for a click.
const CLICK_SLOP := 6.0

## How long a swap takes.
var seconds := 1.6
## Each cartridge: its node, the box to click (in the node's space), the
## title on its label, the game's path and the loaded game (null if none).
var cartridges: Array[Dictionary] = []

var _c3d: NConsole3D
## Which cartridge is where: the port, then each place on the desk.
var _in_port := 0
var _at_spot: Array[int] = [1, 2]
var _busy := false
var _press_at := Vector2.ZERO
var _hovered := false


## Builds the cartridges into [param c3d]'s model. [param paths]: the games
## on the desk, one for each place ("" for a blank); the one in the port is
## the console's.
func setup(c3d: NConsole3D, paths: PackedStringArray) -> void:
	_c3d = c3d
	var model := c3d.model
	var spare_a := model.find_child("CartridgeSpare_A_GRP", true, false) as Node3D
	var spare_b := model.find_child("CartridgeSpare_B_GRP", true, false) as Node3D
	var own := model.find_child("Cartridge_GRP", true, false) as Node3D
	var own_label := model.find_child("Cartridge_Label", true, false) as MeshInstance3D
	if spare_a == null or spare_b == null or own == null:
		push_warning("NConsoleDeskCartridges: the model has no spare cartridges")
		return
	var yellow: Material = own_label.get_active_material(0) if own_label else null
	var port_cart := c3d.console.cartridge
	cartridges.append(_build(spare_a, yellow, c3d.cartridge_path, port_cart))
	for k in 2:
		var path := paths[k] if k < paths.size() else ""
		var cart := NCAssembler.load_cartridge(path) if not path.is_empty() else null
		cartridges.append(_build(spare_b if k == 1 else spare_a, null, path, cart))
	own.hide()
	spare_a.get_parent().remove_child(spare_a)
	spare_a.free()
	spare_b.get_parent().remove_child(spare_b)
	spare_b.free()
	for k in cartridges.size():
		model.add_child(cartridges[k].node)
		cartridges[k].node.transform = _pose(-1 if k == 0 else k - 1)


## The cartridge whose box [param origin] + t * [param direction] (global
## space) meets first, or -1.
func cartridge_at(origin: Vector3, direction: Vector3) -> int:
	var best := -1
	var nearest := INF
	for k in cartridges.size():
		var node: Node3D = cartridges[k].node
		var to_local := node.global_transform.affine_inverse()
		var hit: Variant = (cartridges[k].box as AABB).intersects_ray(to_local * origin, to_local.basis * direction)
		if hit != null:
			var d := origin.distance_to(node.global_transform * (hit as Vector3))
			if d < nearest:
				nearest = d
				best = k
	return best


## The place on the desk of cartridge [param k], or -1 while it's in the port.
func place_of(k: int) -> int:
	return _at_spot.find(k)


## Swaps the cartridge at desk place [param spot] with the one in the port.
## Does nothing while a swap is under way.
func swap(spot: int) -> void:
	if _busy or spot < 0 or spot >= _at_spot.size():
		return
	_busy = true
	var going_in := _at_spot[spot]
	var coming_out := _in_port
	var outer: Node3D = cartridges[coming_out].node
	var inner: Node3D = cartridges[going_in].node
	_c3d.player.eject()
	_c3d._update_parts()
	var step := seconds / 4.0
	var t := create_tween()
	t.tween_property(outer, "position", PULLED, step).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_method(_fly.bind(outer, _pose(-2), _pose(spot), OUT_ARC), 0.0, 1.0, step * 2.0)
	t.parallel().tween_method(_fly.bind(inner, _pose(spot), _pose(-2), IN_ARC), 0.0, 1.0, step * 2.0)
	t.tween_property(inner, "position", PORT, step).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_callback(_inserted.bind(going_in, coming_out, spot))


## Puts the console's new game on the label of the cartridge in the port.
func port_changed() -> void:
	if cartridges.is_empty():
		return
	var cart := _c3d.console.cartridge
	cartridges[_in_port].cart = cart
	cartridges[_in_port].title.text = cart.title.to_upper() if cart else ""


## A cartridge's transform at [param place]: the port (-1), pulled out of
## it (-2), or a place on the desk.
func _pose(place: int) -> Transform3D:
	if place == -1:
		return Transform3D(Basis(), PORT)
	if place == -2:
		return Transform3D(Basis(), PULLED)
	return Transform3D(Basis(Vector3.UP, deg_to_rad(SPOT_TURN[place])), SPOTS[place])


## Moves [param node] from [param from] to [param to] along an arc
## [param height] high, [param f] of the way.
func _fly(f: float, node: Node3D, from: Transform3D, to: Transform3D, height: float) -> void:
	var e := ease(f, -2.0) # slow at both ends
	var at := from.interpolate_with(to, e)
	at.origin.y += sin(e * PI) * height
	node.transform = at


func _inserted(going_in: int, coming_out: int, spot: int) -> void:
	_in_port = going_in
	_at_spot[spot] = coming_out
	var c: Dictionary = cartridges[going_in]
	if c.cart != null:
		_c3d.player.insert_cartridge(c.cart, String(c.path).get_file().get_basename())
	_c3d._update_parts()
	_busy = false
	swapped.emit(c.path)


## A cartridge from the meshes of [param group] (a spare one: its shell
## and label), its middle at the node's origin, its long side along Z with
## the label toward -Z, the end that goes in toward +Z.
func _build(group: Node3D, label_material: Material, path: String, cart: NCCartridge) -> Dictionary:
	var shell := group.find_child("*_Shell", false, false) as MeshInstance3D
	var label := group.find_child("*_Label", false, false) as MeshInstance3D
	var box := shell.transform * shell.get_aabb()
	var middle := box.get_center()
	var node := Node3D.new()
	node.name = "Cartridge"
	for part: MeshInstance3D in [shell, label]:
		var copy := part.duplicate() as MeshInstance3D
		copy.transform = Transform3D(Basis(), -middle) * part.transform
		node.add_child(copy)
		if part == label and label_material:
			copy.material_override = label_material
	var label_box := label.transform * label.get_aabb()
	var title := Label3D.new()
	title.position = Vector3(label_box.get_center().x, label_box.end.y + 0.003, label_box.get_center().z) - middle
	title.rotation_degrees.x = -90.0 # lying on the label, read from the front
	title.pixel_size = 0.006
	title.font_size = 48
	title.modulate = Color(0.12, 0.12, 0.14)
	title.outline_size = 0
	title.double_sided = false
	title.text = cart.title.to_upper() if cart else ""
	node.add_child(title)
	return {node = node, box = AABB(box.position - middle, box.size).grow(0.15), title = title, path = path, cart = cart}


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_press_at = button.position
		elif button.position.distance_to(_press_at) <= CLICK_SLOP:
			var spot := place_of(_pointed(button.position))
			if spot >= 0:
				swap(spot)
				get_viewport().set_input_as_handled()
		return
	var motion := event as InputEventMouseMotion
	if motion and motion.button_mask == 0:
		var over := place_of(_pointed(motion.position)) >= 0
		if over != _hovered:
			_hovered = over
			Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if over else Input.CURSOR_ARROW)


## The cartridge under the mouse at [param at], or -1.
func _pointed(at: Vector2) -> int:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return -1
	return cartridge_at(camera.project_ray_origin(at), camera.project_ray_normal(at))
