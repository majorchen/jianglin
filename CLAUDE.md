# 降临 Jianglin — 社群可视化互动世界

## 项目概述
一个每天自动更新的 2D 像素小镇。思行社区的成员作为 AI agent 生活在这个世界里。每天早上打开网页，看到小镇发生了变化。

## 技术栈
- **游戏引擎**: Godot 4.5 (GDScript)
- **内容生成**: Runner (Node.js) + Agnes API
- **AI Agent**: 斯坦福小镇记忆流+日程表+社交图算法
- **素材生成**: Codex Desktop (GPT Image 2)
- **部署**: HTML5 Web Export → Vercel

## 目录结构
```
jianglin/
├── assets/          # 游戏素材（图片、音频）
├── scenes/          # Godot 场景文件 (.tscn)
├── scripts/         # GDScript 脚本 (.gd)
├── data/            # Runner 生成的 JSON 数据
├── runner/          # Runner 代码（符号链接到 letters-from-changan-runs）
└── project.godot    # Godot 项目配置
```

## 当前阶段
Phase 1 — 静态小镇 ✅ 代码完成，待导出部署
- ✅ Godot 4.6.3 引擎
- ✅ 4 套像素素材（Codex 生成）
- ✅ 主场景（地图 + 3 个 NPC + 镜头控制）
- ✅ 项目验证通过（--check-only）
- 🔄 HTML5 导出模板下载中

## 参考代码
- 斯坦福小镇: /tmp/generative_agents/
- FF7 生图: C:/Users/83744/.claude/tools/codex_gen.py
- Runner: E:/claude-workspace/letters-from-changan-runs/
