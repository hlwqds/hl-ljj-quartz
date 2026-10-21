---
title: "Agent Harness 工程化（四）：工具接口与 Skills/MCP"
date: 2026-10-21 00:40:00
description: "工具注释即风险词汇表：工具设计纪律、MCP 代码执行式接入与技能的系统性验证"
tags: [harness, ai-agents, tools, mcp]
---

# Agent Harness 工程化（四）：工具接口与 Skills/MCP

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 4 篇
> 上一章：[[ch03-context-engineering|上下文工程]] · 下一章：[[ch05-memory-and-state|记忆与状态管理]]

## 先给结论

模型之外，工具层是 harness 里第二个直接决定成败的接口面。上一章讨论的是「信息怎么进上下文」，这一章讨论的是「能力怎么暴露给模型」。综合素材中 Anthropic、OpenAI 与 MCP 团队的工程文献（本篇观点均转述自精读笔记所收录的原文作者），可以归纳为四条：

1. **工具接口设计本质是 agent 的 UX**。命名、schema、错误消息与返回值约定直接决定 agent 可靠性——用 Anthropic 的说法，面对不合适的工具，模型可能凭参数知识硬答、反问用户或直接幻觉。
2. **工具注释是风险词汇表，不是安全契约**。MCP 的四个 annotation hint 只是权限决策的输入；真正要防的风险来自工具组合，而非单个工具。
3. **MCP 的接入范式正在从「离散工具调用」转向「代码执行式接入」**：把工具定义与中间结果挪进沙箱执行环境，Anthropic 实测最高削减 98.7% 的 token。
4. **技能（skills）是被工程化的制品，不是一次性提示词片段**：要可路由、可评测、可进 CI——Stripe 的实验结论是「不在加载上下文里的指引等于没写」。

一句话概括：工具层的全部设计都可以归结为上下文经济学——把计算从上下文里卸载出去，把风险从上下文里挡在外面。

本篇主要引用的原文：

