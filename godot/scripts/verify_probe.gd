extends SceneTree

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://scenes/main.tscn") as PackedScene
	if scene == null:
		push_error("Failed to load main scene.")
		quit(1)
		return

	var root := scene.instantiate()
	var sprite := root.get_node_or_null("LittlerootTownProbe") as Sprite2D
	if sprite == null:
		push_error("LittlerootTownProbe node is missing or is not a Sprite2D.")
		quit(1)
		return

	if sprite.texture == null:
		push_error("LittlerootTownProbe texture did not load.")
		quit(1)
		return

	print("probe texture: %s %sx%s" % [
		sprite.texture.resource_path,
		sprite.texture.get_width(),
		sprite.texture.get_height(),
	])

	get_root().add_child(root)
	await process_frame

	if not root.is_cell_passable(Vector2i(10, 15)):
		push_error("Expected start cell to be passable.")
		quit(1)
		return
	if root.map_registry.size() != 20:
		push_error("Expected twenty registry-backed maps with first-ring interiors, got %d." % root.map_registry.size())
		quit(1)
		return
	var look: Dictionary = root.look_snapshot(4)
	if look["nearby_landmarks"].size() < 2:
		push_error("Expected nearby landmarks from /look at start cell.")
		quit(1)
		return
	if not root.enter_map("LittlerootTown", Vector2i(15, 13), "verify"):
		push_error("Expected LittlerootTown to be loaded for sign interaction.")
		quit(1)
		return
	var sign_interactions: Array = root.available_interactions()
	if sign_interactions.is_empty():
		push_error("Expected a sign interaction at Littleroot town sign.")
		quit(1)
		return
	var sign_result: Dictionary = root.interact_with_target(sign_interactions[0]["target_id"])
	if not bool(sign_result.get("accepted", false)) or str(sign_result.get("kind", "")) != "sign":
		push_error("Expected sign interaction to be accepted.")
		quit(1)
		return
	if not str(sign_result.get("text", "")).contains("LITTLEROOT TOWN"):
		push_error("Expected sign interaction to return extracted text.")
		quit(1)
		return
	if not root.enter_map("LittlerootTown", Vector2i(7, 16), "verify"):
		push_error("Expected LittlerootTown to be loaded for doorway interaction.")
		quit(1)
		return
	var doorway_result: Dictionary = root.interact_with_target("warp_2_7_16")
	if not bool(doorway_result.get("accepted", false)) or str(doorway_result.get("kind", "")) != "doorway":
		push_error("Expected doorway interaction to be accepted.")
		quit(1)
		return
	if str(doorway_result.get("result_type", "")) != "entered_loaded_doorway":
		push_error("Expected doorway interaction to enter a loaded target map.")
		quit(1)
		return
	if root.current_map_name != "LittlerootTown_ProfessorBirchsLab":
		push_error("Expected Birch's lab after doorway interaction, got %s." % root.current_map_name)
		quit(1)
		return
	var doorway_state: Dictionary = doorway_result.get("state", {})
	if str(doorway_state.get("map", "")) != "LittlerootTown_ProfessorBirchsLab":
		push_error("Expected doorway result state to report Birch's lab.")
		quit(1)
		return
	if not root.enter_map("LittlerootTown", Vector2i(10, 15), "verify"):
		push_error("Expected LittlerootTown to be loaded before movement checks.")
		quit(1)
		return
	print("interaction gate: sign text extracted and loaded doorway entered")
	if not root.try_move(Vector2i.RIGHT):
		push_error("Expected movement right from start to succeed.")
		quit(1)
		return
	if not root.try_move(Vector2i.LEFT):
		push_error("Expected movement left back to start to succeed.")
		quit(1)
		return
	if root.try_move(Vector2i.LEFT):
		push_error("Expected movement into blocked cell to fail.")
		quit(1)
		return
	print("movement gate: passable move accepted, blocked move rejected")

	if not root.enter_map("LittlerootTown", Vector2i(10, 0), "verify"):
		push_error("Expected LittlerootTown to be loaded.")
		quit(1)
		return
	if not root.try_move(Vector2i.UP):
		push_error("Expected north edge to cross into Route101.")
		quit(1)
		return
	if root.current_map_name != "Route101" or root.player_cell != Vector2i(10, 19):
		push_error("Expected Route101 at south edge after crossing, got %s %s." % [root.current_map_name, root.player_cell])
		quit(1)
		return
	if not root.try_move(Vector2i.DOWN):
		push_error("Expected south edge to cross back into LittlerootTown.")
		quit(1)
		return
	if root.current_map_name != "LittlerootTown" or root.player_cell != Vector2i(10, 0):
		push_error("Expected LittlerootTown at north edge after returning, got %s %s." % [root.current_map_name, root.player_cell])
		quit(1)
		return

	if not root.enter_map("Route101", Vector2i(10, 0), "verify"):
		push_error("Expected Route101 to be loaded.")
		quit(1)
		return
	if not root.try_move(Vector2i.UP):
		push_error("Expected Route101 north edge to cross into OldaleTown.")
		quit(1)
		return
	if root.current_map_name != "OldaleTown" or root.player_cell != Vector2i(10, 19):
		push_error("Expected OldaleTown at south edge after crossing, got %s %s." % [root.current_map_name, root.player_cell])
		quit(1)
		return

	if not root.enter_map("OldaleTown", Vector2i(0, 10), "verify"):
		push_error("Expected OldaleTown to be loaded.")
		quit(1)
		return
	if not root.try_move(Vector2i.LEFT):
		push_error("Expected OldaleTown west edge to cross into Route102.")
		quit(1)
		return
	if root.current_map_name != "Route102" or root.player_cell != Vector2i(49, 10):
		push_error("Expected Route102 at east edge after crossing, got %s %s." % [root.current_map_name, root.player_cell])
		quit(1)
		return

	if not root.enter_map("Route102", Vector2i(0, 6), "verify"):
		push_error("Expected Route102 to be loaded.")
		quit(1)
		return
	if not root.try_move(Vector2i.LEFT):
		push_error("Expected Route102 west edge to cross into PetalburgCity with offset.")
		quit(1)
		return
	if root.current_map_name != "PetalburgCity" or root.player_cell != Vector2i(29, 16):
		push_error("Expected PetalburgCity at east edge after offset crossing, got %s %s." % [root.current_map_name, root.player_cell])
		quit(1)
		return
	print("connection gate: registry maps and offset crossings work")

	get_root().remove_child(root)
	root.free()
	quit(0)
