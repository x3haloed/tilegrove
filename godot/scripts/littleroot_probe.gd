extends Node2D

const TILE_SIZE := 16
const CONTROL_HTTP_HOST := "127.0.0.1"
const CONTROL_HTTP_PORT := 38473
const CONTROL_HTTP_PORT_SCAN_COUNT := 16
const CONTROL_HTTP_REQUEST_TIMEOUT_MSEC := 2500
const CONTROL_HTTP_MAX_REQUEST_BYTES := 65536
const WORLD_REGISTRY_PATH := "res://assets/pokeemerald/maps/world_registry.json"
const OBJECT_SPRITE_ROOT := "res://assets/pokeemerald/object_sprites"
const PLAYER_SPRITE_PATH := "res://assets/pokeemerald/object_sprites/player.png"
const PLAYER_FRAME_WIDTH := 16
const PLAYER_FACE_FRAMES := {
	"south": 0,
	"north": 1,
	"west": 2,
	"east": 2,
}
const PLAYER_WALK_FRAMES := {
	"south": [3, 0, 4, 0],
	"north": [5, 1, 6, 1],
	"west": [7, 2, 8, 2],
	"east": [7, 2, 8, 2],
}

@onready var map_sprite: Sprite2D = $LittlerootTownProbe
@onready var object_markers: Node2D = $ObjectMarkers
@onready var player_sprite: Sprite2D = $PlayerSprite
@onready var player_marker: ColorRect = $PlayerMarker
@onready var status_label: Label = $StatusLabel
@onready var interaction_label: Label = $InteractionLabel
@onready var message_label: Label = $MessageLabel

var world_registry: Dictionary = {}
var map_registry: Dictionary = {}
var manifests: Dictionary = {}
var current_map_name := "LittlerootTown"
var manifest: Dictionary = {}
var player_cell := Vector2i(10, 15)
var control_server := TCPServer.new()
var control_connections: Array[Dictionary] = []
var control_http_port := 0
var control_http_status := "control endpoint stopped"
var interact_key_was_down := false
var player_facing := "south"
var player_walk_phase := 0


func _ready() -> void:
	load_world_manifests()
	load_player_sprite()
	enter_map(current_map_name, player_cell, "ready")
	start_control_http()
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
	if interact_pressed():
		perform_facing_interaction()
	poll_control_http()


func interact_pressed() -> bool:
	var e_key_down := Input.is_key_pressed(KEY_E)
	var pressed := Input.is_action_just_pressed("ui_accept") or (e_key_down and not interact_key_was_down)
	interact_key_was_down = e_key_down
	return pressed


func load_world_manifests() -> void:
	load_world_registry()
	for map_name in map_registry.keys():
		var map_config: Dictionary = map_registry[map_name]
		var manifest_path := str(map_config["manifest_path"])
		var file := FileAccess.open(manifest_path, FileAccess.READ)
		if file == null:
			push_error("Could not open map manifest: %s" % manifest_path)
			continue

		var json := JSON.new()
		var error := json.parse(file.get_as_text())
		if error != OK:
			push_error("Could not parse map manifest %s: %s" % [manifest_path, json.get_error_message()])
			continue

		manifests[map_name] = json.get_data()


