# 任务：渲染层重构——整图底板 2D 化（main_2d）

## 背景与目标

Major 定标：画面必须达到 `assets_hd2d/style/style-board.png` 的密度与质感。瓦片+单体 sprite 拼装到不了，已切换路线：**地形+建筑+装饰全部烘焙在一张竖版"营地底板"大图里，只有角色、火焰、光效、气泡是动态层**。

同时根治三个体验 bug：
1. **人物飘着**：现 `main_hd2d.gd:808` 用 `sin(bob)*0.035` 做垂直浮动 → 必须删除，改为纯走路帧动画；影子必须钉在脚底
2. **走动不自然**：现在匀速直线滑向目标（穿建筑、脚底打滑）→ 改为沿路径图（path graph）寻路行走，帧率与移动速度同步
3. **比例失调**：角色相对建筑过小 → 按底板中"门高"校准角色身高（角色身高 ≈ 门高 × 0.92），并随 y 做轻微透视缩放

## 产出物（只许写这些文件，其他一律不动）

- `scenes/main_2d.tscn` —— 新主场景（Node2D 根）
- `scripts/main_2d.gd` —— 新主脚本
- `data/backdrop_anchors.json` —— 锚点数据（先写占位版，坐标我后续人工标定覆盖）
- `project.godot` —— 仅改 main scene 指向 main_2d.tscn

**禁止**：改 `main_hd2d.gd/tscn`（保留回滚）、改 `world-state.json`、碰 `.git/`、执行导出（沙箱对 out/ 只读，导出由我做）。

## 场景结构

```
Main (Node2D, scripts/main_2d.gd)
├── Backdrop (Sprite2D)            # assets_hd2d/backdrop/dusk.png，centered=false，位于(0,0)
├── World (Node2D, y_sort_enabled) # 所有动态体
│   ├── 角色 ×N (Node2D 容器: Sprite2D 走路图 + 影子 + Label 名字 + 气泡)
│   ├── Occluder ×N (Sprite2D)     # 建筑前景切片，y_sort 锚点=其底边
│   └── Flame (Sprite2D, 4帧)      # 篝火火焰 + 闪烁光晕
├── Camera2D
├── TiltShiftLayer (CanvasLayer)   # 移植现有 shader
├── CanvasModulate                 # 昼夜调色
└── UI (CanvasLayer)               # 整体移植现有 UI（见下）
```

## backdrop_anchors.json 结构（先写占位，坐标全部用 0~1 归一化 UV，相对底板图片）

```json
{
  "door_height_uv": 0.045,
  "char_scale_far": 0.85, "char_scale_near": 1.1,
  "spots": {
    "radio_door": [0.18, 0.30], "greenhouse_door": [0.50, 0.26],
    "bunker_door": [0.80, 0.28], "watch_base": [0.78, 0.52],
    "kitchen_front": [0.48, 0.58], "campfire": [0.30, 0.66],
    "garden": [0.55, 0.82], "gate": [0.45, 0.93]
  },
  "paths": [["radio_door","campfire"],["greenhouse_door","kitchen_front"],["bunker_door","watch_base"],["watch_base","kitchen_front"],["kitchen_front","campfire"],["campfire","garden"],["garden","gate"],["kitchen_front","garden"]],
  "buildings": {
    "radio":      {"click_rect": [0.06,0.10,0.30,0.32], "light": [0.18,0.22]},
    "greenhouse": {"click_rect": [0.36,0.10,0.64,0.28], "light": [0.50,0.20]},
    "bunker":     {"click_rect": [0.68,0.12,0.94,0.30], "light": [0.80,0.22]},
    "watch":      {"click_rect": [0.66,0.36,0.92,0.54], "light": [0.78,0.44]},
    "kitchen":    {"click_rect": [0.34,0.44,0.62,0.60], "light": [0.48,0.52]}
  },
  "occluders": []
}
```

## 关键实现规则

### 坐标与比例
- 全部游戏逻辑坐标 = 归一化 UV × 底板纹理尺寸（运行时读 `texture.get_size()`，不许写死像素）
- 角色 Sprite2D：`offset` 设为脚底锚定（offset.y = -frame_height/2，使 Node2D.position == 脚底点）
- 角色缩放：`base_scale = door_height_uv * tex_h * 0.92 / frame_h`，再乘 `lerp(char_scale_far, char_scale_near, uv_y)`
- Y-sort：角色与 occluder 都用脚底/底边 y 排序（Node2D position.y 即是）

