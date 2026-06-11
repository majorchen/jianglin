extends Node2D

# 整图底板 2D 路线：地形+建筑烘焙在 backdrop/dusk.png，
# 只有角色/火焰/光效/气泡是动态层。详见 PLAN-mobile-hd2d.md 第七节。

const WORLD_STATE_PATH := "res://data/world-state.json"
const ANCHORS_PATH := "res://data/backdrop_anchors.json"
const BACKDROP_TEXTURE := "res://assets_hd2d/backdrop/dusk.png"
const FLAME_TEXTURE := "res://assets_hd2d/props/flame.png"
const FONT_PATH := "res://assets_hd2d/fonts/NotoSansSC-Regular.ttf"
const BASE_TIME_SPEED := 0.18
const SHEET_HEIGHT_RATIO := 0.54
const WALK_SPEED_PX := 80.0          # 底板像素/秒
const STRIDE_FACTOR := 1.3           # 一个4帧步行循环走过 角色身高×此系数 的距离
const EXPLORE_ZOOM_MAX := 3.0
const FOLLOW_ZOOM := 2.2
const DOUBLE_TAP_MS := 350
const TAP_SLOP_PX := 28.0
# 旧 world-state 的 location 坐标（世界单位）→ 最近 spot 的参照表
const LEGACY_SPOT_COORDS := {
	"radio_door": Vector2(-3.25, -2.0),
	"greenhouse_door": Vector2(0.0, -2.25),
	"bunker_door": Vector2(3.15, -2.0),
	"watch_base": Vector2(3.0, 1.55),
	"kitchen_front": Vector2(-1.1, 2.45),
	"campfire": Vector2(-0.5, 1.55),
	"garden": Vector2(0.45, -0.25),
	"gate": Vector2(-0.35, 2.65),
}
const CHARACTER_TEXTURES := {
	"engineer": "res://assets_hd2d/characters/engineer_walk_sheet.png",
	"scientist": "res://assets_hd2d/characters/scientist_walk_sheet.png",
	"scavenger": "res://assets_hd2d/characters/scavenger_walk_sheet.png",
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

var backdrop: Sprite2D
var backdrop_size := Vector2(941, 1672)
var world: Node2D
var overlay: CanvasLayer
var canvas_modulate: CanvasModulate
var camera: Camera2D
var anchors: Dictionary = {}
var spot_px: Dictionary = {}         # spot 名 → 底板像素坐标
var adjacency: Dictionary = {}       # spot 名 → [相邻 spot 名]
var char_base_height := 62.0         # 角色显示身高（底板像素，由 door_height_uv 推出）

var overview_zoom := 0.45
var camera_mode := "overview"        # overview / explore / follow
var follow_character_id := ""
var last_tap_msec := 0
var last_tap_pos := Vector2.ZERO
var touch_press_pos: Dictionary = {}

var tilt_layer: CanvasLayer
var tilt_rect: ColorRect
var touch_points: Dictionary = {}
var last_pinch_distance := 0.0
var characters: Dictionary = {}
var buildings: Dictionary = {}
var building_glows: Array[Sprite2D] = []
var fire_glow: Sprite2D
var flame: Sprite2D
var flame_phase := 0.0
var triggered_events: Dictionary = {}
var today_timeline: Array[Dictionary] = []
var selected_vote := ""
var vote_totals: Dictionary = {}
var vote_request: HTTPRequest
var current_sheet := SheetKind.NONE
var current_sheet_payload: Dictionary = {}

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
	RenderingServer.set_default_clear_color(Color(0.02, 0.02, 0.022))
	ui_font = ResourceLoader.load(FONT_PATH)
	_load_world_state()
	_load_anchors()
	_setup_world()
	_setup_tilt_shift()
	_setup_runtime_ui()
	_setup_network()
	_spawn_buildings()
	_spawn_flame()
	_spawn_characters()
	_fit_overview_camera()
	_set_realtime_clock()
	_update_characters(0.0)
	_update_lighting()
	_update_ui()
	_fetch_vote_totals()
	_test_pathfind()
	print("[降临] backdrop 2D ready, size=", backdrop_size)

func _process(delta: float) -> void:
	if replay_mode:
		if not paused:
			game_time += delta * time_speed
			if game_time >= 24.0:
				_advance_day()
	else:
		_set_realtime_clock()
	_update_characters(delta)
	_update_flame(delta)
	_update_camera_follow(delta)
	_check_events()
	_update_lighting()
	_update_ui()

# ---------- 数据加载 ----------

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

func _load_anchors() -> void:
	var file := FileAccess.open(ANCHORS_PATH, FileAccess.READ)
	if file == null:
		push_warning("[降临] backdrop_anchors.json 缺失，使用空锚点")
		anchors = {}
		return
	var parsed = JSON.parse_string(file.get_as_text())
	anchors = parsed if parsed is Dictionary else {}

func _build_spot_graph() -> void:
	spot_px.clear()
	adjacency.clear()
	var spots: Dictionary = anchors.get("spots", {})
	for name in spots:
		var uv = spots[name]
		spot_px[name] = _uv_to_px(uv)
		adjacency[name] = []
	for edge in anchors.get("paths", []):
		if edge is Array and edge.size() == 2:
			var a := str(edge[0])
			var b := str(edge[1])
			if adjacency.has(a) and adjacency.has(b):
				adjacency[a].append(b)
				adjacency[b].append(a)

func _uv_to_px(uv) -> Vector2:
	if uv is Array and uv.size() >= 2:
		return Vector2(float(uv[0]) * backdrop_size.x, float(uv[1]) * backdrop_size.y)
	return backdrop_size * 0.5

# ---------- 场景搭建 ----------

func _setup_world() -> void:
	backdrop = Sprite2D.new()
	backdrop.name = "Backdrop"
	backdrop.centered = false
	if ResourceLoader.exists(BACKDROP_TEXTURE):
		backdrop.texture = load(BACKDROP_TEXTURE)
		backdrop_size = backdrop.texture.get_size()
	else:
		push_warning("[降临] 底板纹理缺失：" + BACKDROP_TEXTURE)
	backdrop.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(backdrop)

	world = Node2D.new()
	world.name = "World"
	world.y_sort_enabled = true
	add_child(world)

	# 发光体与文字层：独立 canvas，不被 CanvasModulate 昼夜调色染色
	overlay = CanvasLayer.new()
	overlay.name = "Overlay"
	overlay.layer = 0
	overlay.follow_viewport_enabled = true
	add_child(overlay)

	canvas_modulate = CanvasModulate.new()
	canvas_modulate.name = "DayNight"
	canvas_modulate.color = Color(1, 1, 1)
	add_child(canvas_modulate)

	camera = Camera2D.new()
	camera.name = "Camera"
	add_child(camera)
	camera.make_current()
	get_viewport().size_changed.connect(_on_viewport_resized)

	_build_spot_graph()
	char_base_height = float(anchors.get("door_height_uv", 0.043)) * backdrop_size.y * 0.92

func _fit_overview_camera() -> void:
	var vp := get_viewport().get_visible_rect().size
	var top_chrome := 56.0 + _safe_top()
	var bottom_chrome := 72.0 + _safe_bottom()
	var avail_h := vp.y - top_chrome - bottom_chrome
	overview_zoom = minf((vp.x - 12.0) / backdrop_size.x, avail_h / backdrop_size.y)
	camera.zoom = Vector2(overview_zoom, overview_zoom)
	camera.position = backdrop_size * 0.5 + Vector2(0, (bottom_chrome - top_chrome) * 0.5 / overview_zoom)
	camera_mode = "overview"
	follow_character_id = ""

func _on_viewport_resized() -> void:
	var was_overview := camera_mode == "overview"
	var vp := get_viewport().get_visible_rect().size
	var avail_h := vp.y - (56.0 + _safe_top()) - (72.0 + _safe_bottom())
	overview_zoom = minf((vp.x - 12.0) / backdrop_size.x, avail_h / backdrop_size.y)
	if was_overview:
		_fit_overview_camera()
	else:
		_clamp_camera()

func _camera_to_overview() -> void:
	camera_mode = "overview"
	follow_character_id = ""
	var vp := get_viewport().get_visible_rect().size
	var top_chrome := 56.0 + _safe_top()
	var bottom_chrome := 72.0 + _safe_bottom()
	var target_pos := backdrop_size * 0.5 + Vector2(0, (bottom_chrome - top_chrome) * 0.5 / overview_zoom)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.set_parallel(true)
	tween.tween_property(camera, "zoom", Vector2(overview_zoom, overview_zoom), 0.28)
	tween.tween_property(camera, "position", target_pos, 0.28)

# ---------- 动态体 ----------

func _spawn_buildings() -> void:
	# 建筑本体已烘焙进底板；这里只挂 点击区 + 夜间窗灯
	var anchor_buildings: Dictionary = anchors.get("buildings", {})
	for data in world_state.get("buildings", []):
		if not bool(data.get("unlocked", true)):
			continue
		var id := str(data.get("id", ""))
		var info: Dictionary = anchor_buildings.get(id, {})
		var glow: Sprite2D = null
		if info.has("light"):
			glow = _make_glow(char_base_height * 2.2, Color(1.0, 0.62, 0.3))
			glow.position = _uv_to_px(info["light"])
			glow.modulate.a = 0.0
			overlay.add_child(glow)
			building_glows.append(glow)
		buildings[id] = {"data": data, "rect": _click_rect_px(info), "glow": glow}

func _click_rect_px(info: Dictionary) -> Rect2:
	var r = info.get("click_rect", null)
	if r is Array and r.size() >= 4:
		var p1 := Vector2(float(r[0]) * backdrop_size.x, float(r[1]) * backdrop_size.y)
		var p2 := Vector2(float(r[2]) * backdrop_size.x, float(r[3]) * backdrop_size.y)
		return Rect2(p1, p2 - p1)
	return Rect2()

func _make_glow(radius: float, color: Color) -> Sprite2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(color.r, color.g, color.b, 0.5))
	gradient.set_color(1, Color(color.r, color.g, color.b, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.scale = Vector2.ONE * (radius * 2.0 / 256.0)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sprite.material = mat
	return sprite

func _spawn_flame() -> void:
	var pos: Vector2 = spot_px.get("campfire", backdrop_size * 0.5)
	fire_glow = _make_glow(char_base_height * 2.8, Color(1.0, 0.52, 0.2))
	fire_glow.position = pos
	overlay.add_child(fire_glow)
	if ResourceLoader.exists(FLAME_TEXTURE):
		flame = Sprite2D.new()
		flame.name = "Flame"
		flame.texture = load(FLAME_TEXTURE)
		flame.hframes = 4
		flame.frame = 0
		flame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var frame_h := float(flame.texture.get_height())
		var target_h := char_base_height * 0.8
		flame.scale = Vector2.ONE * (target_h / maxf(frame_h, 1.0))
		flame.offset = Vector2(0, -frame_h * 0.5)
		flame.position = pos
		overlay.add_child(flame)

func _update_flame(delta: float) -> void:
	if flame != null:
		flame_phase += delta
		flame.frame = int(flame_phase / 0.12) % 4

func _spawn_characters() -> void:
	for data in world_state.get("characters", []):
		var texture_path: String = CHARACTER_TEXTURES.get(data.get("archetype", ""), "")
		var texture: Texture2D = load(texture_path)
		var frame_size := Vector2(texture.get_width() / 4.0, texture.get_height() / 4.0)

		var container := Node2D.new()
		container.name = str(data.get("id", data.get("name", "角色")))
		var home_spot := _nearest_spot_for_legacy(data.get("home", [0, 0]))
		container.position = spot_px.get(home_spot, backdrop_size * 0.5) + _spot_jitter()
		world.add_child(container)

		var shadow := Sprite2D.new()
		shadow.name = "Shadow"
		var gradient := Gradient.new()
		gradient.set_color(0, Color(0, 0, 0, 0.34))
		gradient.set_color(1, Color(0, 0, 0, 0.0))
		var shadow_tex := GradientTexture2D.new()
		shadow_tex.gradient = gradient
		shadow_tex.width = 64
		shadow_tex.height = 32
		shadow_tex.fill = GradientTexture2D.FILL_RADIAL
		shadow_tex.fill_from = Vector2(0.5, 0.5)
		shadow_tex.fill_to = Vector2(1.0, 0.5)
		shadow.texture = shadow_tex
		shadow.scale = Vector2(frame_size.x * 0.74 / 64.0, frame_size.x * 0.40 / 64.0)
		shadow.position = Vector2(0, 1)
		container.add_child(shadow)

		var sprite := Sprite2D.new()
		sprite.name = "Body"
		sprite.texture = texture
		sprite.hframes = 4
		sprite.vframes = 4
		sprite.frame = 0
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.offset = Vector2(0, -frame_size.y * 0.5)  # 脚底锚定在 container 原点
		container.add_child(sprite)

		var name_label := _make_overlay_label(str(data.get("name", "")), 26, Color(1.0, 0.88, 0.58), 160)
		overlay.add_child(name_label)
		var bubble := _make_overlay_label("", 28, Color(1.0, 0.96, 0.84), 250)
		bubble.visible = false
		overlay.add_child(bubble)

		characters[data.get("id", container.name)] = {
			"container": container,
			"sprite": sprite,
			"shadow": shadow,
			"shadow_base": shadow.scale,
			"label": name_label,
			"bubble": bubble,
			"data": data,
			"frame_size": frame_size,
			"spot": home_spot,
			"target_spot": home_spot,
			"route": [],
			"route_i": 0,
			"walked": randf() * 100.0,
			"idle_t": randf() * 4.0,
			"facing_row": 0,
			"flip": false,
			"last_hour": -1,
		}
		_apply_character_scale(characters[data.get("id", container.name)])

func _spot_jitter() -> Vector2:
	return Vector2(randf_range(-10.0, 10.0), randf_range(-6.0, 6.0))

func _make_overlay_label(text: String, size: int, color: Color, width: float) -> Label:
	var label := Label.new()
	label.text = text
	label.size = Vector2(width, 64 if width < 200.0 else 96)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.04, 0.03, 0.02, 0.95))
	label.add_theme_constant_override("outline_size", 7)
	if ui_font != null:
		label.add_theme_font_override("font", ui_font)
	return label

