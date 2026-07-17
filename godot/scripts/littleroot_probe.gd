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
const CONNECTION_CONFIG_PATH := "user://tilegrove-connection.cfg"
const UI_SCALE_MIN := 1.0
const UI_SCALE_MAX := 2.0
const UI_SCALE_DEFAULT := 1.0
const PLAYER_STEP_DURATION_SECONDS := 0.16
const OBJECT_STEP_DURATION_SECONDS := 0.32
const OBJECT_IDLE_SECONDS := 1.0
const SSE_NPC_MOTION_SECONDS := 3.0
const SSE_AMBIENT_SECONDS := 10.0
const SSE_SILENCE_SECONDS := 3600.0
const NEARBY_PLAYER_NAME_RADIUS := 7
const PLAYER_GESTURE_VISIBLE_MSEC := 2200
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
@onready var world_traces: Node2D = $WorldTraces
@onready var other_players: Node2D = $OtherPlayers
@onready var player_sprite: Sprite2D = $PlayerSprite
@onready var player_marker: ColorRect = $PlayerMarker
@onready var status_label: Label = $StatusLabel
@onready var interaction_label: Label = $InteractionLabel
@onready var message_label: Label = $MessageLabel
@onready var chat_log: RichTextLabel = $ChatLog
@onready var chat_input: LineEdit = $ChatInput
@onready var connection_button: Button = $ConnectionButton
@onready var connection_layer: CanvasLayer = $ConnectionLayer
@onready var connection_profile: LineEdit = $ConnectionLayer/Panel/Margin/Fields/Profile
@onready var connection_display_name: LineEdit = $ConnectionLayer/Panel/Margin/Fields/DisplayName
@onready var connection_uri: LineEdit = $ConnectionLayer/Panel/Margin/Fields/Uri
@onready var connection_database: LineEdit = $ConnectionLayer/Panel/Margin/Fields/Database
@onready var connection_status: Label = $ConnectionLayer/Panel/Margin/Fields/ConnectionStatus
@onready var connection_cancel: Button = $ConnectionLayer/Panel/Margin/Fields/Actions/Cancel
@onready var connection_connect: Button = $ConnectionLayer/Panel/Margin/Fields/Actions/Connect
@onready var settings_button: Button = $SettingsButton
@onready var settings_layer: CanvasLayer = $SettingsLayer
@onready var settings_scale: HSlider = $SettingsLayer/Panel/Margin/Fields/ScaleRow/Slider
@onready var settings_scale_value: Label = $SettingsLayer/Panel/Margin/Fields/ScaleRow/Value
@onready var settings_close: Button = $SettingsLayer/Panel/Margin/Fields/Close

var world_registry: Dictionary = {}
var map_registry: Dictionary = {}
var manifests: Dictionary = {}
var manifest_jsons: Dictionary = {}
var current_map_name := "LittlerootTown"
var manifest: Dictionary = {}
var player_cell := Vector2i(10, 15)
var control_server := TCPServer.new()
var control_connections: Array[Dictionary] = []
var control_http_port := 0
var control_http_status := "control endpoint stopped"
var interact_key_was_down := false
var gesture_key_was_down := false
var player_facing := "south"
var player_is_stepping := false
var player_step_elapsed := 0.0
var player_visual_cell_from := Vector2i(10, 15)
var player_visual_cell_to := Vector2i(10, 15)
var object_states: Dictionary = {}
var sse_connections: Array[Dictionary] = []
var sse_npc_motion_buffer: Array[Dictionary] = []
var sse_npc_motion_elapsed := 0.0
var sse_ambient_elapsed := 0.0
var sse_silence_elapsed := 0.0
var spacetime = null
var spacetime_enabled := false
var spacetime_join_sent := false
var spacetime_ready := false
var spacetime_seed_queue: Array[String] = []
var spacetime_revision := -1
var smoke_move_sent := false
var smoke_chat_sent := false
var smoke_chat_frames := 0
var smoke_start_revision := -1
var player_display_name := "Player"
var human_connection_mode := false
var connection_pending := false
var ui_scale := UI_SCALE_DEFAULT
var observed_players: Dictionary = {}
var player_gesture_seen: Dictionary = {}
var player_gesture_until: Dictionary = {}
var chat_sequence := 0
var chat_bubbles: Dictionary = {}
var chat_bubble_until: Dictionary = {}


func _ready() -> void:
	load_world_manifests()
	setup_connection_ui()
	setup_settings_ui()
	chat_input.text_submitted.connect(submit_chat)
	configure_initial_connection()
	load_player_sprite()
	enter_map(current_map_name, player_cell, "ready")
	start_control_http()
	update_player_marker()
	update_status("ready")


func setup_connection_ui() -> void:
	connection_button.pressed.connect(show_connection_panel)
	connection_cancel.pressed.connect(hide_connection_panel)
	connection_connect.pressed.connect(connect_from_panel)
	connection_layer.visible = false


func setup_settings_ui() -> void:
	get_window().wrap_controls = true
	get_viewport().size_changed.connect(layout_screen_ui)
	settings_button.pressed.connect(show_settings_panel)
	settings_close.pressed.connect(hide_settings_panel)
	settings_scale.value_changed.connect(apply_ui_scale)
	settings_layer.visible = false
	var config := ConfigFile.new()
	if config.load(CONNECTION_CONFIG_PATH) == OK:
		ui_scale = float(config.get_value("display", "ui_scale", UI_SCALE_DEFAULT))
	apply_ui_scale(ui_scale)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			if settings_layer.visible:
				hide_settings_panel()
			else:
				show_settings_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and settings_layer.visible:
			hide_settings_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ENTER and not chat_input.has_focus() and not connection_layer.visible and not settings_layer.visible:
			chat_input.grab_focus()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and chat_input.has_focus():
			chat_input.release_focus()
			get_viewport().set_input_as_handled()


func show_settings_panel() -> void:
	settings_layer.visible = true
	settings_scale.grab_focus()


func hide_settings_panel() -> void:
	settings_layer.visible = false
	settings_scale.release_focus()


func apply_ui_scale(value: float) -> void:
	ui_scale = clampf(value, UI_SCALE_MIN, UI_SCALE_MAX)
	get_window().content_scale_factor = ui_scale
	get_window().child_controls_changed()
	settings_scale.set_value_no_signal(ui_scale)
	settings_scale_value.text = "%.2fx" % ui_scale
	layout_screen_ui()
	var config := ConfigFile.new()
	config.load(CONNECTION_CONFIG_PATH)
	config.set_value("display", "ui_scale", ui_scale)
	var save_error := config.save(CONNECTION_CONFIG_PATH)
	if save_error != OK:
		push_warning("Could not remember screen scale: %s" % error_string(save_error))