### 走路（修"不自然"）
- 角色在 spots 图上做最短路寻路（节点少，Dijkstra/BFS 即可），沿折线段行走，不许直线穿场
- world-state 的 schedule 兼容两种写法：`"spot": "kitchen_front"`（优先）或老的 `"location": [x,z]`（用一张旧坐标→最近 spot 的映射表换算，映射表写在脚本常量里，按 spots 占位坐标最近邻即可）
- 帧同步：`anim_fps = walk_speed_px / (char_height_px * 1.4) * 4.0`；走路播 row 行 4 帧循环；**删除一切 sin 浮动**
- 待机：只在 frame 0/1 之间以 1.2s 间隔交替（呼吸感），不播走路帧
- 方向：按当前线段方向选 row（下=1 侧=2 上=3，待机=0），侧向用 flip_h
- 到达 spot 后停在 spot 附近随机 ±8px 偏移（避免两人完全重叠）

### 影子（修"飘着"）
- 每角色一个椭圆软影（GradientTexture2D 径向，同现有做法），作为角色容器子节点，position=(0,1px)，**永远贴脚底**
- 影子宽 = 角色显示宽 × 0.7，高=宽×0.42；走路时以 anim 相位轻微缩放 ±4%（踩步感）
- 移动、缩放全部跟随角色容器，不独立摆放

### 相机三状态
- **全景（默认）**：zoom 取"底板完整高度装进 状态条底边~dock 顶边 之间"的值并水平居中；启动即此状态
- **探索**：双指捏合放大（zoom 上限 = 全景 zoom × 3）后单指拖拽，clamp 到底板边界（带 0.15s 回弹 tween）；**双击/双触 回到全景**
- **跟随**：人物 sheet 里加"跟随TA"按钮 → 相机 tween 到该角色并以全景 zoom × 2.2 持续跟随；任何手动拖拽/双击退出跟随
- 鼠标滚轮=缩放、中键拖=平移（桌面调试用），保留

### 昼夜（先做调色版，四时段底板后续再换）
- CanvasModulate 颜色按现有 `_light_keyframe` 的时段插值逻辑移植（保留 27.5h 保持帧技巧），输出乘到画面
- 夜间（20:00-06:00）：建筑 light 点位放 additive 暖光 sprite（半径约 door_height×2 的径向渐变），能量随 flicker 抖动；篝火光晕常亮、夜间增强
- 火焰 Sprite2D：`assets_hd2d/props/flame.png`（1×4 帧，若文件不存在则先用占位 ColorRect 并 TODO 注释）放在 campfire spot，0.12s/帧循环

### UI 与交互（整体移植，不重新发明）
- status bar / dock / bottom sheet / toast / 投票（含 HTTP）/ 今日时间线 / 回放模式 / 实时时钟：**从 main_hd2d.gd 原样移植**，仅把 3D 拾取换成 2D：
  - 点击：屏幕坐标 → `get_canvas_transform().affine_inverse()` → 世界坐标；先判角色（脚底点距离 < 角色显示高×0.6），再判 building click_rect（UV rect）
  - sheet 打开时点外关闭的"只响应新 press"修复逻辑必须保留（main_hd2d.gd:1051-1058 的注释说明了原因）
- 人物 sheet 头像：继续用走路图第 0 帧 AtlasTexture 裁切
- 事件/投票/回放逻辑不改语义

### 纹理设置
- 底板与角色全部 `TEXTURE_FILTER_NEAREST`
- 底板路径常量：`res://assets_hd2d/backdrop/dusk.png`（文件由我放置；若不存在，加载失败时用纯色 ColorRect 兜底并 print 警告，**不许 crash**）

## 验收清单（你完成后逐项自验并在 _codex_backdrop2d_report.md 里写明）

1. `godot --headless --check-only`（或 `--import`）无脚本 Parse Error —— 注意 Godot 4 GDScript 用 `maxf/minf` 而非 `max/min`（浮点），上次踩过
2. main_2d.gd 中不存在任何 `sin(` 参与角色 position.y 的代码
3. 角色影子节点是角色容器的子节点（grep 验证层级）
4. schedule 的 spot 寻路：写一个最小单测函数 `_test_pathfind()`（_ready 里 print 结果）验证 radio_door→garden 能给出途经 campfire 的路径
5. project.godot 主场景已指向 main_2d.tscn
6. 报告中列出：你对占位 anchors 坐标的任何假设、待我人工标定的项

## 已知坑（必读）

- Godot 4.5：`max()` 传 float 会 Parse Error，用 `maxf()`
- 沙箱对 `.git/` 和 `out/` 只读，别尝试导出或 commit
- web 导出下 InputEventScreenTouch 与 Mouse 事件并存，触摸选择逻辑参考 main_hd2d.gd `_handle_touch`
- 中文字体必须用 `assets_hd2d/fonts/NotoSansSC-Regular.ttf`（Label3D 换 Label 后同样要 add_theme_font_override）