func _apply_character_scale(c: Dictionary) -> void:
	var container: Node2D = c["container"]
	var frame_size: Vector2 = c["frame_size"]
	var depth: float = clampf(container.position.y / backdrop_size.y, 0.0, 1.0)
	var perspective: float = lerpf(float(anchors.get("char_scale_far", 0.85)), float(anchors.get("char_scale_near", 1.12)), depth)
	var s: float = char_base_height / maxf(frame_size.y, 1.0) * perspective
	container.scale = Vector2(s, s)

# ---------- 寻路与行走 ----------

func _nearest_spot_for_legacy(loc) -> String:
	if not (loc is Array and loc.size() >= 2):
		return "campfire"
	var p := Vector2(float(loc[0]), float(loc[1]))
	var best := "campfire"
	var best_d := INF
	for name in LEGACY_SPOT_COORDS:
		var d: float = p.distance_squared_to(LEGACY_SPOT_COORDS[name])
		if d < best_d and spot_px.has(name):
			best_d = d
			best = name
	return best

func _action_spot(action: Dictionary) -> String:
	if action.has("spot") and spot_px.has(str(action["spot"])):
		return str(action["spot"])
	return _nearest_spot_for_legacy(action.get("location", null))

func _find_route(from_spot: String, to_spot: String) -> Array:
	# spot 图很小，BFS 足够
	if from_spot == to_spot or not adjacency.has(from_spot) or not adjacency.has(to_spot):
		return []
	var prev := {from_spot: ""}
	var queue := [from_spot]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		if cur == to_spot:
			break
		for next in adjacency[cur]:
			if not prev.has(next):
				prev[next] = cur
				queue.append(next)
	if not prev.has(to_spot):
		return [to_spot]  # 不连通时直走兜底
	var route := []
	var cur := to_spot
	while cur != from_spot and cur != "":
		route.push_front(cur)
		cur = prev[cur]
	return route

