extends Node3D

const WORLD_STATE_PATH := "res://data/world-state.json"
const GROUND_TEXTURE := "res://assets_hd2d/terrain/ground_dirt.png"
const GROUND_TEXTURE_2 := "res://assets_hd2d/terrain/ground_rocky.png"
const PATH_TEXTURE := "res://assets_hd2d/terrain/ground_path.png"
const FONT_PATH := "res://assets_hd2d/fonts/NotoSansSC-Regular.ttf"
# v2 资产按 48px/世界单位生成；取 2x 密度让现有小镇布局保持宽松
const PIXELS_PER_UNIT := 96.0
const MAP_MIN := Vector2(-3.2, -3.6)
const MAP_MAX := Vector2(3.2, 4.2)
const BASE_TIME_SPEED := 0.18
const SHEET_HEIGHT_RATIO := 0.54
const BUILDING_TEXTURES := {
	"b0": "res://assets_hd2d/buildings/b0.png",
	"b1": "res://assets_hd2d/buildings/b1.png",
	"b2": "res://assets_hd2d/buildings/b2.png",
	"b3": "res://assets_hd2d/buildings/b3.png",
	"b4": "res://assets_hd2d/buildings/b4.png",
}
const CHARACTER_TEXTURES := {
	"engineer": "res://assets_hd2d/characters/engineer_walk_sheet.png",
	"scientist": "res://assets_hd2d/characters/scientist_walk_sheet.png",
	"scavenger": "res://assets_hd2d/characters/scavenger_walk_sheet.png",
}
const PROP_TEXTURES := {
	"barrel": "res://assets_hd2d/props/barrel.png",
	"crates": "res://assets_hd2d/props/crates.png",
	"campfire": "res://assets_hd2d/props/campfire.png",
	"fence": "res://assets_hd2d/props/fence.png",
	"watertank": "res://assets_hd2d/props/watertank.png",
	"debris": "res://assets_hd2d/props/debris.png",
	"solar": "res://assets_hd2d/props/solar.png",
	"bench": "res://assets_hd2d/props/bench.png",
}
const RESOURCE_ORDER := ["food", "water", "power", "medicine", "morale", "threat"]
const RESOURCE_LABELS := {
	"food": "食",
	"water": "水",
	"power": "电",
	"medicine": "药",
	"morale": "士",
	"threat": "威",
}

@export var tilt_shift_strength := 2.4

enum SheetKind { NONE, TODAY, VOTE, CAMP, CHARACTER, BUILDING }

var ui_font: Font
var world_state: Dictionary = {}
var resources: Dictionary = {}
var game_time := 6.0
var time_speed := BASE_TIME_SPEED
var replay_mode := false
var paused := false
var camera: Camera3D
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var camp_glow: OmniLight3D
var tilt_layer: CanvasLayer
var tilt_rect: ColorRect
var touch_points: Dictionary = {}
var last_pinch_distance := 0.0
var characters: Dictionary = {}
var buildings: Dictionary = {}
var building_lights: Array[OmniLight3D] = []
var triggered_events: Dictionary = {}
var today_timeline: Array[Dictionary] = []
var selected_vote := ""
var vote_totals: Dictionary = {}
var vote_request: HTTPRequest
var current_sheet := SheetKind.NONE
var current_sheet_payload: Dictionary = {}

@onready var legacy_speech: PanelContainer = $UI/SpeechBubble
@onready var legacy_card: PanelContainer = $UI/CharacterCard

var status_bar: PanelContainer
var status_row: HBoxContainer
var status_labels: Dictionary = {}
var dock: PanelContainer
var dock_row: HBoxContainer
var sheet_overlay: Control
var sheet_panel: PanelContainer
var sheet_title: Label
var sheet_body: VBoxContainer
var toast_panel: PanelContainer
var toast_title: Label
var toast_text: Label
var replay_buttons: Array[Button] = []
var tab_buttons: Dictionary = {}

func _ready() -> void:
	ui_font = ResourceLoader.load(FONT_PATH)
	_load_world_state()
	_setup_world()
	_setup_tilt_shift()
	_setup_runtime_ui()
	_setup_network()
	_spawn_buildings()
	_spawn_props()
	_spawn_characters()
	_set_realtime_clock()
	_update_characters(0.0)
	_update_lighting(0.0)
	_update_ui()
	_fetch_vote_totals()
	if legacy_speech != null:
		legacy_speech.visible = false
	if legacy_card != null:
		legacy_card.visible = false
	print("[降临] mobile P0 HD-2D loop ready")

func _process(delta: float) -> void:
	if replay_mode:
		if not paused:
			game_time += delta * time_speed
			if game_time >= 24.0:
				_advance_day()
	else:
		_set_realtime_clock()
	_update_characters(delta)
	_check_events()
	_update_lighting(delta)
	_update_ui()

func _load_world_state() -> void:
	var file := FileAccess.open(WORLD_STATE_PATH, FileAccess.READ)
	if file == null:
		world_state = {}
	else:
		var parsed = JSON.parse_string(file.get_as_text())
		world_state = parsed if parsed is Dictionary else {}
	resources = world_state.get("world", {}).get("resources", {}).duplicate(true)
	if resources.is_empty():
		resources = {"food": 40, "water": 50, "power": 35, "medicine": 20, "morale": 60}

func _setup_network() -> void:
	vote_request = HTTPRequest.new()
	vote_request.name = "VoteRequest"
	vote_request.request_completed.connect(_on_vote_request_completed)
	add_child(vote_request)

