# Pi Agent 深度探索系列设计

## 1. 目标

在 Quartz 站点中新增一套约 30 篇的中文系列文档，系统讲解
[`earendil-works/pi`](https://github.com/earendil-works/pi)：

- 前期帮助读者安装、配置并熟练使用 Pi；
- 中期解释 Agent Loop、工具调用、流式事件和上下文管理；
- 后期进入 `pi-ai`、`pi-agent-core`、`pi-coding-agent`、`pi-tui`
  的源码与扩展机制；
- 最终通过可运行实验完成 Pi SDK 嵌入和自定义 Coding Agent 开发。

系列不是命令手册的中文翻译。它应当提供从“会使用”到“能解释源码并完成二次开发”
的连续学习路径。

## 2. 目标读者与完成标准

### 目标读者

读者具备以下基础：

- 能使用 Linux 或 macOS 终端；
- 了解 TypeScript、Node.js 和异步编程；
- 知道 LLM、Prompt、Tool Calling 和 Token 的基本概念；
- 不要求事先读过 Pi 源码。

### 完成系列后应能做到

1. 安装 Pi，配置 Provider，并管理交互会话；
2. 解释一次请求如何经过模型、工具、状态和 TUI；
3. 阅读四个核心包的关键源码；
4. 编写包含 Tool、Command、Shortcut 和状态恢复的 Extension；
5. 使用 SDK 构建一个具备工具调用与会话恢复能力的最小 Coding Agent；
6. 判断 Pi 在权限、安全、上下文和升级兼容方面的工程边界。

## 3. 内容原则

### 3.1 事实基线

系列跟踪 Pi 的 `main` 分支，不固定发布版本。每篇涉及源码的文章必须在开头记录：

- 校验日期；
- 完整 commit SHA；
- 对应仓库链接；
- 本文涉及的 package。

文章中的源码结论必须基于该 SHA 验证。后续更新文章时，同时更新 SHA 和受影响的描述。
不使用搜索摘要、Issue 提案或第三方文章代替当前源码事实。Issue 和历史文档只能用于解释
设计演进，并须明确标注其历史属性。

本设计确认时的参考基线为：

```text
branch: main
commit: 1da903983ad72c60995507e813a00bb2bd6faf09
verified: 2026-06-12
```

### 3.2 写作方式

- 中文为主，API、类型、命令和包名保留英文；
- 先给结论和运行路径，再解释内部机制；
- 每篇围绕一个可验证问题展开，避免按文件逐行复述；
- 源码调用链使用 Mermaid、文本图或表格辅助说明；
- 代码片段保持最小，只保留支撑结论的部分；
- 引用源码时使用稳定的 GitHub commit permalink；
- 区分“Pi 当前实现”“通用 Agent 原理”和“作者建议”。

### 3.3 安全边界

Pi 默认继承启动进程的文件系统、进程、网络和凭据权限，不内置完整权限隔离系统。
涉及命令执行、文件修改和凭据的文章不得把本地直接运行描述为安全沙箱。
工程化章节必须覆盖容器化、最小权限、密钥处理和不可信扩展风险。

## 4. 系列结构

### Part I：使用与整体认知

1. Pi 是什么：定位、设计哲学与适用边界
2. 安装、认证、Provider 与模型配置
3. TUI 操作、快捷键、消息队列与运行模式
4. Session、分支、恢复与 Compaction
5. Monorepo 全景：四个核心包如何协作

完成本阶段后，读者能够日常使用 Pi，并能说清四个核心包的职责。

### Part II：Agent 核心原理

6. Coding Agent 的工作循环
7. Message、Tool Call 与 Tool Result 数据模型
8. Streaming：增量事件与状态更新
9. Context Window、Token 与上下文管理
10. 中断、错误恢复与循环终止条件

配套实验：实现一个无 TUI 的最小 Agent Loop。

### Part III：四个核心包源码

11. `pi-ai`：统一模型抽象与 Provider 适配
12. `pi-ai`：消息转换、流式响应与工具协议
13. `pi-agent-core`：Agent 状态机与事件系统
14. `pi-agent-core`：工具注册、执行与结果反馈
15. `pi-coding-agent`：CLI 启动与依赖装配
16. `pi-coding-agent`：Session 生命周期与持久化
17. `pi-coding-agent`：内置 `read`、`write`、`edit`、`bash` 工具
18. `pi-tui`：组件树、输入与事件分发
19. `pi-tui`：差量渲染、终端控制与性能
20. 一次请求的完整源码调用链

配套实验：记录一次真实请求的事件流，并还原跨包调用链。

### Part IV：定制与扩展

21. Context Files、System Prompt 与 Prompt Templates
22. Skills 的发现、加载和执行语义
23. Extensions 生命周期与事件钩子
24. 开发自定义 Tool、Command 和 Shortcut
25. Pi Package：扩展的组织、安装与分发

配套实验：实现一个项目分析 Extension，包含工具、命令、快捷键和会话状态恢复。

### Part V：SDK 与二次开发

26. 使用 SDK 嵌入 Pi Agent
27. 自定义 Provider、模型注册与认证存储
28. 构建一个最小品牌化 Coding Agent

配套实验：实现独立 CLI，支持模型对话、文件读取、命令执行和会话恢复。

### Part VI：工程化专题

29. 权限模型、容器化、凭据和工具安全
30. 测试、调试、性能、升级兼容与源码贡献

## 5. 文件与导航设计

### 文章

所有文章存放在 `content/`，遵循仓库现有命名规则：

```text
2026-06-12-pi-agent-deep-dive-series-index.md
2026-06-12-pi-agent-deep-dive-ch01-overview.md
2026-06-12-pi-agent-deep-dive-ch02-installation-providers.md
...
2026-06-12-pi-agent-deep-dive-ch30-engineering.md
```

系列索引负责：

- 说明读者基础和学习目标；
- 展示六阶段学习路径；
- 链接全部章节并标记完成状态；
- 记录系列统一的源码校验策略；
- 链接实验目录和官方资源。

`content/index.md` 增加 Pi Agent 系列入口，避免新系列成为孤立内容。

### 实验

实验统一存放在：

```text
practice/pi-agent/
├── README.md
├── phase-1-environment/
├── phase-2-minimal-agent/
├── phase-3-event-trace/
├── phase-4-project-extension/
└── phase-5-branded-agent/
```

每个实验目录包含独立说明、运行命令、预期输出和清理方法。实验优先使用发布包，
源码分析阶段再切换到克隆仓库和本地 workspace 构建。实验不得依赖 Quartz 自身运行。

## 6. 分阶段交付

### 第一批

- 系列索引；
- 第 1 至第 5 篇；
- `phase-1-environment` 环境检查实验；
- 主页入口；
- Quartz 构建验证。

### 后续批次

- 第二批：第 6 至第 10 篇和最小 Agent Loop；
- 第三批：第 11 至第 20 篇和事件追踪实验；
- 第四批：第 21 至第 25 篇和 Extension 实验；
- 第五批：第 26 至第 28 篇和品牌化 Agent；
- 第六批：第 29 至第 30 篇、全系列校订和交叉链接。

每一批都应形成可以独立阅读和运行的增量，不提前创建只有标题的空文章。

## 7. 第一批文章边界

### 第 1 篇

回答 Pi 是什么、不是什么、适合什么场景，以及它与 IDE 插件、封闭式 Coding Agent
和通用 Agent Framework 的区别。不得把设计哲学写成无法从官方文档或源码验证的宣传语。

### 第 2 篇

覆盖发布包安装、源码运行、认证方式、Provider 与模型选择，并给出最小诊断步骤。
命令须在干净环境中验证，涉及版本变化的输出不得写死。

### 第 3 篇

覆盖 Interactive、Print、JSON、RPC 等运行方式，以及 TUI 编辑器、快捷键和消息队列。
快捷键和命令必须以当前 `main` 文档或源码为准。

### 第 4 篇

解释 Session 的持久化、树形分支、恢复和 Compaction。重点是行为和数据流，
不在本篇过早展开所有内部类型。

### 第 5 篇

建立 `pi-ai`、`pi-agent-core`、`pi-coding-agent` 和 `pi-tui` 的职责图，
并用一次请求说明依赖方向，为后续源码篇提供地图。

### 第一阶段实验

实验脚本检查 Node.js、npm、Git 和 Pi CLI，并输出明确的通过、跳过或失败状态。
实验说明同时提供发布包和源码两条路径，但不自动安装全局软件或写入用户认证配置。

## 8. 验证策略

每批交付必须完成以下验证：

1. Frontmatter 字段、文件名和 Wiki 链接符合 Quartz 约定；
2. 所有内部链接对应真实文件；
3. 所有源码 permalink 包含完整 commit SHA；
4. Shell 命令通过 `shellcheck` 或等价静态检查（环境可用时）；
5. TypeScript 示例能够安装、类型检查并运行（需要真实 API 的步骤允许使用 mock）；
6. `npx quartz build` 成功；
7. 对新增文章执行冷读，确认读者无需本次对话即可完成文中操作；
8. 不修改与本系列无关的现有未提交文件。

## 9. 非目标

- 不复制或翻译 Pi 官方文档全文；
- 不把 GSD Pi 作为系列主线；
- 不在首批文章中实现完整 Extension 或品牌化 Agent；
- 不承诺 `main` 分支 API 稳定；
- 不把 Pi 描述为具备默认权限沙箱；
- 不为凑足篇数重复解释通用 LLM 基础知识。

## 10. 首批验收标准

首批交付完成时：

- 首页可以进入系列索引；
- 索引可以进入前五篇文章；
- 前五篇共同覆盖安装、日常使用、Session 和四包架构；
- 每篇源码相关结论都能追溯到校验 SHA；
- 环境实验不会修改用户全局环境；
- Quartz 站点构建通过；
- 工作区原有未提交内容保持不变。