func layout_screen_ui() -> void:
	var viewport_size := get_viewport_rect().size
	var right := viewport_size.x - 16.0
	var bottom := viewport_size.y - 16.0
	status_label.position = Vector2(maxf(16.0, right - 416.0), 56.0)
	status_label.size = Vector2(minf(416.0, viewport_size.x - 32.0), 90.0)
	interaction_label.position = Vector2(maxf(16.0, right - 416.0), 164.0)
	interaction_label.size = Vector2(minf(416.0, viewport_size.x - 32.0), 54.0)
	message_label.position = Vector2(maxf(16.0, right - 416.0), 242.0)
	message_label.size = Vector2(minf(416.0, viewport_size.x - 32.0), maxf(54.0, bottom - 300.0))
	chat_log.position = Vector2(maxf(16.0, right - 416.0), maxf(320.0, bottom - 198.0))
	chat_log.size = Vector2(minf(416.0, viewport_size.x - 32.0), 120.0)
	chat_input.position = Vector2(maxf(16.0, right - 416.0), bottom - 70.0)
	chat_input.size = Vector2(minf(416.0, viewport_size.x - 32.0), 34.0)
	connection_button.position = Vector2(right - 116.0, bottom - 34.0)
	settings_button.position = Vector2(right - 238.0, bottom - 34.0)
	var connection_shade := $ConnectionLayer/Shade as ColorRect
	connection_shade.size = viewport_size
	var connection_panel := $ConnectionLayer/Panel as PanelContainer
	var connection_size := Vector2(minf(500.0, viewport_size.x - 32.0), minf(432.0, viewport_size.y - 32.0))
	connection_panel.size = connection_size
	connection_panel.position = (viewport_size - connection_size) * 0.5
	var settings_shade := $SettingsLayer/Shade as ColorRect
	settings_shade.size = viewport_size
	var settings_panel := $SettingsLayer/Panel as PanelContainer
	var settings_size := Vector2(minf(400.0, viewport_size.x - 32.0), minf(196.0, viewport_size.y - 32.0))
	settings_panel.size = settings_size
	settings_panel.position = (viewport_size - settings_size) * 0.5


func configure_initial_connection() -> void:
	if OS.get_environment("TILEGROVE_OFFLINE_VERIFY") == "1":
		return
	var profile := OS.get_environment("TILEGROVE_PROFILE").strip_edges()
	if not profile.is_empty():
		player_display_name = OS.get_environment("TILEGROVE_PLAYER_NAME").strip_edges()
		if player_display_name.is_empty():
			player_display_name = profile
		start_spacetime(
			profile,
			connection_value("TILEGROVE_SPACETIME_URI", "http://127.0.0.1:3000"),
			connection_value("TILEGROVE_DATABASE", "tilegrove-dev")
		)
		return

	human_connection_mode = true
	var config := ConfigFile.new()
	if config.load(CONNECTION_CONFIG_PATH) == OK:
		connection_profile.text = str(config.get_value("connection", "profile", ""))
		connection_display_name.text = str(config.get_value("connection", "display_name", ""))
		connection_uri.text = str(config.get_value("connection", "uri", "http://127.0.0.1:3000"))
		connection_database.text = str(config.get_value("connection", "database", "tilegrove-dev"))
	if connection_profile.text.strip_edges().is_empty():
		show_connection_panel()
	else:
		connect_from_panel()


func connection_value(environment_name: String, fallback: String) -> String:
	var value := OS.get_environment(environment_name).strip_edges()
	return fallback if value.is_empty() else value


func show_connection_panel() -> void:
	connection_layer.visible = true
	connection_cancel.visible = spacetime_ready
	connection_profile.grab_focus()


func hide_connection_panel() -> void:
	if spacetime_ready:
		connection_layer.visible = false


func connect_from_panel() -> void:
	var profile := connection_profile.text.strip_edges().to_lower()
	var display_name := connection_display_name.text.strip_edges()
	var uri := connection_uri.text.strip_edges()
	var database := connection_database.text.strip_edges()
	if profile.is_empty() or not profile.is_valid_filename():
		connection_status.text = "Choose a profile without path separators."
		return
	if display_name.is_empty():
		display_name = profile
		connection_display_name.text = display_name
	if uri.is_empty() or database.is_empty():
		connection_status.text = "Server and database are required."
		return
	player_display_name = display_name
	connection_status.text = "Connecting as %s…" % display_name
	connection_connect.disabled = true
	connection_pending = true
	if human_connection_mode:
		var config := ConfigFile.new()
		config.load(CONNECTION_CONFIG_PATH)
		config.set_value("connection", "profile", profile)
		config.set_value("connection", "display_name", display_name)
		config.set_value("connection", "uri", uri)
		config.set_value("connection", "database", database)
		var save_error := config.save(CONNECTION_CONFIG_PATH)
		if save_error != OK:
			connection_status.text = "Could not remember connection settings (%s)." % error_string(save_error)
	start_spacetime(profile, uri, database)


func _process(delta: float) -> void:
	process_spacetime()
	update_player_step(delta)
	if not spacetime_enabled:
		update_object_steps(delta)
	else:
		update_authoritative_object_steps(delta)
	if connection_layer.visible or settings_layer.visible:
		poll_control_http()
		process_sse(delta)
		return
	if chat_input.has_focus():
		poll_control_http()
		process_sse(delta)
		return
	var movement := Vector2i.ZERO
	if not player_is_stepping and Input.is_action_just_pressed("ui_left"):
		movement = Vector2i.LEFT
	elif not player_is_stepping and Input.is_action_just_pressed("ui_right"):
		movement = Vector2i.RIGHT
	elif not player_is_stepping and Input.is_action_just_pressed("ui_up"):
		movement = Vector2i.UP
	elif not player_is_stepping and Input.is_action_just_pressed("ui_down"):
		movement = Vector2i.DOWN

	if movement != Vector2i.ZERO:
		if Input.is_key_pressed(KEY_SHIFT):
			face_direction(direction_name(movement))
		else:
			try_move(movement)
	var gesture_key_down := Input.is_key_pressed(KEY_G)
	if gesture_key_down and not gesture_key_was_down:
		perform_gesture("wave")
	gesture_key_was_down = gesture_key_down
	if not player_is_stepping and interact_pressed():
		perform_facing_interaction()
	poll_control_http()
	process_sse(delta)


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
		var manifest_text := file.get_as_text()
		var error := json.parse(manifest_text)
		if error != OK:
			push_error("Could not parse map manifest %s: %s" % [manifest_path, json.get_error_message()])
			continue

		manifests[map_name] = json.get_data()
		manifest_jsons[map_name] = manifest_text


func start_spacetime(profile: String, spacetime_uri: String, database: String) -> void:
	if OS.get_environment("TILEGROVE_OFFLINE_VERIFY") == "1":
		return
	if not ClassDB.class_exists("TilegroveBridge"):
		push_error("TilegroveBridge is unavailable; build the Rust client extension.")
		return
	spacetime = TilegroveBridge.new()
	spacetime_join_sent = false
	spacetime_ready = false
	spacetime_seed_queue.clear()
	spacetime_revision = -1
	spacetime_enabled = spacetime.connect_to(spacetime_uri, database, profile)
	if not spacetime_enabled:
		var failure := "Could not connect to Tilegrove authority: %s" % spacetime.last_error()
		push_error(failure)
		show_connection_failure(failure)