func _update_characters(delta: float) -> void:
	var hour := int(game_time) % 24
	for key in characters:
		var c = characters[key]
		var action = _current_action(c["data"].get("schedule", []), hour)
		if action != null:
			var want := _action_spot(action)
			if want != c["target_spot"]:
				c["target_spot"] = want
				c["route"] = _find_route(c["spot"], want)
				c["route_i"] = 0
		_step_character(c, delta)
		_sync_character_attachments(c)
		if action != null and action.get("text", "") != "" and c["last_hour"] != hour:
			c["last_hour"] = hour
			_show_character_speech(c, action["text"])

func _step_character(c: Dictionary, delta: float) -> void:
	var container: Node2D = c["container"]
	var route: Array = c["route"]
	var moving := false
	if c["route_i"] < route.size():
		var target: Vector2 = spot_px[route[c["route_i"]]] + _stable_jitter(c)
		var to_target := target - container.position
		var step := WALK_SPEED_PX * delta
		if to_target.length() <= step + 2.0:
			container.position = target
			c["spot"] = route[c["route_i"]]
			c["route_i"] = int(c["route_i"]) + 1
		else:
			container.position += to_target.normalized() * step
			moving = true
			c["walked"] = float(c["walked"]) + step
			_set_facing(c, to_target)
		_apply_character_scale(c)
	if moving:
		var stride := char_base_height * STRIDE_FACTOR
		var col := int(floor(float(c["walked"]) / stride * 4.0)) % 4
		c["sprite"].frame = int(c["facing_row"]) * 4 + col
		c["sprite"].flip_h = bool(c["flip"])
		var pulse := 1.0 + 0.04 * sin(float(c["walked"]) / stride * TAU * 2.0)
		c["shadow"].scale = Vector2(c["shadow_base"].x * pulse, c["shadow_base"].y)
	else:
		# 待机：row0 慢速呼吸帧，无任何位移浮动
		c["idle_t"] = float(c["idle_t"]) + delta
		c["sprite"].frame = int(floor(float(c["idle_t"]) * 1.2)) % 4
		c["sprite"].flip_h = false
		c["facing_row"] = 0
		c["shadow"].scale = c["shadow_base"]

