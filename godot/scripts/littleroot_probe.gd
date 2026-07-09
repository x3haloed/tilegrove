extends Node2D

const TILE_SIZE := 16
const CONTROL_HTTP_HOST := "127.0.0.1"
const CONTROL_HTTP_PORT := 38473
const CONTROL_HTTP_PORT_SCAN_COUNT := 16
const CONTROL_HTTP_REQUEST_TIMEOUT_MSEC := 2500
const CONTROL_HTTP_MAX_REQUEST_BYTES := 65536
const MAPS := {
	"LittlerootTown": {
		"manifest_path": "res://assets/pokeemerald/maps/littleroot_town.json",
		"texture_path": "res://assets/pokeemerald/maps/littleroot_town.png",
	},
	"Route101": {
		"manifest_path": "res://assets/pokeemerald/maps/route101.json",
		"texture_path": "res://assets/pokeemerald/maps/route101.png",
	},
}

@onready var map_sprite: Sprite2D = $LittlerootTownProbe
@onready var player_marker: ColorRect = $PlayerMarker
@onready var status_label: Label = $StatusLabel

var manifests: Dictionary = {}
var current_map_name := "LittlerootTown"
var manifest: Dictionary = {}
var player_cell := Vector2i(10, 15)
var control_server := TCPServer.new()
var control_connections: Array[Dictionary] = []
var control_http_port := 0
var control_http_status := "control endpoint stopped"


func _ready() -> void:
	load_world_manifests()
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
	poll_control_http()


func load_world_manifests() -> void:
	for map_name in MAPS.keys():
		var map_config: Dictionary = MAPS[map_name]
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


func enter_map(map_name: String, cell: Vector2i, prefix := "entered") -> bool:
	if not manifests.has(map_name):
		update_status("missing map %s" % map_name)
		return false

	current_map_name = map_name
	manifest = manifests[map_name]

	var map_config: Dictionary = MAPS[map_name]
	var texture := load_map_texture(str(map_config["texture_path"]))
	if texture != null:
		map_sprite.texture = texture

	player_cell = cell
	if not is_cell_passable(player_cell):
		player_cell = nearest_passable_cell(player_cell)
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


func try_move(delta: Vector2i) -> bool:
	var target := player_cell + delta
	if is_cell_passable(target):
		player_cell = target
		update_player_marker()
		update_status("moved to %s" % cell_text(player_cell))
		return true

	if not is_cell_in_bounds(target):
		return try_cross_connection(delta, target)

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
			return Vector2i(attempted_cell.x + offset, height - 1)
		"down":
			return Vector2i(attempted_cell.x + offset, 0)
		"left":
			return Vector2i(width - 1, attempted_cell.y + offset)
		"right":
			return Vector2i(0, attempted_cell.y + offset)
		_:
			return Vector2i(-1, -1)


func map_constant_to_world_name(map_constant: String) -> String:
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
		"dimensions": {
			"width": int(manifest.get("width", 0)),
			"height": int(manifest.get("height", 0)),
		},
		"cell": cell_to_dict(player_cell),
		"collision": int(cell.get("collision", -1)),
		"elevation": int(cell.get("elevation", -1)),
		"metatile_id": int(cell.get("metatile_id", -1)),
		"passable_directions": passable_directions,
		"blocked_directions": blocked_directions,
		"connections": connection_summaries(),
		"warps_here": warps_at_cell(player_cell),
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
					"POST /move": "Move with JSON body like {\"direction\":\"east\"}.",
					"GET /move?direction=east": "Move using a query string direction.",
				},
			})
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