func process_spacetime() -> void:
	if not spacetime_enabled or spacetime == null:
		return
	spacetime.poll()
	if not spacetime.is_connected():
		spacetime_ready = false
		if connection_pending and not str(spacetime.last_error()).is_empty():
			show_connection_failure(str(spacetime.last_error()))
		return
	if not spacetime_join_sent:
		spacetime_join_sent = spacetime.join_world(player_display_name)
		return

	var server_position: Dictionary = spacetime.local_position()
	if server_position.is_empty():
		return
	if connection_pending:
		connection_pending = false
		connection_connect.disabled = false
		connection_status.text = "Connected as %s." % player_display_name
		connection_layer.visible = false
	if spacetime_seed_queue.is_empty() and spacetime.world_map_count() < map_registry.size():
		for map_name in map_registry.keys():
			spacetime_seed_queue.append(str(map_name))
	if not spacetime_seed_queue.is_empty():
		var map_name: String = spacetime_seed_queue.pop_front()
		var config: Dictionary = map_registry[map_name]
		if not spacetime.seed_world_map(map_name, str(config.get("constant", "")), str(manifest_jsons.get(map_name, ""))):
			push_error("Could not seed %s: %s" % [map_name, spacetime.last_error()])
			spacetime_seed_queue.push_front(map_name)
		return
	if spacetime.world_map_count() < map_registry.size():
		return
	spacetime_ready = true
	apply_spacetime_position(server_position)
	apply_spacetime_npcs()
	update_world_traces()
	update_other_players()
	process_world_chat()
	process_smoke_client()


func show_connection_failure(message: String) -> void:
	connection_pending = false
	connection_connect.disabled = false
	if human_connection_mode:
		connection_status.text = "Connection failed: %s" % message
		show_connection_panel()


func process_smoke_client() -> void:
	if OS.get_environment("TILEGROVE_SMOKE") != "1":
		return
	if not smoke_move_sent:
		smoke_start_revision = spacetime_revision
		smoke_move_sent = bool(spacetime.move_player(OS.get_environment("TILEGROVE_SMOKE_DIRECTION")))
		return
	if spacetime_revision > smoke_start_revision:
		if not smoke_chat_sent:
			smoke_chat_sent = bool(spacetime.send_world_chat(OS.get_environment("TILEGROVE_SMOKE_CHAT")))
			return
		smoke_chat_frames += 1
		if smoke_chat_frames >= 300:
			get_tree().quit(0)


func apply_spacetime_position(server_position: Dictionary) -> void:
	var revision := int(server_position.get("revision", -1))
	if revision == spacetime_revision:
		return
	var target_map := str(server_position.get("map", current_map_name))
	var target_cell := Vector2i(int(server_position.get("x", player_cell.x)), int(server_position.get("y", player_cell.y)))
	var target_facing := str(server_position.get("facing", player_facing))
	var origin_map := current_map_name
	var origin_cell := player_cell
	player_facing = target_facing
	if target_map != current_map_name:
		enter_map(target_map, target_cell, "authority moved to")
	elif target_cell != player_cell:
		player_cell = target_cell
		start_player_step(origin_cell, target_cell)
		update_status("moved to %s" % cell_text(player_cell))
		emit_sse_event("player_moved", stream_player_moved_details(origin_cell, target_cell))
	else:
		update_player_sprite_frame(false)
	spacetime_revision = revision
	if origin_map != current_map_name:
		update_status("entered %s" % current_map_name)


func apply_spacetime_npcs() -> void:
	for server_npc in spacetime.npcs_on_map(current_map_name):
		var object_id := str(server_npc.get("id", ""))
		if not object_states.has(object_id):
			continue
		var state: Dictionary = object_states[object_id]
		var revision := int(server_npc.get("revision", 0))
		if revision == int(state.get("server_revision", -1)):
			continue
		var origin: Vector2i = state.get("cell", Vector2i.ZERO)
		var target := Vector2i(int(server_npc.get("x", origin.x)), int(server_npc.get("y", origin.y)))
		state["server_revision"] = revision
		state["facing"] = str(server_npc.get("facing", state.get("facing", "south")))
		if target != origin:
			state["from"] = origin
			state["to"] = target
			state["cell"] = target
			state["elapsed"] = 0.0
			state["is_stepping"] = true
			var landmark := find_landmark(object_id)
			if not landmark.is_empty():
				update_object_marker_node(landmark, state, true)
		else:
			var landmark := find_landmark(object_id)
			if not landmark.is_empty():
				update_object_marker_node(landmark, state, false)


func current_world_traces() -> Array:
	if not spacetime_enabled or spacetime == null:
		return []
	return spacetime.traces_on_map(current_map_name)


func update_world_traces() -> void:
	var scale_factor: float = map_sprite.scale.x
	for child in world_traces.get_children():
		child.free()
	for trace in current_world_traces():
		var marker := Polygon2D.new()
		var age: int = maxi(0, int(trace.get("sequence", 0)))
		var alpha: float = 0.18 + float(age % 6) * 0.035
		marker.color = Color(0.70, 0.52, 0.25, alpha)
		marker.polygon = PackedVector2Array([
			Vector2(5, 9), Vector2(9, 5), Vector2(13, 9), Vector2(9, 13),
		])
		marker.position = map_sprite.position + Vector2(
			float(trace.get("x", 0)), float(trace.get("y", 0))
		) * TILE_SIZE * scale_factor
		world_traces.add_child(marker)


func update_other_players() -> void:
	for child in other_players.get_children():
		child.free()
	var local_identity := str(spacetime.local_identity())
	var current_observed: Dictionary = {}
	for player in spacetime.players():
		if str(player.get("identity", "")) == local_identity or str(player.get("map", "")) != current_map_name:
			continue
		var identity := str(player.get("identity", ""))
		current_observed[identity] = player.duplicate(true)
		observe_remote_player(identity, player)
		var cell := Vector2(int(player.get("x", 0)), int(player.get("y", 0)))
		if player_sprite.texture != null:
			var sprite := Sprite2D.new()
			sprite.name = "Player_%s" % identity.substr(0, 8)
			sprite.centered = false
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.texture = player_sprite.texture
			sprite.hframes = player_sprite.hframes
			sprite.vframes = 1
			var facing := str(player.get("facing", "south"))
			sprite.frame = int(PLAYER_FACE_FRAMES.get(facing, 0))
			sprite.flip_h = facing == "east"
			sprite.modulate = Color(0.68, 0.88, 1.0)
			sprite.scale = map_sprite.scale
			sprite.position = object_sprite_position(cell, sprite.texture)
			other_players.add_child(sprite)
			var distance: int = absi(int(cell.x) - player_cell.x) + absi(int(cell.y) - player_cell.y)
			if distance <= NEARBY_PLAYER_NAME_RADIUS:
				var label := Label.new()
				label.text = str(player.get("display_name", identity.substr(0, 8)))
				if int(player_gesture_until.get(identity, 0)) > Time.get_ticks_msec():
					label.text += "  👋"
				if int(chat_bubble_until.get(identity, 0)) > Time.get_ticks_msec():
					label.text += "\n“%s”" % str(chat_bubbles.get(identity, ""))
				label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				label.add_theme_font_size_override("font_size", 8)
				label.add_theme_color_override("font_color", Color(0.92, 0.98, 1.0))
				label.add_theme_color_override("font_shadow_color", Color(0.05, 0.10, 0.16, 0.92))
				label.add_theme_constant_override("shadow_offset_x", 1)
				label.add_theme_constant_override("shadow_offset_y", 1)
				label.position = sprite.position + Vector2(-34, -13) * map_sprite.scale
				label.size = Vector2(84, 14) * map_sprite.scale
				other_players.add_child(label)
	for identity in observed_players.keys():
		if not current_observed.has(identity):
			var departed: Dictionary = observed_players[identity]
			emit_sse_event("player_departed", {
				"summary": "%s left view." % str(departed.get("display_name", "A player")),
				"player": departed,
			})
	observed_players = current_observed


