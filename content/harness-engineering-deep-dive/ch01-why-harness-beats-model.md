---
title: "Agent Harness 工程化（一）：为什么 Harness 是一阶杠杆"
date: 2026-10-21 00:10:00
description: "同模型不同 harness 得分 68% vs 88%：仓库导览、作者三条立场与深读核验口径"
tags: [harness, ai-agents, coding-agent, awesome-list]
---

# Agent Harness 工程化（一）：为什么 Harness 是一阶杠杆

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 1 篇
> 上一章：无，从系列索引开始 · 下一章：[[ch02-agent-loop-and-planning|智能体循环与任务规划]]

## 先给结论

**同一个模型，换一套 harness，基准得分可以从 68% 提到 88%——harness 是被数字证明的一阶性能杠杆，不是模型的附属品。**

本系列基于一份对 awesome-harness-engineering 清单的精读综合报告展开。开篇先交代三件事：

- **这个仓库是什么**：一份按"问题"而非"厂商"组织的 harness engineering 精选清单，18 个条目单元共 502 条资源，从 agent loop、上下文管理一路覆盖到沙箱隔离、评测体系与生产运维。
- **清单作者的三条立场**：harness 组件默认会过期；harness 是被数字证明的一阶杠杆；收录标准偏向可证伪的生产与事故证据。
- **本系列的核验口径**：报告对 38 篇文献做了整篇深读、全部成功抓取，但覆盖只占清单的约 7%；个别原链已失效、个别数据在原文新版本中被修订——本系列引用时会如实带出这些边界，不做静默修正。

## 这个仓库是什么

### 一份按"问题"组织的精选清单

awesome-harness-engineering 的栏目引言自述：这份清单关注 harness 而非模型，并在开头直接给出学科定义——harness engineering 是"设计围绕 AI agent 的脚手架（上下文投递、工具接口、规划工件、验证回路、记忆系统、沙箱）"的学科。

这个定义并不抽象。本站此前的 [[pi-agent-deep-dive|Pi Agent 深度探索]] 系列逐包走读的 Pi，就是一个把 agent loop、工具执行、会话持久化与 compaction 做进核心骨架的具体 harness 实现——清单谈的正是围绕这类骨架的工程方法论。

"按问题组织"指 18 个条目单元各自对应一个工程问题，而非按厂商分类：

- Foundations（学科奠基文献）；
- Design Primitives（以 agent loop 为首节）、规划与任务分解、上下文投递与压缩；
- 工具接口设计、Skills & MCP、权限与授权、Memory & State；
- Task Runners & Orchestration、Verification & CI Integration、可观测与追踪、调试与开发体验；
- Human-in-the-Loop、Reference Implementations（值得研读的真实仓库）、Security, Sandbox & Permissions；
- 评测与验证体系、Templates（四个可复用模板文件）、生产运维基建、同类清单导航。

条目总量 502 条，最大的三个单元是 Reference Implementations（96 条）、Security, Sandbox & Permissions（46 条）和 Skills & MCP、Task Runners & Orchestration（各 42 条）——参考实现与沙箱的权重，本身就说明了作者的取向。

### 适合谁

- **深度使用 Claude Code / Codex 类 AI 编程工具、想系统化自己配置的人**：AGENTS.md 写法、skills/hooks、权限模式、评测门禁在清单里都有直接对应的栏目；
- **自建 agent harness 的工程师**：agent loop、编排、沙箱、评测基建、可观测各有独立单元；
- **系统/基础设施背景的工程师**：清单里大量内容本身就是分布式系统与 OS 层工程——session replay、沙箱决策链、cgroup/eBPF 资源控制、持久执行、OpenTelemetry 追踪。

### 怎么读

按报告给出的使用方式：先选一条阅读路径，再按栏目查"精读要点 + 资源表"。两点口径需要交代：

- 各节资源表是**选摘**（合计 219 条）而非清单全量，未单列的条目按 README 对应行号区间自查；
- "栏目提名"是研读工作流为每个单元指定的 2 篇整篇深读对象；README 本身是平铺条目列表，没有"必读"机制。

动手取向很直接：Templates 单元四个模板文件的定位是"Reusable starting points for harness artifacts. Copy and adapt."——复制、改造成自己的起点。

## 清单作者的三条立场

### 立场一：组件默认会过期

清单开篇明言：最好的 harness 在设计时就知悉其组件将随模型进步变得多余。这条原则贯穿选目——Anthropic 的长跑开发 harness 设计文提出"每个 harness 组件都假设模型做不到某事，而这些假设会随模型进步过期"；marmelab 的综述则建议给每个控制项设过期条件，让 harness 随模型进步"优雅腐化"。

### 立场二：harness 是被数字证明的一阶杠杆

清单作者用一组可查证的数字支撑这个判断（出处均见对应原文）：