func _stable_jitter(c: Dictionary) -> Vector2:
	# 同一角色对同一 spot 的偏移固定，避免两人重叠又不来回抖
	var h := absi(hash(str(c["data"].get("id", "")) + str(c["target_spot"])))
	return Vector2(float(h % 21) - 10.0, float((h / 21) % 13) - 6.0)

func _set_facing(c: Dictionary, direction: Vector2) -> void:
	if absf(direction.x) > absf(direction.y):
		c["facing_row"] = 2
		c["flip"] = direction.x < 0.0
	elif direction.y < 0.0:
		c["facing_row"] = 3
		c["flip"] = false
	else:
		c["facing_row"] = 1
		c["flip"] = false

func _sync_character_attachments(c: Dictionary) -> void:
	var container: Node2D = c["container"]
	var char_h: float = c["frame_size"].y * container.scale.y
	var label: Label = c["label"]
	label.position = container.position + Vector2(-label.size.x * 0.5, -char_h - label.size.y - 2.0)
	var bubble: Label = c["bubble"]
	bubble.position = container.position + Vector2(-bubble.size.x * 0.5, -char_h - label.size.y - bubble.size.y - 6.0)

func _current_action(schedule: Array, hour: int):
	var current = null
	for action in schedule:
		if int(action.get("time", 0)) <= hour:
			current = action
		else:
			break
	return current