func process_world_chat() -> void:
	if not spacetime_enabled or spacetime == null:
		return
	var messages: Array = spacetime.chat_messages()
	var lines := PackedStringArray()
	for message in messages.slice(maxi(0, messages.size() - 8)):
		lines.append("%s: %s" % [str(message.get("display_name", "Player")), str(message.get("text", ""))])
		var sequence := int(message.get("sequence", 0))
		if sequence <= chat_sequence:
			continue
		chat_sequence = sequence
		var sender := str(message.get("sender", ""))
		chat_bubbles[sender] = str(message.get("text", ""))
		chat_bubble_until[sender] = Time.get_ticks_msec() + 5000
		emit_sse_event("world_chat", {
			"summary": "%s said: %s" % [str(message.get("display_name", "Player")), str(message.get("text", ""))],
			"message": message,
		})
	var rendered_chat := "\n".join(lines)
	if chat_log.text != rendered_chat:
		chat_log.text = rendered_chat
		scroll_chat_to_bottom.call_deferred()


func scroll_chat_to_bottom() -> void:
	var scroll_bar := chat_log.get_v_scroll_bar()
	scroll_bar.value = scroll_bar.max_value


func submit_chat(text: String) -> void:
	var result := send_chat(text)
	if bool(result.get("accepted", false)):
		chat_input.clear()
	chat_input.release_focus()


func send_chat(text: String) -> Dictionary:
	text = text.strip_edges()
	if text.is_empty():
		return {"ok": false, "accepted": false, "message": "Chat message is empty."}
	var accepted := spacetime_enabled and spacetime_ready and bool(spacetime.send_world_chat(text))
	if accepted:
		update_status("said: %s" % text)
	else:
		update_status("chat rejected: %s" % (spacetime.last_error() if spacetime != null else "not connected"))
	return {"ok": true, "accepted": accepted, "text": text}


func observe_remote_player(identity: String, player: Dictionary) -> void:
	if not observed_players.has(identity):
		emit_sse_event("player_arrived", {
			"summary": "%s came into view at %s." % [str(player.get("display_name", "A player")), cell_text(Vector2i(int(player.get("x", 0)), int(player.get("y", 0))))],
			"player": player,
		})
	else:
		var before: Dictionary = observed_players[identity]
		if int(before.get("revision", -1)) != int(player.get("revision", -1)):
			var moved := int(before.get("x", 0)) != int(player.get("x", 0)) or int(before.get("y", 0)) != int(player.get("y", 0))
			var kind := "player_moved_nearby" if moved else "player_turned_nearby"
			emit_sse_event(kind, {
				"summary": "%s %s %s." % [str(player.get("display_name", "A player")), "moved to" if moved else "turned", cell_text(Vector2i(int(player.get("x", 0)), int(player.get("y", 0)))) if moved else str(player.get("facing", ""))],
				"player": player,
				"previous": before,
			})
	var gesture_revision := int(player.get("gesture_revision", 0))
	if gesture_revision > int(player_gesture_seen.get(identity, 0)):
		player_gesture_seen[identity] = gesture_revision
		player_gesture_until[identity] = Time.get_ticks_msec() + PLAYER_GESTURE_VISIBLE_MSEC
		emit_sse_event("player_gesture", {
			"summary": "%s waved." % str(player.get("display_name", "A player")),
			"player": player,
			"gesture": str(player.get("gesture", "wave")),
		})


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
	reset_player_step()
	build_object_states()
	update_object_markers()
	update_player_marker()
	update_status("%s %s" % [prefix, current_map_name])
	emit_sse_event("map_entered", stream_map_entered_details(prefix))
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
	if player_is_stepping:
		update_status("moving to %s" % cell_text(player_visual_cell_to))
		return false

	if spacetime_enabled:
		if not spacetime_ready:
			update_status("waiting for world authority")
			return false
		var direction := direction_name(delta)
		var requested: bool = bool(spacetime.move_player(direction))
		if not requested:
			update_status("move rejected: %s" % spacetime.last_error())
		else:
			update_status("requested move %s" % direction)
		return requested
	set_player_facing_from_delta(delta)
	var target := player_cell + delta
	if is_cell_passable(target):
		var origin := player_cell
		player_cell = target
		start_player_step(origin, target)
		update_status("moved to %s" % cell_text(player_cell))
		emit_sse_event("player_moved", stream_player_moved_details(origin, target))
		return true

	if not is_cell_in_bounds(target):
		var crossed := try_cross_connection(delta, target)
		if not crossed:
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


func face_direction(direction: String) -> Dictionary:
	if direction_delta(direction) == Vector2i.ZERO:
		return {"ok": false, "accepted": false, "message": "Unknown direction: %s" % direction}
	var accepted := false
	if spacetime_enabled:
		accepted = spacetime_ready and bool(spacetime.face_player(direction))
	else:
		set_player_facing_from_delta(direction_delta(direction))
		accepted = true
	if accepted:
		update_status("turned %s" % direction)
	else:
		update_status("turn rejected: %s" % spacetime.last_error())
	return {"ok": true, "accepted": accepted, "direction": direction, "state": state_snapshot()}


func perform_gesture(gesture: String) -> Dictionary:
	var accepted := gesture == "wave"
	if spacetime_enabled:
		accepted = spacetime_ready and bool(spacetime.gesture_player(gesture))
	if accepted:
		update_status("waved")
		var local_identity := str(spacetime.local_identity()) if spacetime != null else ""
		emit_sse_event("player_gesture", {
			"summary": "%s waved." % player_display_name,
			"gesture": gesture,
			"player": {"identity": local_identity, "display_name": player_display_name, "map": current_map_name, "x": player_cell.x, "y": player_cell.y},
		})
	else:
		update_status("gesture rejected")
	return {"ok": true, "accepted": accepted, "gesture": gesture, "state": state_snapshot()}


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


func reset_player_step() -> void:
	player_is_stepping = false
	player_step_elapsed = 0.0
	player_visual_cell_from = player_cell
	player_visual_cell_to = player_cell
	update_player_sprite_frame(false)


func start_player_step(origin: Vector2i, target: Vector2i) -> void:
	player_is_stepping = true
	player_step_elapsed = 0.0
	player_visual_cell_from = origin
	player_visual_cell_to = target
	update_player_marker()
	update_player_sprite_frame(true)


func update_player_step(delta: float) -> void:
	if not player_is_stepping:
		return
	player_step_elapsed += delta
	if player_step_elapsed >= PLAYER_STEP_DURATION_SECONDS:
		complete_player_step()
		return
	update_player_marker()
	update_player_sprite_frame(true)


func complete_player_step() -> void:
	player_is_stepping = false
	player_step_elapsed = PLAYER_STEP_DURATION_SECONDS
	player_visual_cell_from = player_cell
	player_visual_cell_to = player_cell
	update_player_marker()
	update_player_sprite_frame(false)


