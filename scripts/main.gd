extends Node2D
## 降临 Phase 1 — 静态小镇

func _ready() -> void:
	_setup_camera()
	_setup_ground()
	_setup_npcs()
	print("[降临] Phase 1 静态小镇加载完成 — 3 个 NPC 已放置")

func _setup_camera() -> void:
	var cam = Camera2D.new()
	cam.position = Vector2(640, 360)
	cam.zoom = Vector2(1.0, 1.0)
	cam.name = "Camera"
	add_child(cam)

func _setup_ground() -> void:
	var ground = Sprite2D.new()
	ground.texture = load("res://assets/tileset-ground.png")
	ground.position = Vector2(640, 360)
	ground.scale = Vector2(0.7, 0.7)
	ground.centered = true
	ground.name = "Ground"
	add_child(ground)

func _setup_npcs() -> void:
	var npc_container = Node2D.new()
	npc_container.name = "NPCs"
	add_child(npc_container)

	var char_sheet = load("res://assets/characters-sheet.png")
	var npcs = [
		{"name": "老王_Engineer", "pos": Vector2(380, 280), "rect": Rect2(0, 0, 32, 48)},
		{"name": "小李_Scientist", "pos": Vector2(520, 320), "rect": Rect2(32, 0, 32, 48)},
		{"name": "老张_Scavenger", "pos": Vector2(450, 420), "rect": Rect2(64, 0, 32, 48)},
	]
	for npc_data in npcs:
		var sprite = Sprite2D.new()
		sprite.texture = char_sheet
		sprite.position = npc_data["pos"]
		sprite.region_enabled = true
		sprite.region_rect = npc_data["rect"]
		sprite.scale = Vector2(3, 3)
		sprite.name = npc_data["name"]
		npc_container.add_child(sprite)

	# Add name labels
	for npc_data in npcs:
		var label = Label.new()
		label.text = npc_data["name"].replace("_", "\n")
		label.position = npc_data["pos"] + Vector2(0, -60)
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7, 0.9))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		npc_container.add_child(label)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			$Camera.zoom *= 1.1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			$Camera.zoom *= 0.9
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		$Camera.position -= event.relative / $Camera.zoom
