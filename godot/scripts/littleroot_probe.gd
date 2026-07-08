extends Node2D

const MANIFEST_PATH := "res://assets/pokeemerald/maps/littleroot_town.json"
const TILE_SIZE := 16
const CONTROL_HTTP_HOST := "127.0.0.1"
const CONTROL_HTTP_PORT := 38473
const CONTROL_HTTP_PORT_SCAN_COUNT := 16
const CONTROL_HTTP_REQUEST_TIMEOUT_MSEC := 2500
const CONTROL_HTTP_MAX_REQUEST_BYTES := 65536

@onready var map_sprite: Sprite2D = $LittlerootTownProbe
@onready var player_marker: ColorRect = $PlayerMarker
@onready var status_label: Label = $StatusLabel

var manifest: Dictionary = {}
var player_cell := Vector2i(10, 15)
var control_server := TCPServer.new()
var control_connections: Array[Dictionary] = []
var control_http_port := 0
var control_http_status := "control endpoint stopped"


func _ready() -> void:
	load_manifest()
	if not is_cell_passable(player_cell):
		player_cell = first_passable_cell()
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
	status_label.text = "%s\ncell %s\ncollision %d | elevation %d\nmetatile %d\n%s" % [
		prefix,
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
		if is_cell_passable(directions[direction]):
			passable_directions.append(direction)
		else:
			blocked_directions.append(direction)

	return {
		"ok": true,
		"map": manifest.get("map", "unknown"),
		"cell": cell_to_dict(player_cell),
		"collision": int(cell.get("collision", -1)),
		"elevation": int(cell.get("elevation", -1)),
		"metatile_id": int(cell.get("metatile_id", -1)),
		"passable_directions": passable_directions,
		"blocked_directions": blocked_directions,
		"control": {
			"host": CONTROL_HTTP_HOST,
			"port": control_http_port,
			"base_url": control_base_url(),
		},
	}


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