func load_world_registry() -> void:
	var file := FileAccess.open(WORLD_REGISTRY_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not open world registry: %s" % WORLD_REGISTRY_PATH)
		return

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK:
		push_error("Could not parse world registry %s: %s" % [WORLD_REGISTRY_PATH, json.get_error_message()])
		return

	world_registry = json.get_data()
	map_registry = world_registry.get("maps", {})
	var start_map := str(world_registry.get("start_map", current_map_name))
	if map_registry.has(start_map):
		current_map_name = start_map


func enter_map(map_name: String, cell: Vector2i, prefix := "entered") -> bool:
	if not manifests.has(map_name):
		update_status("missing map %s" % map_name)
		return false

	current_map_name = map_name
	manifest = manifests[map_name]

	var map_config: Dictionary = map_registry[map_name]
	var texture := load_map_texture(str(map_config["texture_path"]))
	if texture != null:
		map_sprite.texture = texture

	player_cell = cell
	if not is_cell_passable(player_cell):
		player_cell = nearest_passable_cell(player_cell)
	update_object_markers()
	update_player_marker()
	update_status("%s %s" % [prefix, current_map_name])
	return true


func load_map_texture(texture_path: String) -> Texture2D:
	if ResourceLoader.exists(texture_path):
		var resource := ResourceLoader.load(texture_path) as Texture2D
		if resource != null:
			return resource

	if FileAccess.file_exists(texture_path):
		var image := Image.new()
		var error := image.load(texture_path)
		if error == OK:
			return ImageTexture.create_from_image(image)

	push_warning("Could not load map texture: %s" % texture_path)
	return null


func load_player_sprite() -> void:
	var texture := load_map_texture(PLAYER_SPRITE_PATH)
	if texture == null:
		player_sprite.visible = false
		player_marker.visible = true
		return
	player_sprite.texture = texture
	player_sprite.hframes = int(max(1, texture.get_width() / PLAYER_FRAME_WIDTH))
	player_sprite.vframes = 1
	player_sprite.visible = true
	player_marker.visible = false
	update_player_sprite_frame(false)


func try_move(delta: Vector2i) -> bool:
	set_player_facing_from_delta(delta)
	var target := player_cell + delta
	if is_cell_passable(target):
		player_cell = target
		player_walk_phase += 1
		update_player_marker()
		update_player_sprite_frame(true)
		update_status("moved to %s" % cell_text(player_cell))
		return true

	if not is_cell_in_bounds(target):
		var crossed := try_cross_connection(delta, target)
		if crossed:
			player_walk_phase += 1
			update_player_sprite_frame(true)
		else:
			update_player_sprite_frame(false)
		return crossed

	update_player_sprite_frame(false)
	update_status("blocked at %s" % cell_text(target))
	return false


func move_direction(direction: String) -> Dictionary:
	var delta := direction_delta(direction)
	if delta == Vector2i.ZERO:
		return {
			"ok": false,
			"accepted": false,
			"message": "Unknown direction: %s" % direction,
			"state": state_snapshot(),
		}

	var target := player_cell + delta
	var accepted := try_move(delta)
	return {
		"ok": true,
		"accepted": accepted,
		"direction": direction,
		"target_cell": cell_to_dict(target),
		"state": state_snapshot(),
	}


func direction_delta(direction: String) -> Vector2i:
	match direction.strip_edges().to_lower():
		"north", "up":
			return Vector2i.UP
		"south", "down":
			return Vector2i.DOWN
		"west", "left":
			return Vector2i.LEFT
		"east", "right":
			return Vector2i.RIGHT
		_:
			return Vector2i.ZERO


func set_player_facing_from_delta(delta: Vector2i) -> void:
	var direction := direction_name(delta)
	if not direction.is_empty():
		player_facing = direction
		update_player_sprite_frame(false)


func direction_name(delta: Vector2i) -> String:
	if delta == Vector2i.UP:
		return "north"
	if delta == Vector2i.DOWN:
		return "south"
	if delta == Vector2i.LEFT:
		return "west"
	if delta == Vector2i.RIGHT:
		return "east"
	return ""


func facing_delta() -> Vector2i:
	return direction_delta(player_facing)


func connection_direction(delta: Vector2i) -> String:
	if delta == Vector2i.UP:
		return "up"
	if delta == Vector2i.DOWN:
		return "down"
	if delta == Vector2i.LEFT:
		return "left"
	if delta == Vector2i.RIGHT:
		return "right"
	return ""


func try_cross_connection(delta: Vector2i, target: Vector2i) -> bool:
	var direction := connection_direction(delta)
	var connection := find_connection(direction)
	if connection.is_empty():
		update_status("blocked at edge %s" % cell_text(target))
		return false

	var target_map := map_constant_to_world_name(str(connection.get("map", "")))
	if target_map.is_empty() or not manifests.has(target_map):
		update_status("unloaded connection %s" % str(connection.get("map", "")))
		return false

	var target_cell := connected_cell(target_map, direction, int(connection.get("offset", 0)), target)
	if not is_cell_passable_in(target_map, target_cell):
		update_status("blocked entering %s %s" % [target_map, cell_text(target_cell)])
		return false

	return enter_map(target_map, target_cell, "crossed %s to" % direction)


func find_connection(direction: String) -> Dictionary:
	for connection in manifest.get("connections", []):
		if str(connection.get("direction", "")) == direction:
			return connection
	return {}


func connected_cell(target_map: String, direction: String, offset: int, attempted_cell: Vector2i) -> Vector2i:
	var target_manifest: Dictionary = manifests[target_map]
	var width := int(target_manifest.get("width", 0))
	var height := int(target_manifest.get("height", 0))
	match direction:
		"up":
			return Vector2i(attempted_cell.x - offset, height - 1)
		"down":
			return Vector2i(attempted_cell.x - offset, 0)
		"left":
			return Vector2i(width - 1, attempted_cell.y - offset)
		"right":
			return Vector2i(0, attempted_cell.y - offset)
		_:
			return Vector2i(-1, -1)


func map_constant_to_world_name(map_constant: String) -> String:
	var constants: Dictionary = world_registry.get("map_constants", {})
	if constants.has(map_constant):
		return str(constants[map_constant])

	var normalized_constant := normalized_map_name(map_constant.trim_prefix("MAP_"))
	for map_name in manifests.keys():
		if normalized_map_name(str(map_name)) == normalized_constant:
			return str(map_name)
	return ""


func normalized_map_name(value: String) -> String:
	return value.to_lower().replace("_", "").replace(" ", "")


func is_cell_passable(cell: Vector2i) -> bool:
	var data := cell_data(cell)
	return not data.is_empty() and bool(data.get("passable", false))


func is_cell_passable_in(map_name: String, cell: Vector2i) -> bool:
	var data := cell_data_in(map_name, cell)
	return not data.is_empty() and bool(data.get("passable", false))


func is_cell_in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < int(manifest.get("width", 0)) and cell.y < int(manifest.get("height", 0))


func cell_data(cell: Vector2i) -> Dictionary:
	return cell_data_in(current_map_name, cell)


func cell_data_in(map_name: String, cell: Vector2i) -> Dictionary:
	if manifest.is_empty():
		return {}
	if not manifests.has(map_name):
		return {}
	var map_manifest: Dictionary = manifests[map_name]
	if cell.x < 0 or cell.y < 0:
		return {}
	if cell.x >= int(map_manifest.get("width", 0)) or cell.y >= int(map_manifest.get("height", 0)):
		return {}
	return map_manifest["cells"][cell.y][cell.x]


func first_passable_cell() -> Vector2i:
	for y in range(int(manifest.get("height", 0))):
		for x in range(int(manifest.get("width", 0))):
			var candidate := Vector2i(x, y)
			if is_cell_passable(candidate):
				return candidate
	return Vector2i.ZERO


func nearest_passable_cell(origin: Vector2i) -> Vector2i:
	if is_cell_passable(origin):
		return origin
	var best_cell := first_passable_cell()
	var best_distance := 1000000
	for y in range(int(manifest.get("height", 0))):
		for x in range(int(manifest.get("width", 0))):
			var candidate := Vector2i(x, y)
			if not is_cell_passable(candidate):
				continue
			var distance: int = abs(candidate.x - origin.x) + abs(candidate.y - origin.y)
			if distance < best_distance:
				best_distance = distance
				best_cell = candidate
	return best_cell


func update_player_marker() -> void:
	var scale_factor := map_sprite.scale.x
	var marker_size := Vector2(TILE_SIZE, TILE_SIZE) * scale_factor
	player_marker.size = marker_size
	player_marker.position = map_sprite.position + Vector2(player_cell * TILE_SIZE) * scale_factor
	if player_sprite.texture != null:
		player_sprite.scale = map_sprite.scale
		player_sprite.position = player_sprite_position()


func update_player_sprite_frame(walking: bool) -> void:
	if player_sprite == null or player_sprite.texture == null:
		return

	var frames: Array = PLAYER_WALK_FRAMES.get(player_facing, [])
	if walking and not frames.is_empty():
		player_sprite.frame = int(frames[player_walk_phase % frames.size()])
	else:
		player_sprite.frame = int(PLAYER_FACE_FRAMES.get(player_facing, 0))
	player_sprite.flip_h = player_facing == "east"


func player_sprite_position() -> Vector2:
	if player_sprite.texture == null:
		return Vector2.ZERO
	var scale_factor: float = map_sprite.scale.x
	var source_size := Vector2(PLAYER_FRAME_WIDTH, player_sprite.texture.get_height())
	var local_position := Vector2(player_cell * TILE_SIZE)
	local_position.x += (TILE_SIZE - source_size.x) / 2.0
	local_position.y += TILE_SIZE - source_size.y
	return map_sprite.position + local_position * scale_factor


func update_object_markers() -> void:
	for child in object_markers.get_children():
		child.free()

	var scale_factor: float = map_sprite.scale.x
	var marker_size: Vector2 = Vector2(TILE_SIZE, TILE_SIZE) * scale_factor
	var inset: float = maxf(3.0, 3.0 * scale_factor)
	for landmark in manifest.get("landmarks", []):
		if str(landmark.get("kind", "")) != "object":
			continue
		for raw_cell in landmark.get("cells", []):
			var cell := Vector2i(int(raw_cell.get("x", 0)), int(raw_cell.get("y", 0)))
			var sprite_texture := object_sprite_texture(landmark)
			if sprite_texture != null:
				var sprite := Sprite2D.new()
				sprite.name = str(landmark.get("id", "object"))
				sprite.centered = false
				sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				sprite.texture = sprite_texture
				sprite.scale = map_sprite.scale
				sprite.position = object_sprite_position(cell, sprite_texture)
				object_markers.add_child(sprite)
			else:
				var marker := ColorRect.new()
				marker.name = str(landmark.get("id", "object"))
				marker.color = object_marker_color(landmark)
				marker.size = marker_size - Vector2(inset * 2.0, inset * 2.0)
				marker.position = map_sprite.position + Vector2(cell * TILE_SIZE) * scale_factor + Vector2(inset, inset)
				object_markers.add_child(marker)


func object_sprite_position(cell: Vector2i, texture: Texture2D) -> Vector2:
	var scale_factor: float = map_sprite.scale.x
	var source_size := Vector2(texture.get_width(), texture.get_height())
	var local_position := Vector2(cell * TILE_SIZE)
	local_position.x += (TILE_SIZE - source_size.x) / 2.0
	local_position.y += TILE_SIZE - source_size.y
	return map_sprite.position + local_position * scale_factor


func object_sprite_texture(landmark: Dictionary) -> Texture2D:
	var path := object_sprite_path(str(landmark.get("graphics_id", "")))
	if path.is_empty():
		return null
	return load_map_texture(path)


func object_sprite_path(graphics_id: String) -> String:
	if graphics_id.is_empty() or not graphics_id.begins_with("OBJ_EVENT_GFX_"):
		return ""
	var slug := graphics_id.trim_prefix("OBJ_EVENT_GFX_").to_lower()
	var path := "%s/%s.png" % [OBJECT_SPRITE_ROOT, slug]
	if ResourceLoader.exists(path) or FileAccess.file_exists(path):
		return path
	return ""


func object_marker_color(landmark: Dictionary) -> Color:
	if str(landmark.get("script", "")) == "0x0":
		return Color(0.48, 0.52, 0.58, 0.7)
	if landmark.has("text"):
		return Color(0.16, 0.45, 1.0, 0.88)
	return Color(0.32, 0.76, 0.46, 0.82)


func update_status(prefix: String) -> void:
	var data := cell_data(player_cell)
	status_label.text = "%s\nmap %s\ncell %s\ncollision %d | elevation %d\nmetatile %d\n%s" % [
		prefix,
		current_map_name,
		cell_text(player_cell),
		int(data.get("collision", -1)),
		int(data.get("elevation", -1)),
		int(data.get("metatile_id", -1)),
		control_http_status,
	]
	update_interaction_prompt()


func update_interaction_prompt() -> void:
	var nearest := nearest_interaction()
	if nearest.is_empty():
		interaction_label.text = "Nearby: none"
		return

	var action := str(nearest.get("action", "use")).capitalize()
	interaction_label.text = "Nearby: %s %s" % [action, str(nearest.get("name", ""))]


func cell_text(cell: Vector2i) -> String:
	return "(%d,%d)" % [cell.x, cell.y]


func cell_to_dict(cell: Vector2i) -> Dictionary:
	return {"x": cell.x, "y": cell.y}


func state_snapshot() -> Dictionary:
	var cell := cell_data(player_cell)
	var directions := {
		"north": player_cell + Vector2i.UP,
		"south": player_cell + Vector2i.DOWN,
		"west": player_cell + Vector2i.LEFT,
		"east": player_cell + Vector2i.RIGHT,
	}
	var passable_directions := []
	var blocked_directions := []
	for direction in directions.keys():
		if can_move_direction(str(direction), directions[direction]):
			passable_directions.append(direction)
		else:
			blocked_directions.append(direction)

	return {
		"ok": true,
		"map": current_map_name,
		"world": {
			"map_count": int(world_registry.get("map_count", map_registry.size())),
			"loaded_maps": map_registry.keys(),
		},
		"dimensions": {
			"width": int(manifest.get("width", 0)),
			"height": int(manifest.get("height", 0)),
		},
		"cell": cell_to_dict(player_cell),
		"facing": player_facing,
		"facing_cell": cell_to_dict(player_cell + facing_delta()),
		"collision": int(cell.get("collision", -1)),
		"elevation": int(cell.get("elevation", -1)),
		"metatile_id": int(cell.get("metatile_id", -1)),
		"passable_directions": passable_directions,
		"blocked_directions": blocked_directions,
		"connections": connection_summaries(),
		"warps_here": warps_at_cell(player_cell),
		"place": place_snapshot(),
		"available_interactions": available_interactions(),
		"nearby_semantic_cells": nearby_semantic_cells(),
		"control": {
			"host": CONTROL_HTTP_HOST,
			"port": control_http_port,
			"base_url": control_base_url(),
		},
	}


func can_move_direction(direction: String, target: Vector2i) -> bool:
	if is_cell_passable(target):
		return true
	if is_cell_in_bounds(target):
		return false

	var connection := find_connection(control_direction_to_connection_direction(direction))
	if connection.is_empty():
		return false
	var target_map := map_constant_to_world_name(str(connection.get("map", "")))
	if target_map.is_empty() or not manifests.has(target_map):
		return false
	return is_cell_passable_in(
		target_map,
		connected_cell(target_map, control_direction_to_connection_direction(direction), int(connection.get("offset", 0)), target)
	)


func control_direction_to_connection_direction(direction: String) -> String:
	match direction:
		"north":
			return "up"
		"south":
			return "down"
		"west":
			return "left"
		"east":
			return "right"
		_:
			return direction


func connection_summaries() -> Array:
	var summaries := []
	for connection in manifest.get("connections", []):
		var raw_map := str(connection.get("map", ""))
		var world_name := map_constant_to_world_name(raw_map)
		summaries.append({
			"direction": str(connection.get("direction", "")),
			"raw_map": raw_map,
			"map": world_name,
			"loaded": not world_name.is_empty() and manifests.has(world_name),
			"offset": int(connection.get("offset", 0)),
		})
	return summaries


func map_summaries() -> Array:
	var summaries := []
	for map_name in map_registry.keys():
		var config: Dictionary = map_registry[map_name]
		summaries.append({
			"map": str(map_name),
			"width": int(config.get("width", 0)),
			"height": int(config.get("height", 0)),
			"layout": str(config.get("layout", "")),
			"connections": config.get("connections", []),
			"warp_count": int(config.get("warp_count", 0)),
			"landmark_count": int(config.get("landmark_count", 0)),
		})
	return summaries


func place_snapshot() -> Dictionary:
	return {
		"here": landmarks_near(player_cell, 0),
		"nearby": landmarks_near(player_cell, 4),
	}


func look_snapshot(radius := 4) -> Dictionary:
	return {
		"ok": true,
		"map": current_map_name,
		"cell": cell_to_dict(player_cell),
		"cell_data": cell_data(player_cell),
		"here": landmarks_near(player_cell, 0),
		"nearby_landmarks": landmarks_near(player_cell, radius),
		"available_interactions": available_interactions(),
		"connections": connection_summaries(),
		"warps_here": warps_at_cell(player_cell),
	}


func landmarks_near(cell: Vector2i, radius: int) -> Array:
	var result := []
	for landmark in manifest.get("landmarks", []):
		var distance := landmark_distance(cell, landmark)
		if distance <= radius:
			var copy: Dictionary = landmark.duplicate(true)
			copy["distance"] = distance
			result.append(copy)
	return result


func landmark_distance(cell: Vector2i, landmark: Dictionary) -> int:
	var best_distance := 1000000
	for raw_cell in landmark.get("cells", []):
		var landmark_cell := Vector2i(int(raw_cell.get("x", 0)), int(raw_cell.get("y", 0)))
		var distance: int = abs(cell.x - landmark_cell.x) + abs(cell.y - landmark_cell.y)
		if distance < best_distance:
			best_distance = distance
	return best_distance


func available_interactions(range := 1) -> Array:
	var interactions := []
	for landmark in manifest.get("landmarks", []):
		var distance := landmark_distance(player_cell, landmark)
		if distance > range:
			continue
		var kind := str(landmark.get("kind", ""))
		if kind != "sign" and kind != "doorway" and kind != "object":
			continue
		if kind == "object" and not object_is_talkable(landmark):
			continue
		var action := "talk"
		if kind == "sign":
			action = "read"
		elif kind == "doorway":
			action = "enter"
		interactions.append({
			"target_id": str(landmark.get("id", "")),
			"kind": kind,
			"action": action,
			"name": str(landmark.get("name", "")),
			"distance": distance,
			"in_front": landmark_distance(player_cell + facing_delta(), landmark) == 0,
		})
	return interactions


func object_is_talkable(landmark: Dictionary) -> bool:
	return str(landmark.get("text", "")).strip_edges() != ""


func nearest_interaction() -> Dictionary:
	var interactions := available_interactions()
	var nearest := {}
	var nearest_distance := 1000000
	for interaction in interactions:
		var distance := int(interaction.get("distance", 1000000))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = interaction
	return nearest


func facing_interaction() -> Dictionary:
	for interaction in available_interactions():
		if bool(interaction.get("in_front", false)):
			return interaction
	return {}


func perform_facing_interaction() -> Dictionary:
	var front := facing_interaction()
	if front.is_empty():
		return perform_nearest_interaction()

	var result := interact_with_target(str(front.get("target_id", "")))
	show_interaction_result(result)
	return result


func perform_nearest_interaction() -> Dictionary:
	var nearest := nearest_interaction()
	if nearest.is_empty():
		var result := {
			"ok": true,
			"accepted": false,
			"message": "There is nothing to interact with nearby.",
			"available_interactions": available_interactions(),
		}
		show_interaction_result(result)
		return result

	var result := interact_with_target(str(nearest.get("target_id", "")))
	show_interaction_result(result)
	return result


func show_interaction_result(result: Dictionary) -> void:
	if not bool(result.get("accepted", false)):
		message_label.text = str(result.get("message", ""))
		update_interaction_prompt()
		return

	match str(result.get("kind", "")):
		"sign":
			message_label.text = "%s:\n%s" % [
				str(result.get("name", "Sign")),
				str(result.get("text", "")),
			]
		"object":
			message_label.text = "%s says:\n%s" % [
				str(result.get("name", "Someone")),
				str(result.get("text", result.get("message", ""))),
			]
		"doorway":
			if str(result.get("result_type", "")) == "entered_loaded_doorway":
				message_label.text = "Entered %s." % str(result.get("target_map", ""))
			else:
				message_label.text = str(result.get("message", "Doorway target is not loaded yet."))
		_:
			message_label.text = str(result.get("message", ""))
	update_interaction_prompt()


func interact_with_target(target_id: String) -> Dictionary:
	var landmark := find_landmark(target_id)
	if landmark.is_empty():
		return {
			"ok": false,
			"accepted": false,
			"message": "Unknown interaction target: %s" % target_id,
			"available_interactions": available_interactions(),
		}

	var distance := landmark_distance(player_cell, landmark)
	if distance > 1:
		return {
			"ok": true,
			"accepted": false,
			"target_id": target_id,
			"message": "Target is too far away.",
			"distance": distance,
			"available_interactions": available_interactions(),
		}

	var kind := str(landmark.get("kind", ""))
	match kind:
		"sign":
			return interact_with_sign(landmark, distance)
		"object":
			return interact_with_object(landmark, distance)
		"doorway":
			return interact_with_doorway(landmark, distance)
		_:
			return {
				"ok": true,
				"accepted": false,
				"target_id": target_id,
				"kind": kind,
				"message": "Target is not interactive yet.",
				"distance": distance,
			}


func interact_with_sign(landmark: Dictionary, distance: int) -> Dictionary:
	return {
		"ok": true,
		"accepted": true,
		"target_id": str(landmark.get("id", "")),
		"kind": "sign",
		"action": "read",
		"name": str(landmark.get("name", "")),
		"distance": distance,
		"text": sign_text_placeholder(landmark),
		"text_symbol": str(landmark.get("text_symbol", "")),
		"script": str(landmark.get("script", "")),
	}


func interact_with_object(landmark: Dictionary, distance: int) -> Dictionary:
	var text := str(landmark.get("text", ""))
	if text.is_empty():
		return {
			"ok": true,
			"accepted": false,
			"target_id": str(landmark.get("id", "")),
			"kind": "object",
			"name": str(landmark.get("name", "")),
			"distance": distance,
			"message": "%s is visible but not talkable yet." % str(landmark.get("name", "Object")),
		}
	return {
		"ok": true,
		"accepted": true,
		"target_id": str(landmark.get("id", "")),
		"kind": "object",
		"action": "talk",
		"name": str(landmark.get("name", "")),
		"distance": distance,
		"text": text,
		"text_symbol": str(landmark.get("text_symbol", "")),
		"script": str(landmark.get("script", "")),
	}


func interact_with_doorway(landmark: Dictionary, distance: int) -> Dictionary:
	var raw_target := str(landmark.get("target_map_raw", ""))
	var target_map := map_constant_to_world_name(raw_target)
	var target_loaded := not target_map.is_empty() and manifests.has(target_map)
	if target_loaded:
		var target_cell := target_warp_cell(target_map, int(landmark.get("dest_warp_id", 0)))
		enter_map(target_map, target_cell, "entered doorway to")
		return {
			"ok": true,
			"accepted": true,
			"target_id": str(landmark.get("id", "")),
			"kind": "doorway",
			"action": "enter",
			"name": str(landmark.get("name", "")),
			"distance": distance,
			"target_map_raw": raw_target,
			"target_map": target_map,
			"target_loaded": true,
			"target_cell": cell_to_dict(target_cell),
			"result_type": "entered_loaded_doorway",
			"state": state_snapshot(),
		}

	return {
		"ok": true,
		"accepted": true,
		"target_id": str(landmark.get("id", "")),
		"kind": "doorway",
		"action": "enter",
		"name": str(landmark.get("name", "")),
		"distance": distance,
		"target_map_raw": raw_target,
		"target_map": target_map,
		"target_loaded": false,
		"result_type": "doorway_target_unloaded",
		"message": "Doorway target is not loaded yet.",
	}


func target_warp_cell(target_map: String, warp_id: int) -> Vector2i:
	var target_manifest: Dictionary = manifests[target_map]
	var warps: Array = target_manifest.get("warp_events", [])
	if warp_id >= 0 and warp_id < warps.size():
		var warp: Dictionary = warps[warp_id]
		return Vector2i(int(warp.get("x", 0)), int(warp.get("y", 0)))
	return Vector2i.ZERO


func sign_text_placeholder(landmark: Dictionary) -> String:
	if landmark.has("text"):
		return str(landmark["text"])
	var script := str(landmark.get("script", ""))
	if script.is_empty():
		return str(landmark.get("name", "Sign"))
	return "Sign script: %s" % script


func find_landmark(target_id: String) -> Dictionary:
	for landmark in manifest.get("landmarks", []):
		if str(landmark.get("id", "")) == target_id:
			return landmark
	return {}


func warps_at_cell(cell: Vector2i) -> Array:
	var warps := []
	for warp in manifest.get("warp_events", []):
		if int(warp.get("x", -1)) == cell.x and int(warp.get("y", -1)) == cell.y:
			warps.append(warp)
	return warps


func nearby_semantic_cells() -> Dictionary:
	var cells := {
		"here": player_cell,
		"north": player_cell + Vector2i.UP,
		"south": player_cell + Vector2i.DOWN,
		"west": player_cell + Vector2i.LEFT,
		"east": player_cell + Vector2i.RIGHT,
	}
	var result := {}
	for key in cells.keys():
		var cell: Vector2i = cells[key]
		var data := cell_data(cell)
		if data.is_empty():
			result[key] = {"cell": cell_to_dict(cell), "in_bounds": false}
		else:
			result[key] = {
				"cell": cell_to_dict(cell),
				"in_bounds": true,
				"collision": int(data.get("collision", -1)),
				"elevation": int(data.get("elevation", -1)),
				"metatile_id": int(data.get("metatile_id", -1)),
				"behavior": data.get("behavior", null),
				"passable": bool(data.get("passable", false)),
			}
	return result


func control_base_url() -> String:
	if control_http_port <= 0:
		return ""
	return "http://%s:%d" % [CONTROL_HTTP_HOST, control_http_port]


func start_control_http() -> void:
	var preferred_port := int(OS.get_environment("TILEGROVE_CONTROL_PORT"))
	if preferred_port <= 0:
		preferred_port = CONTROL_HTTP_PORT

	var exact_port := not OS.get_environment("TILEGROVE_CONTROL_PORT").strip_edges().is_empty()
	var ports_to_try := 1 if exact_port else CONTROL_HTTP_PORT_SCAN_COUNT
	for offset in range(ports_to_try):
		var candidate_port := preferred_port + offset
		var error := control_server.listen(candidate_port, CONTROL_HTTP_HOST)
		if error == OK:
			control_http_port = candidate_port
			control_http_status = "control at %s" % control_base_url()
			return

	control_http_status = "control failed on %s:%d" % [CONTROL_HTTP_HOST, preferred_port]
	push_warning(control_http_status)


func poll_control_http() -> void:
	if control_server.is_listening():
		while control_server.is_connection_available():
			var peer := control_server.take_connection()
			control_connections.append({
				"peer": peer,
				"buffer": "",
				"started_msec": Time.get_ticks_msec(),
			})

	var finished: Array[Dictionary] = []
	for connection in control_connections:
		var peer: StreamPeerTCP = connection["peer"]
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			finished.append(connection)
			continue

		var available := peer.get_available_bytes()
		if available > 0:
			connection["buffer"] = str(connection["buffer"]) + peer.get_utf8_string(available)

		var request_text := str(connection["buffer"])
		if request_text.to_utf8_buffer().size() > CONTROL_HTTP_MAX_REQUEST_BYTES:
			send_control_json(peer, 413, {"ok": false, "message": "Tilegrove control request is too large."})
			peer.disconnect_from_host()
			finished.append(connection)
		elif control_request_complete(request_text):
			handle_control_request(peer, request_text)
			peer.disconnect_from_host()
			finished.append(connection)
		elif Time.get_ticks_msec() - int(connection["started_msec"]) >= CONTROL_HTTP_REQUEST_TIMEOUT_MSEC:
			send_control_json(peer, 408, {"ok": false, "message": "Tilegrove control request timed out."})
			peer.disconnect_from_host()
			finished.append(connection)

	for connection in finished:
		control_connections.erase(connection)


func control_request_complete(request_text: String) -> bool:
	var header_end := request_text.find("\r\n\r\n")
	if header_end == -1:
		return false

	var content_length := 0
	var headers := request_text.substr(0, header_end).split("\r\n")
	for header in headers:
		var separator := str(header).find(":")
		if separator == -1:
			continue
		if str(header).substr(0, separator).strip_edges().to_lower() == "content-length":
			content_length = int(str(header).substr(separator + 1).strip_edges())
			break

	var body := request_text.substr(header_end + 4)
	return body.to_utf8_buffer().size() >= content_length


func handle_control_request(peer: StreamPeerTCP, request_text: String) -> void:
	var request := parse_control_request(request_text)
	var method: String = request["method"]
	var path: String = request["path"]
	var query: Dictionary = request["query"]

	if method == "OPTIONS":
		send_control_bytes(peer, 204, "text/plain; charset=utf-8", PackedByteArray())
		return

	match path:
		"/", "/help":
			send_control_json(peer, 200, {
				"ok": true,
				"name": "Tilegrove control loopback",
				"base_url": control_base_url(),
				"endpoints": {
					"GET /state": "Return current player cell and blocked/passable directions.",
					"GET /maps": "Return loaded world maps and their connection summaries.",
					"GET /look": "Return landmarks, exits, and semantic map features near the player.",
					"GET /interactions": "Return sign and doorway interactions currently in range.",
					"POST /interact": "Interact with JSON body like {\"target_id\":\"sign_0_15_13\"}.",
					"POST /move": "Move with JSON body like {\"direction\":\"east\"}.",
					"GET /move?direction=east": "Move using a query string direction.",
				},
			})
		"/maps":
			if method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use GET /maps."})
			else:
				send_control_json(peer, 200, {
					"ok": true,
					"map_count": int(world_registry.get("map_count", map_registry.size())),
					"start_map": str(world_registry.get("start_map", "")),
					"maps": map_summaries(),
				})
		"/look":
			if method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use GET /look."})
			else:
				send_control_json(peer, 200, look_snapshot(int(query.get("radius", 4))))
		"/interactions":
			if method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use GET /interactions."})
			else:
				send_control_json(peer, 200, {
					"ok": true,
					"map": current_map_name,
					"cell": cell_to_dict(player_cell),
					"available_interactions": available_interactions(),
				})
		"/interact":
			if method != "POST" and method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use POST /interact or GET /interact?target_id=..."})
			else:
				send_control_json(peer, 200, control_interact(request["body"], query))
		"/state":
			if method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use GET /state."})
			else:
				send_control_json(peer, 200, state_snapshot())
		"/move":
			if method != "POST" and method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use POST /move or GET /move?direction=east."})
			else:
				send_control_json(peer, 200, control_move(request["body"], query))
		_:
			if path.begins_with("/move/"):
				send_control_json(peer, 200, move_direction(path.trim_prefix("/move/")))
			elif path.begins_with("/interact/"):
				send_control_json(peer, 200, interact_with_target(path.trim_prefix("/interact/")))
			else:
				send_control_json(peer, 404, {"ok": false, "message": "Unknown Tilegrove control endpoint. Try GET /help."})


func control_move(body: String, query: Dictionary) -> Dictionary:
	var direction := str(query.get("direction", query.get("dir", "")))
	if direction.is_empty() and not body.strip_edges().is_empty():
		var parsed := parse_json_body(body)
		if not bool(parsed.get("ok", true)):
			return parsed
		direction = str(parsed.get("direction", parsed.get("dir", "")))
	if direction.is_empty():
		return {
			"ok": false,
			"accepted": false,
			"message": "Missing direction. Use north/south/east/west or up/down/left/right.",
			"state": state_snapshot(),
		}
	return move_direction(direction)


func control_interact(body: String, query: Dictionary) -> Dictionary:
	var target_id := str(query.get("target_id", query.get("target", "")))
	if target_id.is_empty() and not body.strip_edges().is_empty():
		var parsed := parse_json_body(body)
		if not bool(parsed.get("ok", true)):
			return parsed
		target_id = str(parsed.get("target_id", parsed.get("target", "")))
	if target_id.is_empty():
		return {
			"ok": false,
			"accepted": false,
			"message": "Missing target_id.",
			"available_interactions": available_interactions(),
		}
	return interact_with_target(target_id)


func parse_json_body(body: String) -> Dictionary:
	var json := JSON.new()
	var error := json.parse(body)
	if error != OK:
		return {"ok": false, "message": "Invalid JSON body: %s" % json.get_error_message()}
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "message": "JSON body must be an object."}
	return data