func _show_character_speech(c: Dictionary, text: String) -> void:
	var bubble: Label = c["bubble"]
	bubble.text = text
	bubble.visible = true
	bubble.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(4.0)
	tween.tween_property(bubble, "modulate:a", 0.0, 0.45)
	tween.tween_callback(func(): bubble.visible = false)

func _test_pathfind() -> void:
	var route := _find_route("radio_door", "garden")
	print("[降临] pathfind radio_door→garden: ", route)

# ---------- 相机 ----------

func _update_camera_follow(delta: float) -> void:
	if camera_mode != "follow" or not characters.has(follow_character_id):
		return
	var target: Vector2 = characters[follow_character_id]["container"].position
	camera.position = camera.position.lerp(target, 1.0 - exp(-6.0 * delta))
	_clamp_camera()

func _start_follow(character_id: String) -> void:
	if not characters.has(character_id):
		return
	camera_mode = "follow"
	follow_character_id = character_id
	var z := overview_zoom * FOLLOW_ZOOM
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(camera, "zoom", Vector2(z, z), 0.3)

func _pan(relative: Vector2) -> void:
	if camera.zoom.x <= overview_zoom * 1.05:
		return  # 全景态不允许拖拽
	if camera_mode == "follow":
		camera_mode = "explore"
		follow_character_id = ""
	camera.position -= relative / camera.zoom.x
	_clamp_camera()

