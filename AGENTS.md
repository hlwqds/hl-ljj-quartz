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

## CI 与提交规范（提交前必读）

CI（`.github/workflows/ci.yaml`）对 v4 分支的每次 push/PR 执行：
`npm ci` → `npm run check`（`tsc --noEmit` + **prettier 全仓检查**）→ `npm test` → `npx quartz build --bundleInfo -d docs`。

### Prettier 全仓检查

- prettier 检查范围是**整个仓库的所有 `.md`/`.json`/`.yaml` 等文本文件**，`.prettierignore` 只排除 `public`、`node_modules`、`.quartz-cache`——`content/` 和 `practice/` 都在射程内。
- 配置：`printWidth: 100`，`proseWrap` 默认 preserve（不重排散文段落，只规范表格对齐、列表符号、代码块围栏、JSON 缩进）。
- **新文档写完必须先 `npx prettier <新增文件> --write` 再交付**，否则 CI 必挂。实验工程产出的 JSON 测量档案同样会被检查。
- 提交前本地跑一遍 `npm run check` 复现 CI 判定。

### quartz 构建检查

- CI 会跑 quartz build（构建 `docs/`）；博客正文在 `content/`，提交前本地跑 `npx quartz build` 确认正文可构建、无解析报错。
- 构建后起服务抽查页面：索引页、新文章页、wikilink 互链是否正常解析（死链不报错但会渲染为失效链接，靠人工抽查）。

### practice/ 实验工程入库规则

- **只提交源码**：`main/`、`CMakeLists.txt`、`sdkconfig.defaults`（及其 `.ci`/`.debug` 等变体）、`README.md`、运行日志（`run.log`/`logs/`）。
- **日志超 1MB 必须截断后入库**：保留首 5000 行 + 关键证据行（`assert failed`/`panic`/`abort()` 等崩溃签名）+ 末尾 500 行，并写入 `[LOG TRUNCATED: ...]` 标注原始行数。完整调试刷屏日志（如 LWIP_DEBUG 全开的压测输出可达 144MB/个）不入库，复现命令在工程 README 与文章实验节。
- **生成物一律 gitignore**（规则已固化在 `.gitignore`）：`practice/*/build*/`——注意构建目录名不固定（`build`、`build_d`、`build-dbg` 都出现过，所以用 `build*/` 通配）；`practice/*/sdkconfig`（生成文件，源是 `sdkconfig.defaults`）；`managed_components/`、`qemu_efuse.bin`、`.mimosa/`、`qemu.pid`。
- 单个 ESP-IDF `build/` 目录可达 ~86MB，24 个工程全提接近 2GB，切勿整目录 `git add` 后不看 `.gitignore` 是否命中。

### 跨系列 wikilink 与提交完整性

- 文章大量使用 `[[wikilink]]` 互链其他系列。**新系列引用了未入库的系列时，必须把被链接系列一并提交**，否则 CI 构建出的站点满是死链（构建不报错，页面链接失效，属于静默劣化）。
- 提交前用脚本核对：从新增 `.md` 提取全部 `[[链接目标]]`，确认每个目标文件都已在库中。

### 交付前自检清单

1. `npx prettier <新文件> --write`
2. `npm run check` 全绿
3. `npx quartz build` 成功 + 本地服务抽查页面
4. `.gitignore` 命中所有生成物，`git status` 无超大目录混入
5. wikilink 目标全部已入库