func player_visual_cell() -> Vector2:
	if not player_is_stepping:
		return Vector2(player_cell)
	var progress: float = clampf(player_step_elapsed / PLAYER_STEP_DURATION_SECONDS, 0.0, 1.0)
	return Vector2(player_visual_cell_from).lerp(Vector2(player_visual_cell_to), progress)


func build_object_states() -> void:
	object_states = {}
	for landmark in manifest.get("landmarks", []):
		if str(landmark.get("kind", "")) != "object":
			continue
		var spawn := landmark_first_cell(landmark)
		var state := {
			"id": str(landmark.get("id", "")),
			"spawn": spawn,
			"cell": spawn,
			"from": spawn,
			"to": spawn,
			"is_stepping": false,
			"elapsed": 0.0,
			"idle": object_idle_offset(str(landmark.get("id", ""))),
			"direction_index": object_direction_offset(str(landmark.get("id", ""))),
			"facing": object_facing(landmark),
			"server_revision": -1,
		}
		object_states[state["id"]] = state


func object_idle_offset(object_id: String) -> float:
	return 0.35 + float(abs(object_id.hash()) % 5) * 0.17


func object_direction_offset(object_id: String) -> int:
	return abs(object_id.hash()) % 4


func update_object_steps(delta: float) -> void:
	for landmark in manifest.get("landmarks", []):
		if str(landmark.get("kind", "")) != "object":
			continue
		var object_id := str(landmark.get("id", ""))
		if not object_states.has(object_id):
			continue
		var state: Dictionary = object_states[object_id]
		if bool(state.get("is_stepping", false)):
			state["elapsed"] = float(state.get("elapsed", 0.0)) + delta
			if float(state["elapsed"]) >= OBJECT_STEP_DURATION_SECONDS:
				complete_object_step(landmark, state)
			else:
				update_object_marker_node(landmark, state, true)
			continue
		if not object_can_idle_wander(landmark):
			continue
		state["idle"] = float(state.get("idle", OBJECT_IDLE_SECONDS)) - delta
		if float(state["idle"]) <= 0.0:
			try_start_object_wander(landmark, state)


func update_authoritative_object_steps(delta: float) -> void:
	for landmark in manifest.get("landmarks", []):
		if str(landmark.get("kind", "")) != "object":
			continue
		var object_id := str(landmark.get("id", ""))
		if not object_states.has(object_id):
			continue
		var state: Dictionary = object_states[object_id]
		if not bool(state.get("is_stepping", false)):
			continue
		state["elapsed"] = float(state.get("elapsed", 0.0)) + delta
		if float(state["elapsed"]) >= OBJECT_STEP_DURATION_SECONDS:
			complete_object_step(landmark, state)
		else:
			update_object_marker_node(landmark, state, true)


func object_can_idle_wander(landmark: Dictionary) -> bool:
	return str(landmark.get("movement_type", "")) == "MOVEMENT_TYPE_WANDER_AROUND"


func try_start_object_wander(landmark: Dictionary, state: Dictionary) -> void:
	var directions := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
	var start_index := int(state.get("direction_index", 0))
	for offset in range(directions.size()):
		var index := (start_index + offset) % directions.size()
		var delta: Vector2i = directions[index]
		var target: Vector2i = state["cell"] + delta
		if object_can_step_to(landmark, state, target):
			state["direction_index"] = (index + 1) % directions.size()
			start_object_step(landmark, state, delta, target)
			return
	state["direction_index"] = (start_index + 1) % directions.size()
	state["idle"] = OBJECT_IDLE_SECONDS


func object_can_step_to(landmark: Dictionary, state: Dictionary, target: Vector2i) -> bool:
	var spawn: Vector2i = state["spawn"]
	if abs(target.x - spawn.x) > int(landmark.get("movement_range_x", 0)):
		return false
	if abs(target.y - spawn.y) > int(landmark.get("movement_range_y", 0)):
		return false
	if not is_cell_passable(target):
		return false
	if target == player_cell:
		return false
	return true


func start_object_step(landmark: Dictionary, state: Dictionary, delta: Vector2i, target: Vector2i) -> void:
	state["is_stepping"] = true
	state["elapsed"] = 0.0
	state["from"] = state["cell"]
	state["to"] = target
	state["facing"] = direction_name(delta)
	update_object_marker_node(landmark, state, true)


func complete_object_step(landmark: Dictionary, state: Dictionary) -> void:
	var origin: Vector2i = state["from"]
	var destination: Vector2i = state["to"]
	state["is_stepping"] = false
	state["elapsed"] = OBJECT_STEP_DURATION_SECONDS
	state["cell"] = destination
	state["from"] = state["cell"]
	state["idle"] = OBJECT_IDLE_SECONDS
	update_object_marker_node(landmark, state, false)
	queue_npc_motion(landmark, origin, destination, str(state.get("facing", "")))


func object_visual_cell(landmark: Dictionary) -> Vector2:
	var object_id := str(landmark.get("id", ""))
	if not object_states.has(object_id):
		return Vector2(landmark_first_cell(landmark))
	var state: Dictionary = object_states[object_id]
	if not bool(state.get("is_stepping", false)):
		return Vector2(state["cell"])
	var progress: float = clampf(float(state.get("elapsed", 0.0)) / OBJECT_STEP_DURATION_SECONDS, 0.0, 1.0)
	return Vector2(state["from"]).lerp(Vector2(state["to"]), progress)


func object_current_cell(landmark: Dictionary) -> Vector2i:
	var object_id := str(landmark.get("id", ""))
	if object_states.has(object_id):
		return object_states[object_id]["cell"]
	return landmark_first_cell(landmark)


func landmark_first_cell(landmark: Dictionary) -> Vector2i:
	for raw_cell in landmark.get("cells", []):
		return Vector2i(int(raw_cell.get("x", 0)), int(raw_cell.get("y", 0)))
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
	player_marker.position = map_sprite.position + player_visual_cell() * TILE_SIZE * scale_factor
	if player_sprite.texture != null:
		player_sprite.scale = map_sprite.scale
		player_sprite.position = player_sprite_position()


func update_player_sprite_frame(walking: bool) -> void:
	if player_sprite == null or player_sprite.texture == null:
		return

	var frames: Array = PLAYER_WALK_FRAMES.get(player_facing, [])
	if walking and not frames.is_empty():
		var progress: float = clampf(player_step_elapsed / PLAYER_STEP_DURATION_SECONDS, 0.0, 0.999)
		var frame_index := int(floor(progress * frames.size()))
		player_sprite.frame = int(frames[frame_index])
	else:
		player_sprite.frame = int(PLAYER_FACE_FRAMES.get(player_facing, 0))
	player_sprite.flip_h = player_facing == "east"


