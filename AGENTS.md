# Obsidian Content 文档规范

本仓库的 `content/` 目录是 Obsidian (Quartz) 博客的内容源。所有笔记必须遵循以下格式。

## 内容组织（双轨制，2026-09 起生效）

`content/` 下分两类内容，**新文章先判断自己属于哪一类**：

| 类型         | 位置                            | 命名                                                | 例子                                            |
| ------------ | ------------------------------- | --------------------------------------------------- | ----------------------------------------------- |
| **系列章节** | `content/<系列文件夹>/`         | `chNN-kebab-case.md`（NN 两位补零，**无日期前缀**） | `freertos-deep-dive/ch13-task-notifications.md` |
| **系列索引** | `content/<系列文件夹>/index.md` | 固定名 `index.md`（slug 即文件夹名）                | `lwip-deep-dive/index.md`                       |
| **散记**     | `content/` 根目录               | `YYYY-MM-DD-kebab-case-title.md`（保留日期前缀）    | `2026-08-26-nload.md`                           |

规则：

- 现有 **21 个系列文件夹**清单见 `content/series/index.md`（系列总览页）。新章节写进所属系列文件夹；**开新系列**时新建文件夹 + `index.md`，并**必须在 `content/series/index.md` 登记一行**，否则读者从总览发现不了。
- 文件基名（不含扩展名）在**全库必须唯一**——Quartz 的 `shortest` 链接策略与 Obsidian 的解析都依赖这一点。起名时带足语义（`ch13-task-notifications` 而不是 `ch13-notifications` 这类易撞名形式）；与其他系列可能撞名时加系列前缀（先例：`zeek-deep-dive-ch1-overview`）。
- 散记升级为系列时（同主题第 3 篇左右）：建文件夹、移入、改名为 `chNN-*`，全库重写指向它的 wikilink。
- `content/assets/` 与 `content/series/` 为保留目录，勿挪作他用。

## Wikilink 规范

- 一律使用**基名 wikilink**：`[[ch13-task-notifications|别名]]`；链接系列索引用**文件夹名**：`[[lwip-deep-dive|lwIP 深度解析]]`。
- **禁止**在 wikilink 里写日期前缀全名（旧结构遗留，已全部迁移）、路径（`[[folder/file]]`）或 `.md` 扩展名。
- 章节正文互链：章首导航 callout（系列索引 + 本章）、章尾"下一章预告"链接，系列内形成线性阅读链。

## 示例代码规则（存放与引用）

示例/实验代码住 `practice/`，文章住 `content/`，两者通过**站内代码浏览器深链**桥接。完整规则如下。

### 存放规则

- 目录结构：`practice/<套件>/<工程>/`。现有套件：`lwip-examples/`（exNN-slug 示例）、
  `hwbasics/`（硬件基础实验）、根下 `lwip-chNN-*`（章节实验）、`lwip-labs/`（公约与调研）。
  新套件开工前先在套件内立 SPEC.md（参考 `practice/lwip-examples/SPEC.md`）。
- 工程名用英文 kebab-case，带章号/示例号前缀（`ex02-tcp-echo-server`、`ch03-cortex-m-anatomy`），
  与所属系列的 slug 对齐；**改名/移动工程目录会使浏览页深链全部失效**，须全局搜替后重生成。
- 工程标准件：`main/`（源码）、`CMakeLists.txt`、`sdkconfig.defaults`（及 `.ci`/`.debug`/场景变体）、
  `README.md`（中文，含拓扑与复现命令——浏览页会展示）、运行日志（`run.log`/`logs/`/`runs/`）、
  宿主工具（`tools/`，单文件脚本为佳）。
- 入库边界与日志截断政策见下文「CI 与提交规范 → practice/ 实验工程入库规则」；
  生成物（`build*/`、`managed_components/`、`sdkconfig`）已被 .gitignore 固化排除。

### 文章引用规则（三层，按优先级）

1. **站内代码浏览器深链（首选）**——读者不离开站点即可看高亮源码：
   `/static/code/?p=<项目ID>&f=<工程内相对路径>`，项目ID 即工程目录路径
   （如 `lwip-examples/ex02-tcp-echo-server`、`lwip-ch03-qemu-network-lab`、`hwbasics`）。
   URL 中 `/` 用 `%2F` 编码；可追加 `#L42` 行锚点定位。文章中用普通 Markdown 链接
   `[看实现](/static/code/?p=...%2F...&f=main/main.c)`——**不是 wikilink**（代码页不是笔记节点）。
2. **GitHub 源链（次选）**——需要历史 blame/PR 语境时：
   `https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/<路径>`。
3. **文内代码块（限短片段）**——≤30 行的关键片段可直接嵌入文章讲解，但必须标注
   出处工程与文件（`> 源自 practice/.../main.c`）。**禁止**把大段实现复制进文章：
   与工程源码形成双份漂移，改一处忘另一处。实验输出摘录（run.log 片段）不受此限。

**章节 ↔ 实验互链（强制）**：系列章节配有 practice 工程时，**必须**在实验相关小节给
出该工程的站内深链（推荐 tip callout 形式，含 main.c 直达 + 完整工程两级链接，
参考 `f429-lab/ch00e` 第 5 节的示范）；工程 README 必须反向 wikilink 回所属章节。
新增实验后流程：`npm run code-site` 重生成 → 章节补深链 → 提交。

### 浏览页收录与更新义务

- 浏览页由 `npm run code-site`（`scripts/gen-code-site.mjs`）生成到 `quartz/static/code/`，
  产物**直接提交**（已列 .prettierignore，随 Quartz 部署 GitHub Pages）。收录范围与过滤规则
  在脚本顶部 `PROJECT_GLOBS`/`SKIP_DIRS`/`TEXT_EXT` 配置：跳过 `build*`、`managed_components`、
  日志与 `sdkconfig` 生成物，只收文本源码，单文件 ≤256KB。
- **新增、修改、删除、重命名任何工程后，必须重跑 `npm run code-site` 再提交**，
  否则浏览页与仓库实际代码脱节。新增套件需同步在脚本 `PROJECT_GLOBS` 加一条收录规则。
- 浏览页入口：站点左侧栏 💻 示例代码 tab（`/static/code/`），支持递归目录树、文件名过滤、
  明暗主题、行锚点与深链。

## 文件命名（散记适用）

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

> [!NOTE]
> 系列章节虽无日期前缀文件名，`date` 字段仍必填（排序与展示用）。

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
