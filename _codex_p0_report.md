# 降临 jianglin 手机端 P0 + P0.5 交付报告

## 做了什么

- `project.godot` viewport 改为 `432x936`，保留 `canvas_items / expand`。
- 重构 `scripts/main_hd2d.gd` 运行时 UI：
  - 顶部只保留一条紧凑状态条，显示第 N 天、时刻、食/水/电/药/士/威，低于 20 红色高亮。
  - 底部 dock 改为 `今日 / 投票 / 营地` 三 tab；回放模式下切换为 `退出回放 / 暂停 / 倍速`。
  - 新增可复用 bottom sheet：今日、投票、营地、人物卡、建筑卡统一从底部滑出，外部点击关闭。
  - 投票选项显示描述文本，点击后本地乐观更新票数并高亮选中项，保留 `/api/vote` 相关逻辑。
  - 删除运行时全局台词条/中央卡片使用，角色台词改为各自头顶 `Label3D` 气泡，4 秒淡出。
  - 事件改为顶部 toast，并追加到今日时间线。
  - sheet 打开时世界点击只关闭 sheet，并调用 `set_input_as_handled()`。
- 时间系统：
  - 默认实时模式使用本机本地 hour/minute。
  - `回放今日` 从 06:00 开始快进，暂停/倍速只在回放模式出现。
  - `_advance_day()` 只在回放模式生效，实时模式不推进 day。
- HD-2D 渲染升级：
  - Sprite3D 去掉 `no_depth_test`，改 `BILLBOARD_FIXED_Y`，启用 `ALPHA_CUT_OPAQUE_PREPASS`。
  - 角色和建筑加椭圆软影，角色影子跟随移动。
  - DirectionalLight 开启 shadow。
  - 新增低于 UI 的 tilt-shift CanvasLayer + screen texture shader。
  - 昼夜光照按游戏内时刻 lerp，夜间建筑暖色 OmniLight 点亮，厨房/营地光带 flicker。
  - 地面从单 Plane 改为 6x8 quad 拼接，道路改为贴地窄长 quad，纹理路径集中为 const。
- `data/world-state.json` 为现有角色/建筑补 `density`，按新 `PIXELS_PER_UNIT := 48.0` 公式保持当前显示尺寸接近改动前。

## 门禁结果

- `./godot.exe --headless --check-only --path .`：通过。
- `./godot.exe --headless --export-release "HTML5" out/index.html`：通过。
- `cd out && python -m http.server 8765` 后访问 `http://127.0.0.1:8765/index.html`：HTTP 200，通过，服务已停止。
- `git add -A && git commit -m "feat: mobile P0 UI rework + HD-2D rendering (P0.5)"`：未完成。当前沙箱对 `.git` 目录只有读权限，Git 无法创建 `.git/index.lock`，报错 `Permission denied`。

## 已知问题 / 风险

- 本环境没有可用的 in-app Browser 控制工具，未做真实浏览器截图级视觉验收；只做了 Godot 检查、导出和 HTTP 加载验证。
- 人物卡头像当前直接显示 walk sheet 纹理，由 TextureRect 放大 nearest；后续若要只裁第 0 帧，需要改成 AtlasTexture 或额外裁剪逻辑。
- 资源低红色高亮包括 threat 低于 20 的通用规则；如果威胁语义要反向高亮，应单独调整。
- Git 工作树在开始时已有大量未跟踪/已修改文件，包括 `assets_hd2d/` 和 `out/`。本次没有修改 `assets_hd2d/` 文件内容，但按任务要求执行 `git add -A` 会把当前工作树状态纳入提交。

## 建议 Claude 验证

- 手机竖屏打开导出版，检查首屏是否只剩状态条 + 世界 + dock，sheet 外点击是否只关闭 sheet。
- 验证角色走到建筑后方时是否被遮挡，尤其是温室/掩体附近。
- 在早晨、黄昏、夜间三段时间查看光照和建筑灯是否符合预期。
- 点击人物、建筑、投票和今日回放，确认 sheet 内容和交互节奏。
