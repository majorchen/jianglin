# 任务：降临 jianglin 手机端 P0（UI/交互重构）+ P0.5（HD-2D 渲染升级）

【当前焦点】降临 jianglin 是当前最高优先级项目：手机端 HD-2D 升级，让线上版本（https://out-pink-xi.vercel.app）成为"第一眼想截图"的竖屏活世界。完整方案见 `PLAN-mobile-hd2d.md`（第四、五节是本任务的规格书，必读）。

## 项目背景
- Godot 4.6 项目，主场景 `scenes/main_hd2d.tscn`，主脚本 `scripts/main_hd2d.gd`（约700行，UI 全部运行时构建）
- 数据驱动：`data/world-state.json`（角色/建筑/资源/事件/投票）
- Web 导出在 `out/`（export_presets.cfg 已配置），部署 Vercel
- 字体：`assets_hd2d/fonts/NotoSansSC-Regular.ttf`

## ⚠️ 硬约束
1. **不要碰 `assets_hd2d/` 下任何文件**——另一个进程正在并行写入新资产（raw/v2/）。纹理路径全部收敛到脚本顶部 const，方便后续换新资产。
2. 保持数据驱动：所有内容仍从 world-state.json 读取，不要硬编码剧情。
3. 保留 `/api/vote` 投票逻辑（_fetch_vote_totals / _submit_vote / _api_url）。
4. Surgical changes：不重构没问题的部分。

## A. project.godot
- viewport 改为 432×936，stretch 保持 canvas_items / expand

## B. UI 重构（手机优先，字号基准：正文15-17，标题18-20，按钮高≥48）

### B1. 顶部：只留一条紧凑状态条
- 一行内容：`第N天 HH:MM` + 6 个资源（短标签+数字：食42 水58 电31 药18 士64 威37，资源低于20红色高亮）
- 高度 ~44px，半透明深色底，safe-area 适配（用 `DisplayServer.get_display_safe_area()` 偏移；web 端没有刘海但代码要兼容）
- 点状态条 → 打开"营地" bottom sheet（资源详情）
- **删除**：现有的 BriefPanel、EventPanel、全局 SpeechBubble、中央 CharacterCard——全部被下面的新组件取代

### B2. 底部 dock：3 个 tab
- `今日` / `投票` / `营地`，等宽按钮，高 52px，含底部 safe-area 留白
- 点击打开对应 bottom sheet；再点同一 tab 或点 sheet 外部区域 → 关闭

### B3. Bottom Sheet 组件（核心交互范式，做一个可复用的）
- PanelContainer 从屏幕底部 tween 滑出（0.22s, EASE_OUT），高度约半屏（内容超出可滚动 ScrollContainer）
- 顶部有一条小灰横杠（drag indicator 视觉）+ 标题
- 点 sheet 外的世界区域 → 关闭 sheet（注意输入拦截，见 B6）
- 五种内容：
  - **今日**：daily_brief 全文 + 今日事件时间线（事件触发后追加进列表，可回看）+「回放今日」按钮（见 C）
  - **投票**：问题 + 选项按钮（点击乐观更新票数、✓ 高亮选中项、按钮描述文字直接显示在选项下方而不是 tooltip——手机没有 tooltip）
  - **营地**：title + threat/weather + history 列表
  - **人物卡**：点角色时打开——头像（从 walk sheet 取第0帧，TextureRect 放大、nearest 过滤）+ 名字/职业/心情/需要 + 记忆列表
  - **建筑卡**：点建筑时打开——名字 + 状态 + 描述

### B4. 台词 → 角色头顶气泡
- 删除全局 SpeechBubble；改为每个角色头顶的 Label3D（在名字标签上方），深色半透圆角背景效果（outline 模拟即可），文字出现 4 秒后淡出（modulate tween）
- 同一时间多个角色可以各自说话，互不覆盖

### B5. 事件 → 顶部 toast
- 事件触发时从状态条下方滑入一条 toast（标题+一行文字），3 秒后滑出
- 同时把事件追加到「今日」sheet 的时间线列表（带游戏内时刻）

### B6. 输入修正
- bottom sheet 打开时，世界点击只用于关闭 sheet（`get_viewport().set_input_as_handled()`），不触发选人
- 角色/建筑选中半径按 viewport 宽度比例换算（不要固定 80px）
- 保留：单指拖拽平移、双指捏合缩放；缩放范围 clamp 后加边界（相机位置 clamp 在地图范围内）