func player_sprite_position() -> Vector2:
	if player_sprite.texture == null:
		return Vector2.ZERO
	var scale_factor: float = map_sprite.scale.x
	var source_size := Vector2(PLAYER_FRAME_WIDTH, player_sprite.texture.get_height())
	var local_position := player_visual_cell() * TILE_SIZE
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
		var visual_cell := object_visual_cell(landmark)
		var sprite_texture := object_sprite_texture(landmark)
		if sprite_texture != null:
			var sprite := Sprite2D.new()
			sprite.name = str(landmark.get("id", "object"))
			sprite.centered = false
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.texture = sprite_texture
			sprite.hframes = object_sprite_hframes(sprite_texture)
			sprite.vframes = 1
			update_object_sprite_frame(sprite, landmark, false)
			sprite.scale = map_sprite.scale
			sprite.position = object_sprite_position(visual_cell, sprite_texture)
			object_markers.add_child(sprite)
		else:
			var marker := ColorRect.new()
			marker.name = str(landmark.get("id", "object"))
			marker.color = object_marker_color(landmark)
			marker.size = marker_size - Vector2(inset * 2.0, inset * 2.0)
			marker.position = map_sprite.position + visual_cell * TILE_SIZE * scale_factor + Vector2(inset, inset)
			object_markers.add_child(marker)


func update_object_marker_node(landmark: Dictionary, state: Dictionary, walking: bool) -> void:
	var marker := object_markers.get_node_or_null(str(landmark.get("id", "")))
	if marker == null:
		return
	if marker is Sprite2D:
		var sprite := marker as Sprite2D
		if sprite.texture != null:
			update_object_sprite_frame(sprite, landmark, walking)
			sprite.position = object_sprite_position(object_visual_cell(landmark), sprite.texture)
	elif marker is ColorRect:
		var rect := marker as ColorRect
		var scale_factor: float = map_sprite.scale.x
		var inset: float = maxf(3.0, 3.0 * scale_factor)
		rect.position = map_sprite.position + object_visual_cell(landmark) * TILE_SIZE * scale_factor + Vector2(inset, inset)


func object_sprite_position(cell: Vector2, texture: Texture2D) -> Vector2:
	var scale_factor: float = map_sprite.scale.x
	var source_size := Vector2(object_sprite_frame_width(texture), texture.get_height())
	var local_position := cell * TILE_SIZE
	local_position.x += (TILE_SIZE - source_size.x) / 2.0
	local_position.y += TILE_SIZE - source_size.y
	return map_sprite.position + local_position * scale_factor


func object_sprite_hframes(texture: Texture2D) -> int:
	if texture.get_width() == 144 and (texture.get_height() == 16 or texture.get_height() == 32):
		return 9
	return 1


func object_sprite_frame_width(texture: Texture2D) -> int:
	return int(texture.get_width() / object_sprite_hframes(texture))


func update_object_sprite_frame(sprite: Sprite2D, landmark: Dictionary, walking: bool) -> void:
	if sprite.hframes <= 1:
		return

	var facing := object_facing(landmark)
	if facing.is_empty():
		facing = "south"
	var frames: Array = PLAYER_WALK_FRAMES.get(facing, [])
	if walking and not frames.is_empty():
		var state: Dictionary = object_states.get(str(landmark.get("id", "")), {})
		var progress: float = clampf(float(state.get("elapsed", 0.0)) / OBJECT_STEP_DURATION_SECONDS, 0.0, 0.999)
		var frame_index := int(floor(progress * frames.size()))
		sprite.frame = int(frames[frame_index])
	else:
		sprite.frame = int(PLAYER_FACE_FRAMES.get(facing, 0))
	sprite.flip_h = facing == "east"


func object_facing(landmark: Dictionary) -> String:
	var object_id := str(landmark.get("id", ""))
	if object_states.has(object_id):
		var state_facing := str(object_states[object_id].get("facing", ""))
		if not state_facing.is_empty():
			return state_facing

	match str(landmark.get("movement_type", "")):
		"MOVEMENT_TYPE_FACE_DOWN", "MOVEMENT_TYPE_FACE_SOUTH":
			return "south"
		"MOVEMENT_TYPE_FACE_UP", "MOVEMENT_TYPE_FACE_NORTH":
			return "north"
		"MOVEMENT_TYPE_FACE_LEFT", "MOVEMENT_TYPE_FACE_WEST":
			return "west"
		"MOVEMENT_TYPE_FACE_RIGHT", "MOVEMENT_TYPE_FACE_EAST":
			return "east"
		_:
			return ""


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


func dict_to_cell(data: Dictionary) -> Vector2i:
	return Vector2i(int(data.get("x", 0)), int(data.get("y", 0)))


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
		"movement": {
			"is_stepping": player_is_stepping,
			"from_cell": cell_to_dict(player_visual_cell_from),
			"to_cell": cell_to_dict(player_visual_cell_to),
			"visual_cell": {
				"x": player_visual_cell().x,
				"y": player_visual_cell().y,
			},
			"elapsed": player_step_elapsed,
			"duration": PLAYER_STEP_DURATION_SECONDS,
		},
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
		"authority": authority_snapshot(),
		"visible_players": spacetime.players() if spacetime_enabled and spacetime != null else [],
		"world_traces": current_world_traces(),
		"control": {
			"host": CONTROL_HTTP_HOST,
			"port": control_http_port,
			"base_url": control_base_url(),
		},
	}


func authority_snapshot() -> Dictionary:
	if not spacetime_enabled or spacetime == null:
		return {"mode": "offline_verify", "ready": true}
	return {
		"mode": "spacetimedb",
		"ready": spacetime_ready,
		"connected": spacetime.is_connected(),
		"subscribed": spacetime.is_subscribed(),
		"identity": str(spacetime.local_identity()),
		"status": str(spacetime.status()),
		"last_error": str(spacetime.last_error()),
		"revision": spacetime_revision,
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
		"nearby_traces": traces_near(player_cell, radius),
		"nearby_players": players_near(player_cell, radius),
		"available_interactions": available_interactions(),
		"connections": connection_summaries(),
		"warps_here": warps_at_cell(player_cell),
	}


func players_near(cell: Vector2i, radius: int) -> Array:
	var result := []
	if not spacetime_enabled or spacetime == null:
		return result
	var local_identity := str(spacetime.local_identity())
	for player in spacetime.players():
		if str(player.get("identity", "")) == local_identity or str(player.get("map", "")) != current_map_name:
			continue
		var distance: int = absi(cell.x - int(player.get("x", 0))) + absi(cell.y - int(player.get("y", 0)))
		if distance <= radius:
			var copy: Dictionary = player.duplicate(true)
			copy["distance"] = distance
			result.append(copy)
	return result


func traces_near(cell: Vector2i, radius: int) -> Array:
	var result := []
	for trace in current_world_traces():
		var trace_cell := Vector2i(int(trace.get("x", 0)), int(trace.get("y", 0)))
		var distance: int = abs(cell.x - trace_cell.x) + abs(cell.y - trace_cell.y)
		if distance <= radius:
			var copy: Dictionary = trace.duplicate(true)
			copy["distance"] = distance
			result.append(copy)
	return result


func landmarks_near(cell: Vector2i, radius: int) -> Array:
	var result := []
	for landmark in manifest.get("landmarks", []):
		var distance := landmark_distance(cell, landmark)
		if distance <= radius:
			var copy: Dictionary = landmark.duplicate(true)
			if str(landmark.get("kind", "")) == "object":
				copy["current_cell"] = cell_to_dict(object_current_cell(landmark))
			copy["distance"] = distance
			result.append(copy)
	return result


