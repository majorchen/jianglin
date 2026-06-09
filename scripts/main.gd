extends Node2D
## 降临 Phase 2 — 活的小镇：角色按日程走动 + 对话 + 记忆

var game_time: float = 6.0  # 游戏内小时 (6:00 = 早上6点)
var time_speed: float = 0.5  # 每秒推进的游戏小时
var schedule_data: Dictionary = {}
var characters: Dictionary = {}  # name -> {sprite, label, memory, schedule}
var speech_bubbles: Array = []

func _ready() -> void:
	_setup_camera()
	_setup_ground()
	_load_schedule()
	_setup_npcs()
	print("[降临] Phase 2 活的小镇 — 角色会走了")

func _process(delta: float) -> void:
	game_time += delta * time_speed
	if game_time >= 24.0:
		game_time = 6.0  # 新的一天从6点开始
	_update_characters()

func _setup_camera() -> void:
	var cam = Camera2D.new()
	cam.position = Vector2(480, 360)
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

func _load_schedule() -> void:
	var file = FileAccess.open("res://data/schedule-sample.json", FileAccess.READ)
	if file:
		var text = file.get_as_text()
		var json = JSON.parse_string(text)
		if json and json.has("characters"):
			schedule_data = json
			print("[降临] 日程加载成功: day ", json.get("day", "?"))
		else:
			print("[降临] 日程解析失败")
	else:
		print("[降临] 找不到日程文件，使用默认站位")
		schedule_data = _default_schedule()

func _setup_npcs() -> void:
	var char_sheet = load("res://assets/characters-sheet.png")
	var char_data = schedule_data.get("characters", {})

	var idx = 0
	for key in char_data:
		var data = char_data[key]
		var start_pos = _find_start_position(data)
		var sprite = Sprite2D.new()
		sprite.texture = char_sheet
		sprite.position = start_pos
		sprite.region_enabled = true
		sprite.region_rect = Rect2(idx * 32, 0, 32, 48)
		sprite.scale = Vector2(3, 3)
		sprite.name = data.get("name", key)
		add_child(sprite)

		var label = Label.new()
		label.text = data.get("name", key)
		label.position = start_pos + Vector2(0, -60)
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", Color(0.95, 0.88, 0.65, 0.9))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.name = data.get("name", key) + "_label"
		add_child(label)

		characters[key] = {
			"sprite": sprite,
			"label": label,
			"data": data,
			"memory": data.get("memory", []),
			"schedule": data.get("schedule", []),
			"target_pos": start_pos,
			"last_text": ""
		}
		idx += 1

func _find_start_position(data: Dictionary) -> Vector2:
	var sched = data.get("schedule", [])
	if sched.size() > 0:
		var loc = sched[0].get("location", [400, 300])
		return Vector2(loc[0], loc[1])
	return Vector2(randi_range(350, 550), randi_range(250, 450))

func _default_schedule() -> Dictionary:
	return {
		"day": 1,
		"characters": {
			"engineer_wang": {"name": "老王", "role": "工程师", "schedule": [], "memory": []},
			"scientist_li": {"name": "小李", "role": "科学家", "schedule": [], "memory": []},
			"scavenger_zhang": {"name": "老张", "role": "拾荒者", "schedule": [], "memory": []}
		}
	}

func _update_characters() -> void:
	var hour = int(game_time) % 24
	for key in characters:
		var char_info = characters[key]
		var sched = char_info["schedule"]
		if sched.is_empty():
			continue

		# Find current action based on game time
		var current_action = null
		var next_action = null
		for i in range(sched.size()):
			var act = sched[i]
			var act_time = act.get("time", 0)
			if act_time <= hour:
				current_action = act
				if i + 1 < sched.size():
					next_action = sched[i + 1]
			else:
				if current_action == null and i > 0:
					current_action = sched[i - 1]
				next_action = act
				break

		if current_action == null:
			continue

		# Move towards target location
		var target = current_action.get("location", null)
		if target != null:
			var target_pos = Vector2(target[0], target[1])
			char_info["target_pos"] = target_pos
			var sprite = char_info["sprite"]
			var dist = sprite.position.distance_to(target_pos)
			if dist > 5:
				var direction = (target_pos - sprite.position).normalized()
				sprite.position += direction * 80.0 * get_process_delta_time()
				# Update label position
				char_info["label"].position = sprite.position + Vector2(0, -60)

		# Check for talk/reply actions at this hour
		var text = current_action.get("text", "")
		if text != "" and text != char_info["last_text"] and hour == current_action.get("time", -1):
			char_info["last_text"] = text
			_show_speech(char_info["sprite"], text)
			# Check for targeted conversation
			var target_name = current_action.get("target", "")
			if target_name != "" and characters.has(target_name):
				# Trigger the target's reply in the same hour
				pass

func _show_speech(sprite: Sprite2D, text: String) -> void:
	for bubble in speech_bubbles:
		if bubble.get_parent():
			bubble.queue_free()
	speech_bubbles.clear()

	var label = Label.new()
	label.text = text
	label.position = sprite.position + Vector2(-80, -110)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.8, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("outline_size", 2)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.name = "SpeechBubble"
	add_child(label)
	speech_bubbles.append(label)

	# Fade out after 3 seconds
	var tween = create_tween()
	tween.tween_interval(3.0)
	tween.tween_property(label, "modulate:a", 0.0, 1.0)
	tween.tween_callback(label.queue_free)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			$Camera.zoom = clamp($Camera.zoom * 1.15, 0.3, 3.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			$Camera.zoom = clamp($Camera.zoom * 0.87, 0.3, 3.0)
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		$Camera.position -= event.relative / $Camera.zoom
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			game_time = 6.0  # Reset day
		elif event.keycode == KEY_PLUS or event.keycode == KEY_EQUAL:
			time_speed += 0.2
		elif event.keycode == KEY_MINUS:
			time_speed = max(0.1, time_speed - 0.2)
		elif event.keycode == KEY_M:
			for key in characters:
				var mem = characters[key].get("memory", [])
				if mem.size() > 0:
					print(characters[key]["data"]["name"], " 记忆: ", mem)