func _set_realtime_clock() -> void:
	var now := Time.get_datetime_dict_from_system()
	game_time = float(now.get("hour", 6)) + float(now.get("minute", 0)) / 60.0

func _panel_style(color: Color, border := Color(0, 0, 0, 0), radius := 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_color = border
	style.border_width_left = 1 if border.a > 0.0 else 0
	style.border_width_top = 1 if border.a > 0.0 else 0
	style.border_width_right = 1 if border.a > 0.0 else 0
	style.border_width_bottom = 1 if border.a > 0.0 else 0
	return style

func _new_label(text := "", size := 15, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = align
	label.add_theme_font_size_override("font_size", size)
	if ui_font != null:
		label.add_theme_font_override("font", ui_font)
	return label

func _new_button(text: String, size := 16) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 48)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", size)
	if ui_font != null:
		button.add_theme_font_override("font", ui_font)
	button.add_theme_stylebox_override("normal", _panel_style(Color(0.09, 0.075, 0.055, 0.92), Color(0.78, 0.56, 0.32, 0.28), 8))
	button.add_theme_stylebox_override("hover", _panel_style(Color(0.14, 0.11, 0.075, 0.96), Color(0.9, 0.66, 0.38, 0.48), 8))
	button.add_theme_stylebox_override("pressed", _panel_style(Color(0.22, 0.15, 0.08, 0.98), Color(1.0, 0.72, 0.36, 0.62), 8))
	return button

func _safe_top() -> float:
	var safe := DisplayServer.get_display_safe_area()
	return clamp(float(safe.position.y), 0.0, 44.0)

func _safe_bottom() -> float:
	var safe := DisplayServer.get_display_safe_area()
	var screen_h := float(DisplayServer.screen_get_size().y)
	return clamp(screen_h - float(safe.position.y + safe.size.y), 0.0, 36.0)

func _setup_runtime_ui() -> void:
	var ui: CanvasLayer = $UI
	for child in ui.get_children():
		if child.name in ["TopBar", "SpeechBubble", "CharacterCard"]:
			child.visible = false
	_setup_status_bar(ui)
	_setup_toast(ui)
	_setup_sheet(ui)
	_setup_dock(ui)

func _setup_status_bar(ui: CanvasLayer) -> void:
	status_bar = PanelContainer.new()
	status_bar.name = "StatusBar"
	status_bar.anchor_right = 1.0
	status_bar.offset_left = 8
	status_bar.offset_top = 6 + _safe_top()
	status_bar.offset_right = -8
	status_bar.offset_bottom = status_bar.offset_top + 44
	status_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	status_bar.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.032, 0.03, 0.72), Color(0.9, 0.68, 0.4, 0.22), 8))
	status_bar.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_toggle_sheet(SheetKind.CAMP)
		elif event is InputEventScreenTouch and event.pressed:
			_toggle_sheet(SheetKind.CAMP)
	)
	ui.add_child(status_bar)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	status_bar.add_child(margin)

	status_row = HBoxContainer.new()
	status_row.alignment = BoxContainer.ALIGNMENT_CENTER
	status_row.add_theme_constant_override("separation", 5)
	margin.add_child(status_row)

	var time_label := _new_label("", 15, HORIZONTAL_ALIGNMENT_CENTER)
	time_label.name = "time"
	time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(time_label)
	status_labels["time"] = time_label

	for key in RESOURCE_ORDER:
		var label := _new_label("", 15, HORIZONTAL_ALIGNMENT_CENTER)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		status_row.add_child(label)
		status_labels[key] = label

func _setup_toast(ui: CanvasLayer) -> void:
	toast_panel = PanelContainer.new()
	toast_panel.name = "EventToast"
	toast_panel.visible = false
	toast_panel.anchor_right = 1.0
	toast_panel.offset_left = 12
	toast_panel.offset_right = -12
	toast_panel.offset_top = 54 + _safe_top()
	toast_panel.offset_bottom = toast_panel.offset_top + 68
	toast_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.045, 0.035, 0.9), Color(1.0, 0.5, 0.24, 0.46), 8))
	ui.add_child(toast_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	toast_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)
	toast_title = _new_label("", 17, HORIZONTAL_ALIGNMENT_LEFT)
	toast_title.add_theme_color_override("font_color", Color(1.0, 0.78, 0.42))
	box.add_child(toast_title)
	toast_text = _new_label("", 14, HORIZONTAL_ALIGNMENT_LEFT)
	toast_text.add_theme_color_override("font_color", Color(0.94, 0.86, 0.72))
	box.add_child(toast_text)