func landmark_distance(cell: Vector2i, landmark: Dictionary) -> int:
	if str(landmark.get("kind", "")) == "object":
		var object_cell := object_current_cell(landmark)
		return abs(cell.x - object_cell.x) + abs(cell.y - object_cell.y)

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
		var interaction := {
			"target_id": str(landmark.get("id", "")),
			"kind": kind,
			"action": action,
			"name": str(landmark.get("name", "")),
			"distance": distance,
			"in_front": landmark_distance(player_cell + facing_delta(), landmark) == 0,
		}
		if kind == "object":
			interaction["current_cell"] = cell_to_dict(object_current_cell(landmark))
		interactions.append(interaction)
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
	if player_is_stepping:
		var moving_result := {
			"ok": true,
			"accepted": false,
			"message": "Finish moving first.",
			"state": state_snapshot(),
		}
		show_interaction_result(moving_result)
		return moving_result

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
	emit_sse_event("interaction", stream_interaction_details(result))
	update_interaction_prompt()


func interact_with_target(target_id: String) -> Dictionary:
	if player_is_stepping:
		return {
			"ok": true,
			"accepted": false,
			"target_id": target_id,
			"message": "Finish moving first.",
			"state": state_snapshot(),
		}

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
		if spacetime_enabled:
			if not spacetime_ready or not spacetime.use_doorway(str(landmark.get("id", ""))):
				return {
					"ok": true,
					"accepted": false,
					"target_id": str(landmark.get("id", "")),
					"kind": "doorway",
					"action": "enter",
					"name": str(landmark.get("name", "")),
					"message": "World authority rejected doorway entry: %s" % spacetime.last_error(),
					"state": state_snapshot(),
				}
		else:
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
			var keep_open := handle_control_request(peer, request_text)
			if not keep_open:
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


func handle_control_request(peer: StreamPeerTCP, request_text: String) -> bool:
	var request := parse_control_request(request_text)
	var method: String = request["method"]
	var path: String = request["path"]
	var query: Dictionary = request["query"]

	if method == "OPTIONS":
		send_control_bytes(peer, 204, "text/plain; charset=utf-8", PackedByteArray())
		return false

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
					"POST /face": "Turn in place with JSON body like {\"direction\":\"east\"}.",
					"POST /gesture": "Gesture with JSON body like {\"gesture\":\"wave\"}.",
					"POST /chat": "Chat with JSON body like {\"text\":\"Hello!\"}.",
					"GET /move?direction=east": "Move using a query string direction.",
					"GET /stream": "Open a semantic server-sent event stream of visible world changes.",
					"GET /screenshot": "Return the current Godot viewport as image/png.",
				},
			})
		"/stream":
			if method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use GET /stream."})
			else:
				start_sse_connection(peer, query)
				return true
		"/screenshot":
			if method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use GET /screenshot."})
			else:
				var image: Image = get_viewport().get_texture().get_image()
				if image == null or image.is_empty():
					send_control_json(peer, 503, {"ok": false, "message": "Viewport capture is unavailable in this headless renderer."})
				else:
					send_control_bytes(peer, 200, "image/png", image.save_png_to_buffer())
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
		"/face":
			if method != "POST" and method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use POST /face or GET /face?direction=east."})
			else:
				send_control_json(peer, 200, control_face(request["body"], query))
		"/gesture":
			if method != "POST" and method != "GET":
				send_control_json(peer, 405, {"ok": false, "message": "Use POST /gesture or GET /gesture?gesture=wave."})
			else:
				send_control_json(peer, 200, control_gesture(request["body"], query))
		"/chat":
			if method != "POST":
				send_control_json(peer, 405, {"ok": false, "message": "Use POST /chat with JSON body {\"text\":\"Hello!\"}."})
			else:
				send_control_json(peer, 200, control_chat(request["body"]))
		_:
			if path.begins_with("/move/"):
				send_control_json(peer, 200, move_direction(path.trim_prefix("/move/")))
			elif path.begins_with("/interact/"):
				send_control_json(peer, 200, interact_with_target(path.trim_prefix("/interact/")))
			else:
				send_control_json(peer, 404, {"ok": false, "message": "Unknown Tilegrove control endpoint. Try GET /help."})
	return false


func start_sse_connection(peer: StreamPeerTCP, query: Dictionary) -> void:
	var header_text := "\r\n".join([
		"HTTP/1.1 200 OK",
		"Content-Type: text/event-stream; charset=utf-8",
		"Cache-Control: no-cache",
		"Access-Control-Allow-Origin: *",
		"Connection: keep-alive",
		"",
		"",
	])
	peer.put_data(header_text.to_utf8_buffer())
	sse_connections.append({"peer": peer, "attention_only": str(query.get("attention", "0")) == "1"})
	send_sse_event(peer, "hello", stream_hello_details())


func process_sse(delta: float) -> void:
	var closed: Array[Dictionary] = []
	for connection in sse_connections:
		var peer: StreamPeerTCP = connection["peer"]
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed.append(connection)
	for connection in closed:
		sse_connections.erase(connection)

	if sse_connections.is_empty():
		sse_npc_motion_buffer = []
		sse_npc_motion_elapsed = 0.0
		sse_ambient_elapsed = 0.0
		sse_silence_elapsed = 0.0
		return

	if not sse_npc_motion_buffer.is_empty():
		sse_npc_motion_elapsed += delta
		if sse_npc_motion_elapsed >= SSE_NPC_MOTION_SECONDS:
			flush_npc_motion()

	sse_ambient_elapsed += delta
	sse_silence_elapsed += delta
	if sse_ambient_elapsed >= SSE_AMBIENT_SECONDS:
		sse_ambient_elapsed = 0.0
		emit_sse_event("ambient_status", stream_ambient_details())
	if sse_silence_elapsed >= SSE_SILENCE_SECONDS:
		sse_silence_elapsed = 0.0
		emit_sse_event("silence", {
			"summary": "%s is quiet." % current_map_name,
			"map": current_map_name,
			"cell": cell_to_dict(player_cell),
		})


func queue_npc_motion(landmark: Dictionary, origin: Vector2i, destination: Vector2i, facing: String) -> void:
	if sse_connections.is_empty():
		return
	sse_npc_motion_buffer.append(stream_npc_move_details(landmark, origin, destination, facing))
	if sse_npc_motion_buffer.size() >= 12:
		flush_npc_motion()


func flush_npc_motion() -> void:
	if sse_npc_motion_buffer.is_empty():
		return
	var moves := sse_npc_motion_buffer.duplicate(true)
	sse_npc_motion_buffer = []
	sse_npc_motion_elapsed = 0.0
	emit_sse_event("npc_motion", stream_npc_motion_details(moves))


func emit_sse_event(kind: String, details: Dictionary) -> void:
	if sse_connections.is_empty():
		return
	if kind != "ambient_status" and kind != "silence" and kind != "npc_motion":
		sse_silence_elapsed = 0.0
	var closed: Array[Dictionary] = []
	for connection in sse_connections:
		var peer: StreamPeerTCP = connection["peer"]
		if bool(connection.get("attention_only", false)):
			if kind in ["ambient_status", "silence", "npc_motion", "player_moved"]:
				continue
			var local_identity := str(spacetime.local_identity()) if spacetime != null else ""
			if kind == "world_chat" and str(details.get("message", {}).get("sender", "")) == local_identity:
				continue
			if kind == "player_gesture" and str(details.get("player", {}).get("identity", "")) == local_identity:
				continue
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed.append(connection)
			continue
		if send_sse_event(peer, kind, details) != OK:
			peer.disconnect_from_host()
			closed.append(connection)
	for connection in closed:
		sse_connections.erase(connection)