- [Writing Effective Tools for Agents（Anthropic）](https://www.anthropic.com/engineering/writing-effective-tools-for-agents)
- [Tool Annotations as Risk Vocabulary（MCP 官方博客）](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/)
- [Code Execution with MCP（Anthropic）](https://www.anthropic.com/engineering/code-execution-with-mcp)
- [Shell + Skills + Compaction: Tips for Long-Running Agents（OpenAI）](https://developers.openai.com/blog/skills-shell-tips)

## 工具即契约：好工具的写作纪律

素材转述的 Anthropic 指南把工具定义为「确定性系统与非确定性 agent 之间的契约」：传统 API 的调用者是会读文档、会调试的人类工程师，而工具的调用者是模型——设计对象变了，接口的评价标准也随之改变。

### 选对工具，不造多余的工具

盲目包装原始 API endpoint 是素材指出的最常见反模式。正例是把多步流程合并为单一工具（如 `schedule_event` 一步取代 `list_users` + `list_events` + `create_event`），因为功能重叠的工具只会分散模型注意力、抬高选错率。这与 [[pi-agent-deep-dive|Pi Agent 深度探索]] 里 Pi 的取舍形成有意思的对照：Pi 只提供数量极少的文件读写、补丁编辑与 Shell 原语，把组合空间留给模型。工具少而正交与工具多而专门是两条都成立的路线，但都必须有意取舍，而不是顺手把既有 API 一层层包出来。

### 命名空间是给模型的检索结构

同一来源的工具用共享前缀分组（如 `asana_search` 与 `jira_search`），模型实际上是在拿命名空间当检索索引。素材提到 Anthropic 明说前缀还是后缀对评测有 non-trivial 影响，需要用自家 eval 定夺。好命名的本质，依然是上一章说过的那件事：把计算从上下文卸载（offload）进工具调用本身——模型扫一眼工具列表就能猜对用途，胜过在 description 里写三百字解释。参数命名同理，消除歧义（`user_id` 而非 `user`）。对 description 的态度则应是把它当 prompt 工程来写：Anthropic 给出的检验标准是「你会怎么向新入职同事描述这个工具」，并称 Claude Sonnet 3.5 刷 SWE-bench Verified 的过程中就包含对工具描述的精修。

### 返回有意义的上下文，而非原始 payload

Anthropic 的建议是砍掉 uuid、mime_type 这类低信号字段，把 UUID 解析成自然语言名称——素材称这能显著提升检索精度并降低幻觉。素材引用的 Slack 示例很能说明杠杆：同一工具的 `response_format` 提供 detailed 与 concise 两档，detailed 206 token、concise 仅 72 token，且 concise 仍保留链式调用所需的标识符。另一个可抄的数字是 Claude Code 把单次工具响应截断在 25,000 token——分页、范围选择、过滤、截断都应带合理默认值，而不是把选择负担丢给模型；截断提示语本身也要写成引导 agent 下一步行为的指令。

### 错误消息是写给模型的重试指令

错误消息的受众是模型而非人类：不能只回错误码或堆栈，要说明问题所在，并附一个格式正确的输入示例。这条纪律成本极低，却是素材归纳的 Anthropic 指南里性价比最高的几条之一。

### 结构化输出的分层保证

「返回值必须可解析」这件事可以在不同层面获得保证。素材铺出一条从静态到动态的谱系：outlines 在解码层用 regex/CFG/JSON Schema 约束采样，无需微调即可保证结构化输出（[GitHub](https://github.com/dottxt-ai/outlines)）；instructor 在解析层把 Pydantic 模型映射为结构化抽取，内置校验错误反馈与重试环（[官网](https://python.useinstructor.com/)）；AutoHarness 则从工具 schema 动态合成运行时约束代码，把约束执行从静态校验转向动态合成（[arXiv 2603.03329](https://arxiv.org/abs/2603.03329)，DeepMind 论文）。按部署环境与可控性要求选层即可。

### 接口不只是函数签名

工具接口还包括错误、预算与身份这些协议语义。素材给了两个佐证：EigentSearch-Q+ 把中间搜索决策外部化为带类型参数的专用工具（`plan_next_searches` 等），延续 think-tool 范式让认知脚手架显式可审计（[arXiv 2604.07927](https://arxiv.org/abs/2604.07927)）；一份企业 MCP 落地实测报告则指出三大协议级缺口——身份传播缺失、缺自适应工具预算、错误语义非结构化，并给出 JWT 富化调用、每工具超时契约、错误-动作映射等缓解模式（[arXiv 2603.13417](https://arxiv.org/abs/2603.13417)）。

### 评测驱动的工具开发

Anthropic 给出的工作流是把工具开发当评测驱动的迭代：用 Claude Code 加 llms.txt 把原型包成本地 MCP server → 基于真实数据构造复杂任务 → 每个任务配可验证判据 → 逐任务跑程序化 agentic loop → 统计 token、调用次数与错误类型 → 通读推理轨迹与原始 transcript。素材特别记录了 Anthropic 的一个观点：「模型没做什么往往比它做了什么更重要」——例如某个 web search 工具被模型无脑追加年份 '2025'，最后是靠改 description 修复的。这些评测 transcript 还可以被喂回去批量重构工具，用 held-out 测试集防过拟合；据素材转述，实测增益超过了专家手写的工具实现。这套打法规格与 [[ch07-evals-and-verification|评测与验证闭环]] 的主题直接衔接。

## 工具注释：一份风险词汇表

### 四个 hint 与悲观默认值

MCP 规范为工具定义了四个 annotation hint：`readOnlyHint`、`destructiveHint`、`idempotentHint`、`openWorldHint`。MCP 团队在自己博客里的定位非常克制：它们是权限决策的**输入而非强制契约**——规范原文写明 annotations "are not guaranteed to faithfully describe tool behavior"，客户端必须视为不可信，除非来自可信 server。需要硬保证的约束应放在网络控制、沙箱、授权层或运行时。语义映射与默认值方向如下（素材转述）：

- readOnly 支持跳过确认框；destructive 支持执行前告警；idempotent 支持失败后安全重试；openWorld 支持对输出做不可信内容审查。
- 未标注的工具一律按最坏情况对待：会改环境、可能具破坏性、不可重试、开放世界——原文的说法是 "the spec assumes the worst until told otherwise"。

### lethal trifecta：风险在组合而非单体

这是本篇素材里最值得带走的安全框架：**私有数据访问 × 不可信内容暴露 × 外部通信**，三者叠加才构成外泄条件，称为 lethal trifecta。关键在于它是 session 级风险而非单 server 级——逐个工具做安全分析，会漏掉组合涌现的风险。素材引用的已演示攻击链是：恶意 Calendar 事件（不可信内容）+ MCP calendar server（私有数据）+ 本地代码执行（外部通信），其中 shell 工具是关键环节。开放中的 SEP 提议为工具增加组合元数据，目标规则是「单一被污染执行路径中永不允许三者共存」。

这条框架也解释了为什么注释词汇表不够用：它只是把风险「说出来」，硬保证要落在沙箱与授权层——那是 [[ch08-sandbox-and-permissions|沙箱、权限与审批]] 的主题。

### 信任分级与评审清单

素材提炼出的判别准则是一个问句：**"Does it need trust to be useful?"**——title 在不可信 server 下仍有用，readOnlyHint 则没有；更彻底的主张是客户端应完全忽略不可信 server 的 annotations。工程落点是分级信任：内部认证 server 的 hints 可以驱动策略，互联网安装的 server 的 hints 只当信息参考。原文还给出一个可直接用于评审新 annotation 提案的五问框架：启用什么具体客户端行为、是否依赖信任才有用、`_meta` 能否替代、是否帮助推理工具组合、是 hint 还是 contract。给实践者的操作建议也很具体：server 作者给只读操作标 `readOnlyHint: true`、纯增量操作标 `destructiveHint: false`、封闭域工具标 `openWorldHint: false`；client/agent 作者对可信 server 的 readOnly 自动放行、destructive 要求确认，host 层做 taint tracking。现实约束也要如实记录：素材提到采用并不均衡，GitHub read-only 模式（约 17% 用户启用）是它找到的最接近的生产级类比。

## MCP 的代码执行式接入

### 从离散工具调用到「文件系统上的代码 API」

Anthropic 的《Code Execution with MCP》给出了一个重新框架化的接入模式：不把 MCP 服务器呈现为一组离散工具，而是为每个 server 生成一棵 TypeScript 文件树——一个工具对应一个带接口定义的文件，所有调用经统一的 `callMCPTool` 桥接回真实 MCP 服务器。模型用它本就擅长的能力（列目录、读文件、写代码）按需发现和调用工具，而不是把全部工具定义预先塞进上下文。

### token 从哪里省出来

素材记录了三笔账（均出自 Anthropic 实验数据）：

- **定义按需加载**：配合可选的 `search_tools`，上下文里的工具定义开销从 150,000 token 降到 2,000——即被广泛引用的 98.7%。
- **中间结果留在执行环境**：10,000 行的表格经代码过滤后，模型只看到 5 行加一条计数日志。
- **数据不过模型**：Google Drive→Salesforce 案例中，2 小时会议转录原本要在上下文里流经两次（约 50,000 额外 token）；代码执行下数据在变量间直接传递，全程不进上下文。

### 控制流下沉与隐私收益

循环、条件、错误处理、轮询等待都在执行环境本地跑，省掉了 agent 循环里「调工具→等响应→再调工具」的往返。素材对 harness 作者的概括是：让模型输出一段程序，而不是让它亲自扮演解释器。隐私则是架构级收益——harness 可以在 MCP client 层自动把 PII 令牌化（如 `[EMAIL_1]`），真实数据在工具间流转时由 client 做 lookup 还原，敏感数据从未进入上下文；数据流安全规则从「提示词约定」变成确定性代码。此外，跑通的代码可以沉淀为可复用文件（如 `skills/save-sheet-as-csv.ts`）配 SKILL.md，让 agent 随时间自建高层能力库——这正是下一节「技能即制品」的实现路径之一。

### 代价与适用边界

代价要诚实评估：运行 agent 生成的代码需要真正的安全执行环境——沙箱隔离、资源限制、监控。素材给出的落地建议是：优先在多步、大数据量、跨多 server 的工作流上启用此模式，简单单步调用仍保留直接工具调用。顺带一提，浏览器自动化领域的 playwright-mcp 提供了同型的降 token 案例：用可访问性树快照替代截图驱动浏览器——同样是「结构化输出替代高带宽负载」（[GitHub](https://github.com/microsoft/playwright-mcp)）。

## 技能：从提示词片段到工程制品

### 结构与路由

OpenAI 的《Shell + Skills + Compaction》描述的技能原语是对齐 Agent Skills 开放标准的版本化指令包：一个文件束，加一个含 frontmatter 与指令的 SKILL.md 清单。平台只向模型暴露 name、description、path 三个元数据做路由，正文仅在被调用时加载——这本质上是上一章注意力预算思想在能力层的延续：常驻上下文的只有路由信息，重内容按需投递。

Stripe 的实验给技能写作立了第一条铁律：被动文档会被代理无视，只有放进加载上下文的硬引导信号才可靠改变行为——「不在加载上下文里的指引等于没写」（[Stripe 实验记录](https://stripe.dev/blog/ai-steering-experiments)）。

### 一个数字的口径修正

素材本身完成了一次很有价值的核验，值得原样转述：流传的「加负面示例使技能路由准确率 73%→85%」并不准确。深读原文后发现，73%→85% 出自 Glean 案例中一个 Salesforce-oriented skill 带来的**整体评测准确率**提升（同时减少 18.1% time-to-first-token），而负面示例只是其中一项战术；真实的路由故事是——Glean 技能初上线时路由触发率反而下降约 20%，加负面示例与边界用例后才恢复。实操结论倒是稳定的：description 要写成 "Use when / don't use when" 的路由逻辑；模糊路由不可靠时，把技能名写成显式契约，直接在 prompt 里指名调用（素材引 Glean 的做法，并称模板与示例放进技能文件而非系统提示带来了最大的质量与延迟收益）。

### 把技能验证变成 CI 单元测试

技能既然是制品，就该有测试。素材提名了几条相互衔接的路线：skillgrade 把技能验证变成可重复的单元测试——从 SKILL.md 生成任务/评分对，对多家 agent 跑多轮评测并给出 CI 可用的通过率阈值（[GitHub](https://github.com/mgechev/skillgrade)）；SkillOpt 把技能当作可随执行反馈改进的优化参数；AIP 用图结构替换自由散文，使任务通过率从 53% 提升到 67%（素材转述的论文数据）。加上 Stripe 划定的「对齐信号必须落在加载上下文里」这条边界，这些工作共同把「写技能」从文案创作变成 [[ch07-evals-and-verification|评测与验证闭环]] 里可度量的一环。

Microsoft 的 Dataverse Skills 案例则补充了技能的编排语义：让 agent 自己学会何时走 MCP、何时降到 Python SDK、何时调裸 API——技能是把多工具集成栈藏在意图背后的执行策略（[Microsoft 开发者博客](https://devblogs.microsoft.com/powerplatform/dataverse-skills-your-coding-agent-now-speaks-dataverse)）。

## 协议栈与规格走向

素材铺 MCP 时特意强调它只是互操作协议栈中的一层：MCP 管工具/数据接入，A2A 管代理间路由，AG-UI 补代理到前端的实时通信；Google 的六协议指南（[开发者博客](https://developers.googleblog.com/en/developers-guide-to-ai-agent-protocols/)）可作选型地图——集成选型应先定「跨哪种系统边界」，再定协议。

建远程 MCP 基础设施前，规格走向值得先读。素材记录了 2026-07-28 发布的 MCP 规格候选（[官方博客](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)）是协议发布以来的最大修订：无状态核心砍掉 initialize 握手与 Mcp-Session-Id，并给出十二个月的废弃政策；而此前取代 HTTP+SSE 的 Streamable HTTP 传输中，有状态会话与负载均衡、横向扩展存在张力（[规格](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)）。结论与本章主线一致：接口与协议设计的第一性约束，仍是上下文经济学与可治理性。

## 本章小结

工具层的工程纪律可以压缩成三句话：工具是写给模型的契约，命名、返回值与错误消息都要按「模型会不会照做」来评审；注释是风险词汇表，硬保证必须落在沙箱与授权层，并警惕 lethal trifecta 式的组合风险；token 开销能挪出上下文的就挪——代码执行式接入与按需加载的技能路由，是同一思想的两次应用。素材中对 73%→85% 数字归因的核验修正也提醒我们：harness 工程里的数字值得逐条回原文核对，这正是本系列坚持全文深读的原因。

下一章：[[ch05-memory-and-state|记忆与状态管理]]