func _setup_sheet(ui: CanvasLayer) -> void:
	sheet_overlay = Control.new()
	sheet_overlay.name = "SheetOverlay"
	sheet_overlay.visible = false
	sheet_overlay.anchor_right = 1.0
	sheet_overlay.anchor_bottom = 1.0
	sheet_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	sheet_overlay.gui_input.connect(func(event: InputEvent):
		if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed):
			_close_sheet()
			get_viewport().set_input_as_handled()
	)
	ui.add_child(sheet_overlay)

	sheet_panel = PanelContainer.new()
	sheet_panel.name = "BottomSheet"
	sheet_panel.visible = false
	sheet_panel.anchor_top = 1.0
	sheet_panel.anchor_right = 1.0
	sheet_panel.anchor_bottom = 1.0
	sheet_panel.offset_left = 0
	sheet_panel.offset_right = 0
	sheet_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	sheet_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.038, 0.032, 0.97), Color(0.9, 0.68, 0.42, 0.34), 14))
	ui.add_child(sheet_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	sheet_panel.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var handle := ColorRect.new()
	handle.color = Color(0.78, 0.76, 0.72, 0.48)
	handle.custom_minimum_size = Vector2(48, 5)
	handle.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(handle)

	sheet_title = _new_label("", 20, HORIZONTAL_ALIGNMENT_CENTER)
	sheet_title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.54))
	root.add_child(sheet_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	sheet_body = VBoxContainer.new()
	sheet_body.add_theme_constant_override("separation", 10)
	sheet_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(sheet_body)

func _setup_dock(ui: CanvasLayer) -> void:
	dock = PanelContainer.new()
	dock.name = "BottomDock"
	dock.anchor_top = 1.0
	dock.anchor_right = 1.0
	dock.anchor_bottom = 1.0
	dock.offset_left = 8
	dock.offset_top = -60 - _safe_bottom()
	dock.offset_right = -8
	dock.offset_bottom = -6 - _safe_bottom()
	dock.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.032, 0.028, 0.78), Color(0.9, 0.68, 0.42, 0.2), 8))
	ui.add_child(dock)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_bottom", 3)
	dock.add_child(margin)
	dock_row = HBoxContainer.new()
	dock_row.add_theme_constant_override("separation", 4)
	margin.add_child(dock_row)
	_build_default_dock()

func _clear_dock() -> void:
	for child in dock_row.get_children():
		child.queue_free()
	tab_buttons.clear()
	replay_buttons.clear()

func _build_default_dock() -> void:
	_clear_dock()
	var specs := [
		{"label": "今日", "kind": SheetKind.TODAY},
		{"label": "投票", "kind": SheetKind.VOTE},
		{"label": "营地", "kind": SheetKind.CAMP},
	]
	for spec in specs:
		var button := _new_button(spec["label"], 17)
		var kind: int = spec["kind"]
		button.pressed.connect(func(): _toggle_sheet(kind))
		dock_row.add_child(button)
		tab_buttons[kind] = button

func _build_replay_dock() -> void:
	_clear_dock()
	var exit_btn := _new_button("退出回放", 15)
	exit_btn.pressed.connect(_exit_replay)
	dock_row.add_child(exit_btn)
	replay_buttons.append(exit_btn)
	var pause_btn := _new_button("暂停", 15)
	pause_btn.pressed.connect(func():
		paused = not paused
		pause_btn.text = "继续" if paused else "暂停"
	)
	dock_row.add_child(pause_btn)
	replay_buttons.append(pause_btn)
	var speed_btn := _new_button("倍速 1x", 15)
	speed_btn.pressed.connect(func():
		_cycle_speed()
		speed_btn.text = "倍速 %.0fx" % max(1.0, time_speed / BASE_TIME_SPEED)
	)
	dock_row.add_child(speed_btn)
	replay_buttons.append(speed_btn)

func _toggle_sheet(kind: int, payload := {}) -> void:
	if current_sheet == kind and sheet_panel.visible:
		_close_sheet()
		return
	_open_sheet(kind, payload)

func _open_sheet(kind: int, payload := {}) -> void:
	current_sheet = kind
	current_sheet_payload = payload
	sheet_overlay.visible = true
	sheet_panel.visible = true
	_populate_sheet(kind, payload)
	var vp_h := get_viewport().get_visible_rect().size.y
	var height := maxf(360.0, vp_h * SHEET_HEIGHT_RATIO)
	var dock_off := 66.0 + _safe_bottom()
	# 底部抽屉：贴着 dock 上沿，从屏幕下方滑入
	sheet_panel.offset_top = -dock_off - height
	sheet_panel.offset_bottom = -dock_off
	var final_y := vp_h - dock_off - height
	sheet_panel.position.y = vp_h
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(sheet_panel, "position:y", final_y, 0.22)

func _close_sheet() -> void:
	if not sheet_panel.visible:
		return
	var vp_h := get_viewport().get_visible_rect().size.y
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(sheet_panel, "position:y", vp_h, 0.18)
	tween.tween_callback(func():
		sheet_panel.visible = false
		sheet_overlay.visible = false
		current_sheet = SheetKind.NONE
	)

func _clear_sheet_body() -> void:
	for child in sheet_body.get_children():
		child.queue_free()

func _populate_sheet(kind: int, payload := {}) -> void:
	_clear_sheet_body()
	if kind == SheetKind.TODAY:
		_build_today_sheet()
	elif kind == SheetKind.VOTE:
		_build_vote_sheet()
	elif kind == SheetKind.CAMP:
		_build_camp_sheet()
	elif kind == SheetKind.CHARACTER:
		_build_character_sheet(payload)
	elif kind == SheetKind.BUILDING:
		_build_building_sheet(payload)

func _build_today_sheet() -> void:
	sheet_title.text = "今日"
	var brief := _new_label(world_state.get("world", {}).get("daily_brief", ""), 16)
	brief.add_theme_color_override("font_color", Color(0.95, 0.88, 0.72))
	sheet_body.add_child(brief)
	sheet_body.add_child(_section_title("时间线"))
	if today_timeline.is_empty():
		var empty := _new_label("今天尚未触发事件。", 15)
		empty.add_theme_color_override("font_color", Color(0.72, 0.68, 0.58))
		sheet_body.add_child(empty)
	else:
		for item in today_timeline:
			var row := _new_label("%s  %s\n%s" % [item.get("time", ""), item.get("title", ""), item.get("text", "")], 15)
			row.add_theme_color_override("font_color", Color(0.9, 0.84, 0.7))
			sheet_body.add_child(row)
	var replay_btn := _new_button("回放今日", 16)
	replay_btn.pressed.connect(_start_replay)
	sheet_body.add_child(replay_btn)