- 同一模型经不同 harness 得分 **68% vs 88%**（出处：marmelab 审计报告）；
- 纯 harness 调优以约 1/10 的成本（$4.48 vs $43.48）把 Nemotron 3 Ultra 拉到距 Opus 4.8 一分之内；
- deepset 的失败分类框架证明不换模型可移动 20+ 排名；
- Anthropic 趋势报告称 harness 配置本身可摆动基准 5+ 个百分点。

### 立场三：只收可证伪的生产与事故证据

收录标准偏向有数据、有反例、可复盘的一手实践文献，而非厂商宣传。两个典型：Claude Code 质量退化 postmortem——推理档位降级、缓存 bug 丢思考历史、过度限长的系统提示，三个微小改动叠加成可见回归；Azure SRE Agent 两篇实证——故障缓解时间从 40.5 小时降到 3 分钟，从 100+ 专用工具转向文件系统化上下文后 Intent Met 从 45% 升到 75%。

## 奠基文献栏目精读

Foundations 单元（33 条）的编排本身就有方法论：并置 OpenAI、Anthropic、Martin Fowler、LangChain、arXiv 多个相互独立的定义出处，让这门新学科从不同阵营获得交叉验证的边界。主要坐标包括：

- [Harness Engineering（OpenAI）](https://openai.com/index/harness-engineering/)：为这门学科正名的奠基文，把 harness engineering 框架为"设计脚手架、让 Codex 类 agent 在 agent-first 世界可靠工作"的学科；
- [Building Effective Agents（Anthropic）](https://www.anthropic.com/research/building-effective-agents)：何时用 workflow、何时用 agent，以及如何组合基本原语；
- [The Anatomy of an Agent Harness（LangChain）](https://blog.langchain.com/the-anatomy-of-an-agent-harness/)：分解 harness 五原语，并警示模型可能与特定 harness 设计共同演化而过拟合；
- [What makes a harness a harness（arXiv 2606.10106）](https://arxiv.org/abs/2606.10106)：给出运行时层四要素的必要充分条件，并在 Claude Code、Codex CLI、Aider 等六个真实系统上做判据检验；
- [Harness Engineering（Martin Fowler）](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html)：把 harness 实践归纳为上下文工程、架构约束、熵管理三套互锁系统，报告评为对该学科最清晰的概念地图；
- [Harness Engineering for Self-Improvement（Lilian Weng）](https://lilianweng.github.io/posts/2026-07-04-harness/)：把 harness 视为递归自我改进的部署层，横跨多个主流 coding agent 的工具面稳定化案例。

这些定义互相并不完全一致，但共同点清晰：讨论的重心都在模型外围的工程层，而不是模型本身。下面重点深读其中被栏目提名的 OpenAI 两篇。

### Unrolling the Codex Agent Loop

按 OpenAI 作者的主张（[原文](https://openai.com/index/unrolling-the-codex-agent-loop/)），agent loop 是编排 user/model/tools 的核心逻辑：一次 turn 可含多轮 inference 与 tool-call 的迭代，唯一终止信号是 assistant message；agent 的"输出"不限于对话消息——写盘的代码才是主产出。

全文性能设计的根基是一个**前缀不变式**：对话历史按"旧 prompt 是新 prompt 的精确前缀"单调增长。因为采样成本主导网络成本，prompt cache 命中后采样开销从二次方降回线性，所以"精确前缀"值得作为硬性工程约束来维护。相应地有三大缓存失配雷区：中途变更 tools 列表、换 model、改 sandbox/approval mode/cwd——长对话中途响应 MCP 的 tools/list_changed 通知就是典型的昂贵失配。对策是**配置变化一律以追加新消息表达**，绝不修改历史消息。

上下文压缩也已从早期的手动文本摘要（/compact 命令）演进为隐状态交接：专用 compact 端点直接返回可替换原输入的 item 列表，内含携带不透明 encrypted_content 的压缩项，保留模型对原对话的 latent understanding。作者给出的复刻清单是四件事：无状态请求、前缀不变式、追加式配置变更、端点化压缩。

### Run Long-Horizon Tasks with Codex

这是长程任务的第一手实践指南（[原文](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex/)）。文章自述的实证框架：GPT-5.3-Codex 在空仓库、完全访问权限下无人值守连跑约 25 小时、消耗约 1300 万 token、产出约 3 万行代码，交付含画布编辑、实时协作等 10 项功能的设计工具。文章并引 METR 基准（前沿 agent 以 50%/80% 可靠性可完成的任务时长每约 7 个月翻倍），据此主张工程问题已从"写好一个 prompt"变成"设计 agent 在小时级尺度上保持连贯的系统"。

连贯性来自循环而非聪明 prompt：plan → 编辑代码 → 跑工具（test/build/lint）→ 观察结果 → 修复失败 → 更新文档/状态 → 重复。循环提供三样东西：真实反馈、外化状态（仓库/文件/文档即记忆）、随时间的可操控性；人类角色后移为在里程碑处把控。

落地为四个 Markdown 工件（深读经 GitHub API 核验，全部真实存在于实验仓库中）：

- **prompt.md**：冻结规格——目标/非目标、硬约束、交付物清单、"Done when"完成检查，防止建出 impressive but wrong 的东西；
- **plans.md**：唯一事实来源——里程碑按序执行，每个固定 Scope / Key files / Acceptance criteria / Verification commands 四字段，附风险登记册与决策日志；
- **implement.md**：执行手册——明令不在里程碑后停下来等确认；bug 处理四步法：先写复现失败的测试、修复、确认通过、在 plans.md 记说明；
- **documentation.md**：状态与决策日志——人离开数小时后回来仍可审计。

深读还核出一个迁移要点：文章里的命名（Plan.md/Implement.md）与仓库实际文件名（docs/ 下小写 plans.md 等）不一致，可搬的是章节模式而非文件名；仓库另有 AGENTS.md 承担环境约定（提交前必跑 typecheck/test/lint 等），所以完整移植是**五件套**：规格、计划、手册、状态日志、环境约定。证据边界同样要说明：25 小时/1300 万 token/3 万行均为文章自述、无第三方复核，文章未署名作者。

### 68% vs 88%：这个数字从哪来

立场二里最重要的 68% vs 88% 出自 marmelab 的综述 [The State Of AI Harness Engineering 2026](https://marmelab.com/blog/2026/09/24/the-state-of-ai-harness-engineering-2026.html)：该文审计了 246 个开源 harness 仓库与 57 篇文献，发现 60% 的仓库无测试无评测，并给出同模型不同 harness 的得分对比；方法论建议包括用可执行脚本替代散文规则、给控制项设过期条件。清单作者把它作为"一阶杠杆"的核心证据引用，读者应回到这份审计本身核对口径。

## 深读核验口径：如实交代证据边界

报告的深读层有明确的口径，本系列沿用：

- **覆盖度**：38 篇深读对应 19 个单元各 2 篇栏目提名（其中一篇被两个单元重复提名，实际 37 篇不同文章），覆盖 37/502 ≈ 7%——属重点精读而非全量覆盖；
- **抓取状态**：38 篇全部成功抓取，其中 36 篇为文章/论文全文，另 2 篇是 GitHub 仓库 README 页面，证据强度有别；所有快照未在工作区留存，深读层断言无法从工作区副本二次复核。

核验中发现的典型问题，引用相关资源时需要注意：

- **失效链接**：Anthropic《Beyond Permission Prompts》的 README 原链已 404，真实地址为 `anthropic.com/engineering/claude-code-sandboxing`（经搜索确认标题与发布日期后另抓全文）；
- **口径被原文修订**：Claude Agent SDK 权限文档现行版已把求值顺序列为六层（清单提名时写"五层"）；AgentCgroup 的 OS 层延迟占比在 v1 正文为 56–74%，当前 v3 摘要改为 55–60%，引用宜用后者；OpenAI Windows 沙箱文实际发布于 2026-09-11，README 标注的 July 2026 有偏差；
- **同一实验两套数字并存**：某压缩对照实验在素材中同时出现"全史 100% 召回 vs 压缩后 58%"与"92% 召回 vs 38%"两组数字，素材无法确认两者的窗口口径差异，报告如实并置、不作调和——遇到这种情形，正确做法是标注不确定，而不是挑一个顺手的数字用；
- **同一论文两套描述**：arXiv 2603.06847 在素材中同时出现"6 框架/375 issue"与"40 仓库/13,602 issue"两种描述，经核对 README 原文为后者——这类冲突必须回原文裁决，不能二选一了事。

因此本系列的引用纪律是：转述时保留"作者主张"口径，数据注明出处文章；发现版本冲突时以原文现行版为准并注明差异。

## 本章小结

本章交代了整个系列的底座。awesome-harness-engineering 是一份按问题组织的 502 条精选清单，清单作者以三条立场选目：harness 组件默认会过期、harness 是被数字证明的一阶杠杆（同模型 68% vs 88%）、只收可证伪的生产与事故证据。奠基文献栏目中，OpenAI 两篇 Codex 文章分别给出了 agent loop 的性能设计根基（前缀不变式与追加式配置变更）和长程任务的工件化实践（规格、计划、手册、状态日志加环境约定的五件套）。深读核验口径提醒我们：约 7% 的覆盖、失效的链接、被修订的数据，都要求引用时保留出处与版本意识。后续章节将沿清单的栏目顺序，逐个拆解 agent loop、规划、上下文、工具与验证回路。

下一章：[[ch02-agent-loop-and-planning|智能体循环与任务规划]]