func _zoom(factor: float) -> void:
	var z: float = clampf(camera.zoom.x * factor, overview_zoom, overview_zoom * EXPLORE_ZOOM_MAX)
	camera.zoom = Vector2(z, z)
	if z <= overview_zoom * 1.02:
		_camera_to_overview()
	elif camera_mode == "overview":
		camera_mode = "explore"
	_clamp_camera()

func _clamp_camera() -> void:
	var vp := get_viewport().get_visible_rect().size
	var half := vp * 0.5 / camera.zoom.x
	if half.x * 2.0 >= backdrop_size.x:
		camera.position.x = backdrop_size.x * 0.5
	else:
		camera.position.x = clampf(camera.position.x, half.x, backdrop_size.x - half.x)
	if half.y * 2.0 >= backdrop_size.y:
		camera.position.y = backdrop_size.y * 0.5
	else:
		camera.position.y = clampf(camera.position.y, half.y, backdrop_size.y - half.y)

# ---------- 光照与昼夜 ----------

func _update_lighting() -> void:
	var t := fmod(game_time, 24.0)
	canvas_modulate.color = _daylight_color(t)
	var night := t >= 20.0 or t < 6.0
	var flicker := 0.08 * sin(Time.get_ticks_msec() * 0.006)
	for glow in building_glows:
		glow.modulate.a = (0.62 + flicker) if night else 0.0
	if fire_glow != null:
		fire_glow.modulate.a = (0.85 + flicker * 2.0) if night else (0.4 + flicker)

func _daylight_color(hour: float) -> Color:
	# 底板本身是黄昏光，17:00 为恒等色；其余时段做色彩偏移
	var keys := [
		{"h": 5.0, "c": Color(0.58, 0.50, 0.50)},
		{"h": 7.0, "c": Color(0.94, 0.84, 0.78)},
		{"h": 12.0, "c": Color(1.0, 0.98, 0.94)},
		{"h": 17.0, "c": Color(1.0, 1.0, 1.0)},
		{"h": 19.5, "c": Color(0.82, 0.64, 0.56)},
		{"h": 21.0, "c": Color(0.36, 0.40, 0.58)},
		{"h": 27.5, "c": Color(0.36, 0.40, 0.58)},
		{"h": 29.0, "c": Color(0.58, 0.50, 0.50)},
	]
	var wrapped := hour if hour >= 5.0 else hour + 24.0
	for i in range(keys.size() - 1):
		var a: Dictionary = keys[i]
		var b: Dictionary = keys[i + 1]
		if wrapped >= float(a["h"]) and wrapped <= float(b["h"]):
			var p := inverse_lerp(float(a["h"]), float(b["h"]), wrapped)
			return (a["c"] as Color).lerp(b["c"] as Color, p)
	return keys[0]["c"]

# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if sheet_panel != null and sheet_panel.visible:
		# 只在"新的按下"时关闭，否则开 sheet 那次点击的 mouseup 会立刻把它关掉
		var pressed: bool = (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed)
		if pressed:
			_close_sheet()
			# 双击建筑/角色时首击会开卡：第二击除了关卡还要回全景
			_check_double_tap(event.position)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _check_double_tap(event.position):
				return
			_select_world_item(event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1.12)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0 / 1.12)
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_pan(event.relative)

func _check_double_tap(pos: Vector2) -> bool:
	var now := Time.get_ticks_msec()
	var is_double: bool = now - last_tap_msec < DOUBLE_TAP_MS and pos.distance_to(last_tap_pos) < 60.0
	last_tap_msec = now
	last_tap_pos = pos
	if is_double:
		_camera_to_overview()
	return is_double

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		touch_points[event.index] = event.position
		touch_press_pos[event.index] = event.position
	else:
		var press: Vector2 = touch_press_pos.get(event.index, event.position)
		if touch_points.size() == 1 and touch_points.has(event.index) \
			and event.position.distance_to(press) < TAP_SLOP_PX:
			if not _check_double_tap(event.position):
				_select_world_item(event.position)
		touch_points.erase(event.index)
		touch_press_pos.erase(event.index)
		last_pinch_distance = 0.0

func _handle_drag(event: InputEventScreenDrag) -> void:
	touch_points[event.index] = event.position
	if touch_points.size() == 1:
		_pan(event.relative)
	elif touch_points.size() >= 2:
		var points := touch_points.values()
		var d: float = points[0].distance_to(points[1])
		if last_pinch_distance > 0.0 and d > 0.0:
			_zoom(d / last_pinch_distance)
		last_pinch_distance = d

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * screen_pos

func _select_world_item(screen_pos: Vector2) -> void:
	var world_pos := _screen_to_world(screen_pos)
	var best_key := ""
	var best_dist := INF
	for key in characters:
		var c = characters[key]
		var container: Node2D = c["container"]
		var char_h: float = c["frame_size"].y * container.scale.y
		var center: Vector2 = container.position - Vector2(0, char_h * 0.5)
		var dist := center.distance_to(world_pos)
		if dist < char_h * 0.9 and dist < best_dist:
			best_dist = dist
			best_key = key
	if best_key != "":
		_open_sheet(SheetKind.CHARACTER, characters[best_key]["data"])
		return
	for key in buildings:
		var rect: Rect2 = buildings[key]["rect"]
		if rect.has_area() and rect.has_point(world_pos):
			_open_sheet(SheetKind.BUILDING, buildings[key]["data"])
			return

# ---------- UI（移植自 main_hd2d，逻辑不变） ----------

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
			# 双击建筑/角色时首击会开卡：第二击除了关卡还要回全景
			_check_double_tap(event.position)
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
		speed_btn.text = "倍速 %.0fx" % maxf(1.0, time_speed / BASE_TIME_SPEED)
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
	var world_data: Dictionary = world_state.get("world", {})
	var title := _new_label(world_state.get("title", "降临"), 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.5))
	sheet_body.add_child(title)
	sheet_body.add_child(_new_label("威胁 %d · 天气 %s" % [int(world_data.get("threat", 0)), world_data.get("weather", "unknown")], 16))
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
	var follow_btn := _new_button("跟随TA", 16)
	var char_id := str(data.get("id", ""))
	follow_btn.pressed.connect(func():
		_close_sheet()
		_start_follow(char_id)
	)
	sheet_body.add_child(follow_btn)
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

# ---------- 事件 / 投票 / 回放（移植自 main_hd2d，逻辑不变） ----------

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