## C. 时间系统：默认实时模式 + 回放模式
- **实时模式（默认）**：游戏内时刻 = 本机本地时间（`Time.get_datetime_dict_from_system()` 的 hour+minute），角色按 schedule 走位、事件按 hour 触发。打开网页看到的就是小镇"现在"的样子
- **回放模式**：「今日」sheet 里的「回放今日」按钮进入——时间从 06:00 开始快进（沿用现有 time_speed 逻辑），底部 dock 临时变为：退出回放 / 暂停 / 倍速。退出回放回到实时模式
- 实时模式下不显示暂停/倍速
- `_advance_day()` 的跨天逻辑只在回放模式生效；实时模式跨午夜只是时刻回绕，day 字段仍以 world-state.json 为准（日更由 Runner 负责）

## D. HD-2D 渲染三件套（PLAN 第四节）

### D1. 真深度遮挡
- 所有 Sprite3D 去掉 `no_depth_test`
- billboard 改 `BILLBOARD_FIXED_Y`
- `alpha_cut = SpriteBase3D.ALPHA_CUT_OPAQUE_PREPASS`（保证深度排序正确）
- 验证：角色走到建筑后面要被遮挡

### D2. 影子
- 每个角色/建筑脚下加一个椭圆软影：QuadMesh 平贴地面 + GradientTexture2D 径向渐变（黑→透明），unshaded 材质，跟随角色移动
- DirectionalLight `shadow_enabled = true`（sprite 本体因 billboard 不投影，椭圆影是主影子，平行光影子作用于未来的 3D 元素，开着无害）

### D3. Tilt-shift 景深
- 新建 CanvasLayer（layer 低于 UI 层）+ 全屏 ColorRect + shader：
  - `hint_screen_texture` 采样屏幕
  - 屏幕 Y 在 [0, 0.25] 和 [0.75, 1.0] 区间内做渐进模糊（5-9 tap 高斯近似，模糊强度从中心 0 平滑到边缘最大）
  - gl_compatibility 渲染器可用，注意 `screen_texture` 用 `textureLod`
- 模糊强度做成 export 变量方便调

### D4. 昼夜循环（跟随游戏内时刻，实时/回放都生效）
- 关键帧 lerp：05:00 黎明（橙，能量1.6）→ 12:00 正午（暖白，2.2）→ 18:00 黄昏（金红，1.8）→ 21:00 夜（蓝紫，0.5）→ 通宵到 05:00
- 同步 lerp：DirectionalLight 颜色/能量/角度、ambient 颜色、background 颜色
- 夜间（20:00-06:00）：每栋建筑位置点亮一盏暖色 OmniLight（窗户光），厨房/篝火光做轻微 flicker（能量 sin 抖动）
- 现有的 CampGlow OmniLight 整合进这套系统

### D5. 地面重做
- 替换"单张 PlaneMesh + 2 条 BoxMesh 路"：改为 N×M 个 quad 拼地面（约 6×8 块，每块 2×2 世界单位），每块随机使用地面纹理的不同 UV region / 随机 90° 旋转，打破平铺感
- 道路：用窄长 quad + 现有地面纹理偏暗的 modulate（新的 path 纹理之后会换上，路径写成 const）
- 纹理路径 const：`GROUND_TEXTURE`、`GROUND_TEXTURE_2`（暂时都指向现有 ground-tiles.png）、`PATH_TEXTURE`（暂指向 ground-tiles.png）

### D6. Glow（可选，最后做）
- 尝试 Environment glow（Godot 4.3+ compatibility 支持 2D/3D glow）；若导出后 web 端表现异常就关掉，不要恋战

## E. 资产密度参数化（为换新资产做准备）
- 脚本顶部加 `const PIXELS_PER_UNIT := 48.0`
- 角色/建筑的 pixel_size 计算改为：`pixel_size = 1.0 / PIXELS_PER_UNIT / density`，density 从 world-state.json 的角色/建筑条目读（新增可选字段 `density`，默认 1.0）
- 在 world-state.json 里为现有资产填好 density 值，使**当前画面尺寸与改动前一致**（现有资产像素密度高，算出对应倍数，比如角色帧高313px原pixel_size 0.00205 → 反推 density）
- 新资产（48px/单位）到位后，把 density 字段删掉或设 1.0 即可

## F. 质量门禁（必须全部通过）
1. `./godot.exe --headless --check-only --path .` 无脚本错误
2. Web 导出：`./godot.exe --headless --export-release "Web" out/index.html`（preset 名以 export_presets.cfg 实际为准），导出无报错
3. 本地起服务验证加载：`cd out && python -m http.server 8765`（验证 index.html 能返回 200 即可，起完记得杀掉）
4. git add -A && git commit -m "feat: mobile P0 UI rework + HD-2D rendering (P0.5)"，**不要 push，不要部署**

## 汇报
完成后在仓库根目录写 `_codex_p0_report.md`：做了什么、门禁结果、已知问题/风险、建议我（Claude）验证的点。