func send_sse_event(peer: StreamPeerTCP, kind: String, details: Dictionary) -> Error:
	return peer.put_data(sse_event_text(kind, details).to_utf8_buffer())


func sse_event_text(kind: String, details: Dictionary) -> String:
	return "data: %s\n\n" % JSON.stringify({
		"kind": kind,
		"details": details,
	})


func stream_hello_details() -> Dictionary:
	return {
		"summary": "Tilegrove stream opened on %s at %s." % [current_map_name, cell_text(player_cell)],
		"map": current_map_name,
		"cell": cell_to_dict(player_cell),
		"facing": player_facing,
		"loaded_map_count": map_registry.size(),
		"visible_object_count": visible_object_count(),
		"wandering_object_count": wandering_object_count(),
		"nearby_interactions": available_interactions(),
		"control": {
			"base_url": control_base_url(),
			"state": "%s/state" % control_base_url(),
			"screenshot": "%s/screenshot" % control_base_url(),
		},
		"authority": authority_snapshot(),
	}


func stream_map_entered_details(prefix: String) -> Dictionary:
	return {
		"summary": "%s %s at %s." % [prefix.capitalize(), current_map_name, cell_text(player_cell)],
		"map": current_map_name,
		"cell": cell_to_dict(player_cell),
		"facing": player_facing,
		"visible_object_count": visible_object_count(),
		"wandering_object_count": wandering_object_count(),
		"connections": connection_summaries(),
	}


func stream_player_moved_details(origin: Vector2i, destination: Vector2i) -> Dictionary:
	return {
		"summary": "Player walked %s from %s to %s on %s." % [
			player_facing,
			cell_text(origin),
			cell_text(destination),
			current_map_name,
		],
		"map": current_map_name,
		"from_cell": cell_to_dict(origin),
		"to_cell": cell_to_dict(destination),
		"facing": player_facing,
		"movement": {
			"duration": PLAYER_STEP_DURATION_SECONDS,
			"visual_tween": true,
		},
	}


func stream_npc_move_details(landmark: Dictionary, origin: Vector2i, destination: Vector2i, facing: String) -> Dictionary:
	var name := str(landmark.get("name", "Object"))
	return {
		"map": current_map_name,
		"target_id": str(landmark.get("id", "")),
		"name": name,
		"from_cell": cell_to_dict(origin),
		"to_cell": cell_to_dict(destination),
		"facing": facing,
		"movement": {
			"duration": OBJECT_STEP_DURATION_SECONDS,
			"visual_tween": true,
		},
	}


func stream_npc_motion_details(moves: Array) -> Dictionary:
	var snippets := PackedStringArray()
	for move in moves.slice(0, 4):
		snippets.append("%s %s to %s" % [
			str(move.get("name", "Object")),
			str(move.get("facing", "moved")),
			cell_text(dict_to_cell(move.get("to_cell", {}))),
		])
	var extra_count: int = maxi(0, moves.size() - snippets.size())
	var summary := "%d NPC movements: %s" % [moves.size(), ", ".join(snippets)]
	if extra_count > 0:
		summary += ", and %d more" % extra_count
	summary += "."
	return {
		"summary": summary,
		"map": current_map_name,
		"count": moves.size(),
		"sample_count": mini(6, moves.size()),
		"omitted_count": maxi(0, moves.size() - 6),
		"sample_moves": moves.slice(0, 6),
	}


func stream_interaction_details(result: Dictionary) -> Dictionary:
	var kind := str(result.get("kind", "interaction"))
	var name := str(result.get("name", kind.capitalize()))
	var summary := ""
	match kind:
		"sign":
			summary = "Read %s: %s" % [name, stream_preview_text(str(result.get("text", "")))]
		"object":
			summary = "Talked to %s: %s" % [name, stream_preview_text(str(result.get("text", result.get("message", ""))))]
		"doorway":
			if str(result.get("result_type", "")) == "entered_loaded_doorway":
				summary = "Entered %s through %s." % [str(result.get("target_map", "")), name]
			else:
				summary = "Tried %s; %s" % [name, str(result.get("message", ""))]
		_:
			summary = str(result.get("message", "Interaction completed."))

	return {
		"summary": summary,
		"map": current_map_name,
		"cell": cell_to_dict(player_cell),
		"target_id": str(result.get("target_id", "")),
		"kind": kind,
		"action": str(result.get("action", "")),
		"name": name,
		"text_preview": stream_preview_text(str(result.get("text", result.get("message", "")))),
		"result_type": str(result.get("result_type", "")),
		"target_map": str(result.get("target_map", "")),
	}


func stream_ambient_details() -> Dictionary:
	return {
		"summary": "%s has %d visible objects, %d wanderers, and %d nearby interactions." % [
			current_map_name,
			visible_object_count(),
			wandering_object_count(),
			available_interactions().size(),
		],
		"map": current_map_name,
		"cell": cell_to_dict(player_cell),
		"facing": player_facing,
		"visible_object_count": visible_object_count(),
		"wandering_object_count": wandering_object_count(),
		"nearby_interactions": available_interactions(),
	}


func stream_preview_text(text: String) -> String:
	var single_line := text.replace("\n", " ").strip_edges()
	if single_line.length() <= 96:
		return single_line
	return "%s..." % single_line.substr(0, 93)


func visible_object_count() -> int:
	var count := 0
	for landmark in manifest.get("landmarks", []):
		if str(landmark.get("kind", "")) == "object":
			count += 1
	return count


func wandering_object_count() -> int:
	var count := 0
	for landmark in manifest.get("landmarks", []):
		if object_can_idle_wander(landmark):
			count += 1
	return count


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


func control_face(body: String, query: Dictionary) -> Dictionary:
	var direction := str(query.get("direction", query.get("dir", "")))
	if direction.is_empty() and not body.strip_edges().is_empty():
		var parsed := parse_json_body(body)
		if not bool(parsed.get("ok", true)):
			return parsed
		direction = str(parsed.get("direction", parsed.get("dir", "")))
	if direction.is_empty():
		return {"ok": false, "accepted": false, "message": "Missing direction."}
	return face_direction(direction)


func control_gesture(body: String, query: Dictionary) -> Dictionary:
	var gesture := str(query.get("gesture", ""))
	if gesture.is_empty() and not body.strip_edges().is_empty():
		var parsed := parse_json_body(body)
		if not bool(parsed.get("ok", true)):
			return parsed
		gesture = str(parsed.get("gesture", ""))
	if gesture.is_empty():
		return {"ok": false, "accepted": false, "message": "Missing gesture; try wave."}
	return perform_gesture(gesture)


func control_chat(body: String) -> Dictionary:
	var parsed := parse_json_body(body)
	if not bool(parsed.get("ok", true)):
		return parsed
	return send_chat(str(parsed.get("text", "")))


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
