# Obsidian Content 文档规范

本仓库的 `content/` 目录是 Obsidian (Quartz) 博客的内容源。所有笔记必须遵循以下格式。

## 文件命名

格式：`YYYY-MM-DD-kebab-case-title.md`

- 日期使用 ISO 8601 格式（创建日期）
- 标题使用英文 kebab-case（短横线连接），如 `linux-trace`、`bash-pretty`
- 中文笔记同样使用英文 kebab-case 文件名，中文标题放在 frontmatter 的 `title` 字段

## Frontmatter

每个文件必须包含 YAML frontmatter，格式如下：

```yaml
---
title: 中文标题（可自由使用中文）
date: YYYY-MM-DD HH:MM:SS
pin: true # 可选，置顶文章
description: 一句话描述 # 可选
tags: [tag1, tag2, tag3]
---
```

### 字段说明

| 字段          | 必填 | 说明                                 |
| ------------- | ---- | ------------------------------------ |
| `title`       | 是   | 文章标题，可使用中文/英文            |
| `date`        | 是   | 发布日期，格式 `YYYY-MM-DD HH:MM:SS` |
| `tags`        | 是   | 标签数组，使用 PascalCase 或小写英文 |
| `pin`         | 否   | 是否置顶，布尔值                     |
| `description` | 否   | 文章简介                             |

## 内容格式

- 使用标准 Markdown
- 正文以一级标题 `# 标题` 开头（通常与 `title` 相同）
- 使用 `##`、`###` 等层级标题组织内容
- 代码块必须标注语言标识（`bash`、`go`、`yaml` 等）
- 图片引用放在 `content/assets/` 目录，使用相对路径：`![alt](assets/image.png)`
- 排版语言：中文为主，技术术语保留英文

## 文档类型参考

- **技术笔记**：记录工具使用、配置、排坑过程（如 `bash-pretty`、`nload`）
- **技术调研**：方案对比、选型分析，使用表格总结（如 TTS 方案对比）
- **深度分析**：协议分析、源码解读、架构设计（如 `ipsec-protocol-deep-dive`）
- **决策记录 (ADR)**：技术选型决策，包含背景、分析、实现（如 `caracal-gateway-compression-adr`）

## 写作规范

- 简洁直接，先结论后展开
- 技术文档以实用为主，记录可复现的命令和步骤
- 代码块中包含可直接复制的命令
- 排坑记录需说明环境、问题现象、解决方案
- 对比类文章使用 Markdown 表格