func parse_control_request(request_text: String) -> Dictionary:
	var header_end := request_text.find("\r\n\r\n")
	var head := request_text.substr(0, header_end)
	var body := request_text.substr(header_end + 4)
	var lines := head.split("\r\n")
	var request_line := str(lines[0]).split(" ")
	var method := "GET"
	var raw_path := "/"
	if request_line.size() >= 2:
		method = str(request_line[0]).to_upper()
		raw_path = str(request_line[1])

	var path := raw_path
	var query := {}
	var query_start := raw_path.find("?")
	if query_start != -1:
		path = raw_path.substr(0, query_start)
		query = parse_control_query(raw_path.substr(query_start + 1))

	return {
		"method": method,
		"path": path,
		"query": query,
		"body": body,
	}


func parse_control_query(query_text: String) -> Dictionary:
	var query := {}
	if query_text.is_empty():
		return query

	for part in query_text.split("&", false):
		var separator := str(part).find("=")
		if separator == -1:
			query[str(part).uri_decode()] = ""
		else:
			var key := str(part).substr(0, separator).uri_decode()
			var value := str(part).substr(separator + 1).uri_decode()
			query[key] = value
	return query


func send_control_json(peer: StreamPeerTCP, status_code: int, data: Dictionary) -> void:
	send_control_bytes(peer, status_code, "application/json; charset=utf-8", JSON.stringify(data, "\t").to_utf8_buffer())


func send_control_bytes(peer: StreamPeerTCP, status_code: int, content_type: String, body: PackedByteArray) -> void:
	var reason := "OK"
	match status_code:
		204:
			reason = "No Content"
		404:
			reason = "Not Found"
		405:
			reason = "Method Not Allowed"
		408:
			reason = "Request Timeout"
		413:
			reason = "Payload Too Large"
		_:
			reason = "OK"
	var header_text := "\r\n".join([
		"HTTP/1.1 %d %s" % [status_code, reason],
		"Content-Type: %s" % content_type,
		"Content-Length: %d" % body.size(),
		"Access-Control-Allow-Origin: *",
		"Access-Control-Allow-Methods: GET, POST, OPTIONS",
		"Access-Control-Allow-Headers: Content-Type",
		"Connection: close",
		"",
		"",
	])
	var response := PackedByteArray()
	response.append_array(header_text.to_utf8_buffer())
	response.append_array(body)
	peer.put_data(response)