func _build_vote_sheet() -> void:
	sheet_title.text = "投票"
	var question := _new_label(world_state.get("votes", {}).get("question", "明天优先做什么？"), 18, HORIZONTAL_ALIGNMENT_CENTER)
	question.add_theme_color_override("font_color", Color(1.0, 0.82, 0.48))
	sheet_body.add_child(question)
	for option in world_state.get("votes", {}).get("options", []):
		var option_id := str(option.get("id", ""))
		var count := int(vote_totals.get(option_id, 0))
		var selected := option_id == selected_vote
		var button := _new_button("%s%s · %d" % ["✓ " if selected else "", option.get("label", ""), count], 16)
		if selected:
			button.add_theme_stylebox_override("normal", _panel_style(Color(0.24, 0.16, 0.08, 0.98), Color(1.0, 0.75, 0.36, 0.72), 8))
		button.pressed.connect(func(): _select_vote(option_id))
		sheet_body.add_child(button)
		var desc := _new_label(option.get("description", ""), 14)
		desc.add_theme_color_override("font_color", Color(0.76, 0.71, 0.61))
		sheet_body.add_child(desc)

func _build_camp_sheet() -> void:
	sheet_title.text = "营地"
	var world: Dictionary = world_state.get("world", {})
	var title := _new_label(world_state.get("title", "降临"), 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.5))
	sheet_body.add_child(title)
	sheet_body.add_child(_new_label("威胁 %d · 天气 %s" % [int(world.get("threat", 0)), world.get("weather", "unknown")], 16))
	sheet_body.add_child(_section_title("资源"))
	for key in RESOURCE_ORDER:
		var value := _resource_value(key)
		var label := _new_label("%s  %d" % [RESOURCE_LABELS.get(key, key), value], 16)
		label.add_theme_color_override("font_color", Color(1.0, 0.34, 0.26) if value < 20 else Color(0.9, 0.84, 0.7))
		sheet_body.add_child(label)
	sheet_body.add_child(_section_title("历史"))
	for item in world_state.get("history", []):
		sheet_body.add_child(_new_label(str(item), 15))

func _build_character_sheet(data: Dictionary) -> void:
	sheet_title.text = data.get("name", "人物")
	var head := TextureRect.new()
	head.custom_minimum_size = Vector2(96, 96)
	head.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	head.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var texture_path: String = CHARACTER_TEXTURES.get(data.get("archetype", ""), "")
	var sheet_tex: Texture2D = load(texture_path)
	# 只取 4x4 走路图的第 0 帧做头像
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet_tex
	atlas.region = Rect2(0, 0, sheet_tex.get_width() / 4.0, sheet_tex.get_height() / 4.0)
	head.texture = atlas
	sheet_body.add_child(head)
	var meta := _new_label("%s · %s\n需要：%s" % [data.get("role", ""), data.get("mood", ""), data.get("need", "")], 16)
	meta.add_theme_color_override("font_color", Color(0.95, 0.86, 0.68))
	sheet_body.add_child(meta)
	sheet_body.add_child(_section_title("记忆"))
	for item in data.get("memory", []):
		sheet_body.add_child(_new_label(str(item), 15))

func _build_building_sheet(data: Dictionary) -> void:
	sheet_title.text = data.get("name", "建筑")
	var status := _new_label(data.get("status", ""), 17)
	status.add_theme_color_override("font_color", Color(1.0, 0.82, 0.5))
	sheet_body.add_child(status)
	sheet_body.add_child(_new_label(data.get("description", ""), 16))

func _section_title(text: String) -> Label:
	var label := _new_label(text, 17)
	label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.38))
	return label

func _setup_world() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 9.2
	camera.position = Vector3(0.0, 9.8, 9.8)
	add_child(camera)
	camera.look_at(Vector3(0, 0, 0.35), Vector3.UP)
	camera.current = true

	sun = DirectionalLight3D.new()
	sun.name = "SunCycle"
	sun.light_energy = 2.0
	sun.light_color = Color(1.0, 0.82, 0.58)
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-52, -35, 0)
	add_child(sun)

	camp_glow = OmniLight3D.new()
	camp_glow.name = "CampGlow"
	camp_glow.position = Vector3(-0.9, 1.1, 2.0)
	camp_glow.light_color = Color(1.0, 0.48, 0.22)
	camp_glow.light_energy = 0.0
	camp_glow.omni_range = 5.0
	add_child(camp_glow)

	world_env = WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.06, 0.07, 0.1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.32, 0.28, 0.22)
	e.ambient_light_energy = 0.55
	world_env.environment = e
	add_child(world_env)

	_build_tiled_ground()
	_add_path(Vector3(-2.6, 0.018, 2.8), Vector3(2.6, 0.018, -1.1), 0.34)
	_add_path(Vector3(-3.1, 0.021, -1.2), Vector3(2.8, 0.021, 1.6), 0.3)

func _build_tiled_ground() -> void:
	var tex: Texture2D = load(GROUND_TEXTURE)
	var tex2: Texture2D = load(GROUND_TEXTURE_2)
	for x in range(6):
		for z in range(8):
			var inst := MeshInstance3D.new()
			inst.name = "GroundTile"
			var mesh := PlaneMesh.new()
			mesh.size = Vector2(2.0, 2.0)
			inst.mesh = mesh
			inst.position = Vector3(-5.0 + x * 2.0, 0.0, -7.0 + z * 2.0)
			var rocky := (x * 73 + z * 137 + 11) % 6 == 0
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = tex2 if rocky else tex
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			mat.roughness = 1.0
			# 镜像平铺：相邻砖 UV 翻转，边缘像素严格对齐，不依赖纹理真无缝
			mat.uv1_scale = Vector3(-1.0 if x % 2 == 1 else 1.0, -1.0 if z % 2 == 1 else 1.0, 1.0)
			inst.material_override = mat
			add_child(inst)

