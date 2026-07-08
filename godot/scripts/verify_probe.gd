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

	get_root().remove_child(root)
	root.free()
	quit(0)
