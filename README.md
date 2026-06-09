# 降临 Jianglin — 社群可视化互动世界

> 一个每天自动更新的 2D 像素小镇。思行社区的成员作为 AI agent 生活在这个世界里。

**线上地址：** https://out-pink-xi.vercel.app  
**GitHub：** https://github.com/majorchen/jianglin

---

## 项目概述

《降临》是思行社区的内部项目——把社区成员变成一部 AI 末日群像剧的角色。每个群友在故事里有一个化身，Runner 每天自动生成剧情、日程和地图变化。群友通过投票影响次日剧情走向。

**核心理念：** 不是"做一个游戏"，是"做一个活着的世界"。

---

## 技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| 渲染引擎 | JavaScript Canvas | 纯 JS 2D 渲染，零依赖 |
| 素材生成 | Codex Desktop (GPT Image 2) | 像素精灵、建筑、地形 AI 生成 |
| 内容引擎 | Runner (Node.js) | 每天自动生成剧情+日程 JSON |
| 记忆系统 | 斯坦福小镇算法 | Associative Memory（待移植） |
| 部署 | Vercel | 静态站点，自动 CDN |

---

## 当前进度（Phase 1 — 静态小镇 ✅）

- [x] 项目初始化，Git 仓库
- [x] Godot 4.6.3 引擎（备用，主方案已切换为 JS Canvas）
- [x] 4 套 Codex 像素素材（地形瓦片、建筑精灵、角色精灵、UI 元素）
- [x] JS Canvas 游戏引擎（地图渲染、NPC 移动、对话气泡）
- [x] 3 个 NPC（工程师老王、科学家小李、拾荒者老张）
- [x] NPC 日程系统（按时移动、对话气泡、记忆存储）
- [x] 滚轮缩放、中键拖拽、键盘控制
- [x] Vercel 部署 + GitHub Push

**已知限制：**
- 素材为 RGB 无透明通道（Codex 限制）
- NPC 日程为静态 JSON，未接入 Runner
- 仅 3 个 NPC，尚未扩展到社群规模

---

## 计划路线图

### Phase 2 — 活的小镇（开发中）

- [ ] **Runner 接入**：每天自动生成日程+对话+地图变化 JSON
- [ ] **投票系统**：页面底部投票组件，结果驱动次日剧情
- [ ] **自动部署**：Runner 生成 → Git Push → Vercel 自动部署
- [ ] **地图扩展**：更多建筑和地形区域

### Phase 3 — 社交小镇

- [ ] **斯坦福记忆系统**：移植 Associative Memory（重要性-时间-关联度三维检索）
- [ ] **NPC 间对话**：角色之间的互动对话，记忆驱动的社交行为
- [ ] **扩展 NPC**：支持 10-15 个角色，新群友加入自动生成角色卡
- [ ] **角色关系图**：可视化 NPC 之间的社交网络

### Phase 4 — 沉浸体验

- [ ] **昼夜光影**：根据游戏时间动态调色
- [ ] **天气系统**：随机天气粒子效果
- [ ] **移动端适配**：触摸手势、响应式布局
- [ ] **存档回放**：每天快照，可回溯小镇历史

### Phase 5 — 开源 & 扩展

- [ ] **开源核心引擎**：让其他社群搭建自己的"活地图"
- [ ] **多世界观支持**：不只 AI 末日，可切换主题
- [ ] **社区模板市场**：社群可分享自己的地图/角色配置

---

## 项目结构

```
jianglin/
├── assets/              # Codex 生成的原始素材
├── data/                # Runner 生成的 JSON 数据
│   └── schedule-sample.json  # 示例日程
├── out/                 # 部署文件
│   ├── index.html       # 游戏入口
│   ├── game.js          # 游戏引擎
│   ├── schedule.json    # 日程数据
│   ├── ground-tiles.png # 地面瓦片
│   ├── buildings/       # 建筑精灵（5个）
│   ├── characters/      # 角色精灵（3个）
│   └── ...
├── scenes/              # Godot 场景（备用）
├── scripts/             # Godot 脚本（备用）
├── project.godot        # Godot 项目配置
└── CLAUDE.md            # Claude 项目文档
```

---

## 参考项目

- **斯坦福小镇 (Generative Agents):** `E:\claude-workspace\generative_agents\`
  - 核心 agent 逻辑在 `reverie/backend_server/persona/`
  - 记忆系统：`persona/memory_structures/associative_memory.py`
- **来信长安 Runner:** `E:\claude-workspace\letters-from-changan-runs\`
  - 已验证的 API 内容管线，可复用

---

## 本地运行

```bash
cd out/
npx serve .    # 或 python -m http.server 8080
```

浏览器打开 `http://localhost:8080`

**控制：** 滚轮缩放 · 中键拖拽 · R 重置时间 · +/- 调速

---

## 部署

```bash
cd out/
vercel --prod -y .
```

---

## 贡献者

- **Major** — 产品方向、社群运营、内容设计
- **Claude (Cloud)** — 架构设计、代码执行、项目管理
- **Codex** — 像素素材生成、Godot 引擎搭建
