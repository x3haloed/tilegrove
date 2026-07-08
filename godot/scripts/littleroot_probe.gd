extends Node2D

const MANIFEST_PATH := "res://assets/pokeemerald/maps/littleroot_town.json"
const TILE_SIZE := 16

@onready var map_sprite: Sprite2D = $LittlerootTownProbe
@onready var player_marker: ColorRect = $PlayerMarker
@onready var status_label: Label = $StatusLabel

var manifest: Dictionary = {}
var player_cell := Vector2i(10, 15)


func _ready() -> void:
	load_manifest()
	if not is_cell_passable(player_cell):
		player_cell = first_passable_cell()
	update_player_marker()
	update_status("ready")


func _process(_delta: float) -> void:
	var movement := Vector2i.ZERO
	if Input.is_action_just_pressed("ui_left"):
		movement = Vector2i.LEFT
	elif Input.is_action_just_pressed("ui_right"):
		movement = Vector2i.RIGHT
	elif Input.is_action_just_pressed("ui_up"):
		movement = Vector2i.UP
	elif Input.is_action_just_pressed("ui_down"):
		movement = Vector2i.DOWN

	if movement != Vector2i.ZERO:
		try_move(movement)


func load_manifest() -> void:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not open Littleroot manifest: %s" % MANIFEST_PATH)
		return

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK:
		push_error("Could not parse Littleroot manifest: %s" % json.get_error_message())
		return

	manifest = json.get_data()


func try_move(delta: Vector2i) -> bool:
	var target := player_cell + delta
	if is_cell_passable(target):
		player_cell = target
		update_player_marker()
		update_status("moved to %s" % cell_text(player_cell))
		return true

	update_status("blocked at %s" % cell_text(target))
	return false


func is_cell_passable(cell: Vector2i) -> bool:
	var data := cell_data(cell)
	return not data.is_empty() and bool(data.get("passable", false))


func cell_data(cell: Vector2i) -> Dictionary:
	if manifest.is_empty():
		return {}
	if cell.x < 0 or cell.y < 0:
		return {}
	if cell.x >= int(manifest.get("width", 0)) or cell.y >= int(manifest.get("height", 0)):
		return {}
	return manifest["cells"][cell.y][cell.x]


func first_passable_cell() -> Vector2i:
	for y in range(int(manifest.get("height", 0))):
		for x in range(int(manifest.get("width", 0))):
			var candidate := Vector2i(x, y)
			if is_cell_passable(candidate):
				return candidate
	return Vector2i.ZERO


func update_player_marker() -> void:
	var scale_factor := map_sprite.scale.x
	var marker_size := Vector2(TILE_SIZE, TILE_SIZE) * scale_factor
	player_marker.size = marker_size
	player_marker.position = map_sprite.position + Vector2(player_cell * TILE_SIZE) * scale_factor


func update_status(prefix: String) -> void:
	var data := cell_data(player_cell)
	status_label.text = "%s\ncell %s\ncollision %d | elevation %d\nmetatile %d" % [
		prefix,
		cell_text(player_cell),
		int(data.get("collision", -1)),
		int(data.get("elevation", -1)),
		int(data.get("metatile_id", -1)),
	]


func cell_text(cell: Vector2i) -> String:
	return "(%d,%d)" % [cell.x, cell.y]