func _add_path(start: Vector3, end: Vector3, width: float) -> void:
	var mid := (start + end) * 0.5
	var length := start.distance_to(end)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(width, length)
	var inst := MeshInstance3D.new()
	inst.name = "PathQuad"
	inst.mesh = mesh
	inst.position = mid
	inst.rotation.y = atan2(end.x - start.x, end.z - start.z)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(PATH_TEXTURE)
	mat.albedo_color = Color(0.52, 0.42, 0.3, 0.34)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.roughness = 1.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	inst.material_override = mat
	add_child(inst)

func _setup_tilt_shift() -> void:
	tilt_layer = CanvasLayer.new()
	tilt_layer.name = "TiltShiftLayer"
	tilt_layer.layer = 0
	add_child(tilt_layer)
	tilt_rect = ColorRect.new()
	tilt_rect.anchor_right = 1.0
	tilt_rect.anchor_bottom = 1.0
	tilt_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float strength = 2.4;
void fragment() {
	vec2 uv = SCREEN_UV;
	float top = smoothstep(0.25, 0.0, uv.y);
	float bottom = smoothstep(0.75, 1.0, uv.y);
	float blur = max(top, bottom) * strength / 720.0;
	vec4 c = textureLod(screen_texture, uv, 0.0) * 0.24;
	c += textureLod(screen_texture, uv + vec2(blur, 0.0), 0.0) * 0.15;
	c += textureLod(screen_texture, uv - vec2(blur, 0.0), 0.0) * 0.15;
	c += textureLod(screen_texture, uv + vec2(0.0, blur), 0.0) * 0.15;
	c += textureLod(screen_texture, uv - vec2(0.0, blur), 0.0) * 0.15;
	c += textureLod(screen_texture, uv + vec2(blur, blur), 0.0) * 0.08;
	c += textureLod(screen_texture, uv - vec2(blur, blur), 0.0) * 0.08;
	COLOR = c;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("strength", tilt_shift_strength)
	tilt_rect.material = mat
	tilt_layer.add_child(tilt_rect)

func _spawn_buildings() -> void:
	for data in world_state.get("buildings", []):
		if not bool(data.get("unlocked", true)):
			continue
		var texture_path: String = BUILDING_TEXTURES.get(data.get("texture", ""), "")
		var texture: Texture2D = load(texture_path)
		var sprite := Sprite3D.new()
		sprite.name = data.get("name", "建筑")
		sprite.texture = texture
		sprite.pixel_size = _pixel_size(data)
		sprite.position = _vec2_to_world(data.get("position", [0, 0]), 0.02) + Vector3(0, _sprite_half_height(texture, sprite.pixel_size), 0)
		sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_OPAQUE_PREPASS
		add_child(sprite)
		var shadow := _add_shadow(sprite, Vector2(1.15, 0.48) * float(data.get("scale", 1.0)), 0.012)
		var light := _add_building_light(_vec2_to_world(data.get("position", [0, 0]), 0.75), data.get("id", ""))
		buildings[data.get("id", sprite.name)] = {"sprite": sprite, "shadow": shadow, "light": light, "data": data}

func _spawn_characters() -> void:
	for data in world_state.get("characters", []):
		var texture_path: String = CHARACTER_TEXTURES.get(data.get("archetype", ""), "")
		var texture: Texture2D = load(texture_path)
		var sprite := Sprite3D.new()
		sprite.name = data.get("name", "角色")
		sprite.texture = texture
		sprite.hframes = 4
		sprite.vframes = 4
		sprite.frame = 0
		sprite.pixel_size = _pixel_size(data)
		var home := _vec2_to_world(data.get("home", [0, 0]), 0.08)
		var lift := _sprite_half_height(texture, sprite.pixel_size, sprite.vframes)
		sprite.position = home + Vector3(0, lift, 0)
		sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_OPAQUE_PREPASS
		add_child(sprite)

		var label := _make_label3d(data.get("name", ""), 52, Color(1.0, 0.88, 0.58))
		add_child(label)
		var bubble := _make_label3d("", 60, Color(1.0, 0.96, 0.84))
		bubble.visible = false
		bubble.outline_size = 14
		bubble.outline_modulate = Color(0.025, 0.022, 0.018, 0.92)
		bubble.width = 420.0
		bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(bubble)
		var shadow := _add_shadow(sprite, Vector2(0.52, 0.24), 0.011)

		characters[data.get("id", sprite.name)] = {
			"sprite": sprite,
			"label": label,
			"bubble": bubble,
			"shadow": shadow,
			"data": data,
			"target": home,
			"ground_y": float(home.y),
			"lift": lift,
			"last_hour": -1,
			"bob": randf() * TAU,
		}

func _spawn_props() -> void:
	for data in world_state.get("props", []):
		var texture_path: String = PROP_TEXTURES.get(data.get("texture", ""), "")
		if texture_path == "":
			continue
		var texture: Texture2D = load(texture_path)
		var sprite := Sprite3D.new()
		sprite.name = "Prop_" + str(data.get("texture", ""))
		sprite.texture = texture
		sprite.pixel_size = _pixel_size(data)
		sprite.position = _vec2_to_world(data.get("position", [0, 0]), 0.02) + Vector3(0, _sprite_half_height(texture, sprite.pixel_size), 0)
		sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_OPAQUE_PREPASS
		add_child(sprite)
		_add_shadow(sprite, Vector2(0.55, 0.22) * float(data.get("scale", 1.0)), 0.01)

func _pixel_size(data: Dictionary) -> float:
	var density := maxf(0.001, float(data.get("density", 1.0)))
	return (1.0 / PIXELS_PER_UNIT / density) * float(data.get("scale", 1.0))

func _make_label3d(text: String, size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.font_size = size
	if ui_font != null:
		label.font = ui_font
	label.modulate = color
	label.outline_size = 10
	label.outline_modulate = Color(0.04, 0.03, 0.02, 0.95)
	return label

func _add_shadow(sprite: Sprite3D, size: Vector2, y: float) -> MeshInstance3D:
	var shadow := MeshInstance3D.new()
	shadow.name = sprite.name + "_Shadow"
	var mesh := QuadMesh.new()
	mesh.size = size
	shadow.mesh = mesh
	shadow.rotation_degrees.x = -90.0
	shadow.position = Vector3(sprite.position.x, y, sprite.position.z)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.0, 0.0, 0.0, 0.26))
	gradient.set_color(1, Color(0.0, 0.0, 0.0, 0.0))
	var gradient_tex := GradientTexture2D.new()
	gradient_tex.gradient = gradient
	gradient_tex.width = 128
	gradient_tex.height = 64
	gradient_tex.fill = GradientTexture2D.FILL_RADIAL
	gradient_tex.fill_from = Vector2(0.5, 0.5)
	gradient_tex.fill_to = Vector2(1.0, 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = gradient_tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	shadow.material_override = mat
	add_child(shadow)
	return shadow

func _add_building_light(pos: Vector3, id: String) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "%s_WindowLight" % id
	light.position = pos
	light.light_color = Color(1.0, 0.58, 0.28)
	light.light_energy = 0.0
	light.omni_range = 2.6
	add_child(light)
	building_lights.append(light)
	return light

func _vec2_to_world(value, y: float) -> Vector3:
	if value is Array and value.size() >= 2:
		return Vector3(float(value[0]), y, float(value[1]))
	return Vector3.ZERO

func _sprite_half_height(texture: Texture2D, pixel_size: float, rows: int = 1) -> float:
	if texture == null:
		return 0.0
	return float(texture.get_height()) / float(max(rows, 1)) * pixel_size * 0.5

func _update_characters(delta: float) -> void:
	var hour := int(game_time) % 24
	for key in characters:
		var c = characters[key]
		var action = _current_action(c["data"].get("schedule", []), hour)
		if action != null and action.has("location"):
			c["target"] = _vec2_to_world(action["location"], c["ground_y"])
		var sprite: Sprite3D = c["sprite"]
		var target: Vector3 = c["target"]
		var flat := Vector3(target.x - sprite.position.x, 0, target.z - sprite.position.z)
		var moving := flat.length() > 0.03
		if moving and delta > 0.0:
			sprite.position += flat.normalized() * delta * 0.72
			c["bob"] += delta * 9.0
		elif delta > 0.0:
			c["bob"] += delta * 2.8
		sprite.position.y = float(c["ground_y"]) + float(c["lift"]) + sin(c["bob"]) * 0.035
		_update_character_frame(sprite, flat, moving, c["bob"])
		c["label"].position = sprite.position + Vector3(0, 0.82, 0)
		c["bubble"].position = sprite.position + Vector3(0, 1.12, 0)
		c["shadow"].position = Vector3(sprite.position.x, 0.011, sprite.position.z)
		if action != null and action.get("text", "") != "" and c["last_hour"] != hour:
			c["last_hour"] = hour
			_show_character_speech(c, action["text"])

func _current_action(schedule: Array, hour: int):
	var current = null
	for action in schedule:
		if int(action.get("time", 0)) <= hour:
			current = action
		else:
			break
	return current

func _update_character_frame(sprite: Sprite3D, direction: Vector3, moving: bool, phase: float) -> void:
	var row := 0
	if moving:
		if abs(direction.x) > abs(direction.z):
			row = 2
			sprite.flip_h = direction.x < 0
		elif direction.z < 0:
			row = 3
		else:
			row = 1
	else:
		sprite.flip_h = false
	var col := int(floor(phase * 0.65)) % 4 if moving else int(floor(phase * 0.35)) % 4
	sprite.frame = row * 4 + col

func _show_character_speech(c: Dictionary, text: String) -> void:
	var bubble: Label3D = c["bubble"]
	bubble.text = text
	bubble.visible = true
	bubble.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(4.0)
	tween.tween_property(bubble, "modulate:a", 0.0, 0.45)
	tween.tween_callback(func(): bubble.visible = false)

func _check_events() -> void:
	var hour := int(game_time) % 24
	for event in world_state.get("events", []):
		var event_hour := int(event.get("hour", -1))
		var key := "%s-%s" % [world_state.get("day", 1), event_hour]
		if event_hour == hour and not triggered_events.has(key):
			triggered_events[key] = true
			_apply_impact(event.get("impact", {}))
			_show_event(event.get("title", "事件"), event.get("text", ""))

func _apply_impact(impact: Dictionary) -> void:
	for key in impact:
		if key == "threat":
			var threat := int(world_state.get("world", {}).get("threat", 0))
			world_state["world"]["threat"] = clamp(threat + int(impact[key]), 0, 100)
		else:
			resources[key] = clamp(int(resources.get(key, 0)) + int(impact[key]), 0, 100)

func _advance_day() -> void:
	if not replay_mode:
		return
	game_time = 6.0
	triggered_events.clear()
	for key in characters:
		characters[key]["last_hour"] = -1
	if selected_vote != "":
		for option in world_state.get("votes", {}).get("options", []):
			if option.get("id", "") == selected_vote:
				_apply_impact(option.get("impact", {}))
				_show_event("投票生效", "营地明天优先执行：" + option.get("label", ""))
				break
		selected_vote = ""
		_refresh_sheet_if_vote()
	else:
		_apply_impact({"food": -4, "water": -3, "morale": -2})
		_show_event("无人表决", "营地按最低消耗度过一夜，但士气下降。")

func _show_event(title: String, text: String) -> void:
	today_timeline.append({"time": _time_string(), "title": title, "text": text})
	if current_sheet == SheetKind.TODAY and sheet_panel.visible:
		_build_today_sheet()
	toast_title.text = title
	toast_text.text = text
	toast_panel.visible = true
	toast_panel.modulate.a = 1.0
	var original_y := 54 + _safe_top()
	toast_panel.position.y = -80
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(toast_panel, "position:y", 0.0, 0.22)
	tween.tween_interval(3.0)
	tween.tween_property(toast_panel, "position:y", -80.0, 0.2)
	tween.tween_callback(func():
		toast_panel.visible = false
		toast_panel.offset_top = original_y
		toast_panel.offset_bottom = original_y + 68
		toast_panel.position.y = 0
	)

func _time_string() -> String:
	var h := int(game_time) % 24
	var m := int((game_time - floor(game_time)) * 60.0)
	return "%02d:%02d" % [h, m]

func _resource_value(key: String) -> int:
	if key == "threat":
		return int(world_state.get("world", {}).get("threat", 0))
	return int(resources.get(key, 0))

func _update_ui() -> void:
	if status_labels.has("time"):
		status_labels["time"].text = "第%d天 %s" % [int(world_state.get("day", 1)), _time_string()]
	for key in RESOURCE_ORDER:
		if not status_labels.has(key):
			continue
		var value := _resource_value(key)
		var label: Label = status_labels[key]
		label.text = "%s%d" % [RESOURCE_LABELS.get(key, key), value]
		label.add_theme_color_override("font_color", Color(1.0, 0.32, 0.26) if value < 20 else Color(0.95, 0.88, 0.72))

func _start_replay() -> void:
	replay_mode = true
	paused = false
	game_time = 6.0
	time_speed = BASE_TIME_SPEED
	triggered_events.clear()
	today_timeline.clear()
	for key in characters:
		characters[key]["last_hour"] = -1
	_close_sheet()
	_build_replay_dock()

func _exit_replay() -> void:
	replay_mode = false
	paused = false
	time_speed = BASE_TIME_SPEED
	_set_realtime_clock()
	triggered_events.clear()
	_build_default_dock()

func _cycle_speed() -> void:
	var speeds := [BASE_TIME_SPEED, BASE_TIME_SPEED * 2.0, BASE_TIME_SPEED * 4.0]
	var current := 0
	for i in range(speeds.size()):
		if is_equal_approx(time_speed, speeds[i]):
			current = i
			break
	time_speed = speeds[(current + 1) % speeds.size()]
	paused = false

func _select_vote(option_id: String) -> void:
	selected_vote = option_id
	vote_totals[option_id] = int(vote_totals.get(option_id, 0)) + 1
	_submit_vote(option_id)
	_refresh_sheet_if_vote()
	for option in world_state.get("votes", {}).get("options", []):
		if option.get("id", "") == option_id:
			_show_event("已记录投票", option.get("description", ""))
			break

func _refresh_sheet_if_vote() -> void:
	if current_sheet == SheetKind.VOTE and sheet_panel.visible:
		_populate_sheet(SheetKind.VOTE)

func _fetch_vote_totals() -> void:
	if vote_request == null:
		return
	var endpoint := _api_url("/api/vote?day=%d" % int(world_state.get("day", 1)))
	if endpoint == "":
		return
	vote_request.request(endpoint)

func _submit_vote(option_id: String) -> void:
	if vote_request == null:
		return
	var endpoint := _api_url("/api/vote")
	if endpoint == "":
		return
	var payload := JSON.stringify({
		"day": int(world_state.get("day", 1)),
		"optionId": option_id,
	})
	vote_request.request(endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)

func _api_url(path: String) -> String:
	if OS.has_feature("web"):
		var origin = JavaScriptBridge.eval("window.location.origin")
		if origin != null and str(origin) != "":
			return str(origin) + path
	return ""

func _on_vote_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary and parsed.has("totals") and parsed["totals"] is Dictionary:
		vote_totals = parsed["totals"]
		_refresh_sheet_if_vote()

func _update_lighting(delta: float) -> void:
	var t := fmod(game_time, 24.0)
	var k := _light_keyframe(t)
	if sun != null:
		sun.light_color = k["sun_color"]
		sun.light_energy = k["sun_energy"]
		sun.rotation_degrees = k["sun_rot"]
	if world_env != null and world_env.environment != null:
		world_env.environment.ambient_light_color = k["ambient"]
		world_env.environment.background_color = k["background"]
	var night := t >= 20.0 or t < 6.0
	var flicker := 0.08 * sin(Time.get_ticks_msec() * 0.006)
	for light in building_lights:
		light.light_energy = (0.5 + flicker) if night else 0.0
	if camp_glow != null:
		camp_glow.light_energy = (0.65 + flicker * 1.8) if night else 0.18

func _light_keyframe(hour: float) -> Dictionary:
	var keys := [
		{"h": 5.0, "sun_color": Color(1.0, 0.55, 0.28), "sun_energy": 1.6, "ambient": Color(0.34, 0.25, 0.22), "background": Color(0.15, 0.12, 0.16), "sun_rot": Vector3(-34, -62, 0)},
		{"h": 12.0, "sun_color": Color(1.0, 0.94, 0.84), "sun_energy": 1.85, "ambient": Color(0.42, 0.4, 0.36), "background": Color(0.19, 0.22, 0.25), "sun_rot": Vector3(-62, -35, 0)},
		{"h": 18.0, "sun_color": Color(1.0, 0.42, 0.22), "sun_energy": 1.8, "ambient": Color(0.32, 0.21, 0.2), "background": Color(0.18, 0.11, 0.13), "sun_rot": Vector3(-24, 38, 0)},
		{"h": 21.0, "sun_color": Color(0.42, 0.55, 1.0), "sun_energy": 0.38, "ambient": Color(0.13, 0.18, 0.33), "background": Color(0.025, 0.035, 0.08), "sun_rot": Vector3(-45, 120, 0)},
		{"h": 27.5, "sun_color": Color(0.42, 0.55, 1.0), "sun_energy": 0.38, "ambient": Color(0.13, 0.18, 0.33), "background": Color(0.025, 0.035, 0.08), "sun_rot": Vector3(-45, 120, 0)},
		{"h": 29.0, "sun_color": Color(1.0, 0.55, 0.28), "sun_energy": 1.6, "ambient": Color(0.34, 0.25, 0.22), "background": Color(0.15, 0.12, 0.16), "sun_rot": Vector3(-34, -62, 0)},
	]
	var wrapped := hour if hour >= 5.0 else hour + 24.0
	for i in range(keys.size() - 1):
		var a: Dictionary = keys[i]
		var b: Dictionary = keys[i + 1]
		if wrapped >= float(a["h"]) and wrapped <= float(b["h"]):
			var p := inverse_lerp(float(a["h"]), float(b["h"]), wrapped)
			return {
				"sun_color": a["sun_color"].lerp(b["sun_color"], p),
				"sun_energy": lerp(float(a["sun_energy"]), float(b["sun_energy"]), p),
				"ambient": a["ambient"].lerp(b["ambient"], p),
				"background": a["background"].lerp(b["background"], p),
				"sun_rot": a["sun_rot"].lerp(b["sun_rot"], p),
			}
	return keys[0]

func _unhandled_input(event: InputEvent) -> void:
	if sheet_panel != null and sheet_panel.visible:
		# 只在"新的按下"时关闭，否则开 sheet 那次点击的 mouseup 会立刻把它关掉
		var pressed: bool = (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed)
		if pressed:
			_close_sheet()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_select_world_item(event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(-0.45)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(0.45)
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_pan(event.relative)

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		touch_points[event.index] = event.position
	else:
		if touch_points.size() == 1 and touch_points.has(event.index):
			_select_world_item(event.position)
		touch_points.erase(event.index)
		last_pinch_distance = 0.0

func _handle_drag(event: InputEventScreenDrag) -> void:
	touch_points[event.index] = event.position
	if touch_points.size() == 1:
		_pan(event.relative)
	elif touch_points.size() >= 2:
		var points := touch_points.values()
		var d: float = points[0].distance_to(points[1])
		if last_pinch_distance > 0.0:
			_zoom((last_pinch_distance - d) * 0.01)
		last_pinch_distance = d

func _pan(relative: Vector2) -> void:
	var right := camera.global_transform.basis.x
	var forward := -camera.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	camera.position -= right * relative.x * 0.008
	camera.position += forward * relative.y * 0.008
	_clamp_camera()

func _zoom(delta_size: float) -> void:
	camera.size = clamp(camera.size + delta_size, 4.5, 10.5)
	_clamp_camera()

func _clamp_camera() -> void:
	# 相机 z 自带 +9.8 注视偏移，边界按"注视点"折算
	camera.position.x = clamp(camera.position.x, MAP_MIN.x, MAP_MAX.x)
	camera.position.z = clamp(camera.position.z, 9.8 + MAP_MIN.y, 9.8 + MAP_MAX.y)

func _select_world_item(screen_pos: Vector2) -> void:
	var best_type := ""
	var best_key := ""
	var pick_radius := maxf(56.0, get_viewport().get_visible_rect().size.x * 0.13)
	var best_dist := pick_radius
	# 输入事件坐标在画布空间(432×936拉伸)，unproject 在窗口像素空间——必须换算到同一空间再比距离
	# 实测（web导出）：输入事件与 unproject 同在画布空间，无需换算
	var to_canvas := 1.0
	for key in characters:
		var sprite: Sprite3D = characters[key]["sprite"]
		var p := camera.unproject_position(sprite.global_position + Vector3(0, 0.45, 0)) * to_canvas
		var dist := p.distance_to(screen_pos)
		if dist < best_dist:
			best_dist = dist
			best_type = "character"
			best_key = key
	for key in buildings:
		var sprite: Sprite3D = buildings[key]["sprite"]
		var p := camera.unproject_position(sprite.global_position) * to_canvas
		var dist := p.distance_to(screen_pos)
		if dist < best_dist:
			best_dist = dist
			best_type = "building"
			best_key = key
	if best_type == "character":
		_open_sheet(SheetKind.CHARACTER, characters[best_key]["data"])
	elif best_type == "building":
		_open_sheet(SheetKind.BUILDING, buildings[best_key]["data"])
