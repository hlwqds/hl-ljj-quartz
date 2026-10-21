---
title: "Agent Harness 工程化（五）：记忆与状态管理"
date: 2026-10-21 00:50:00
description: "自纠错记忆、检索边界与状态外化：记忆系统何时是一阶杠杆、何时是负资产"
tags: [harness, ai-agents, memory, state]
---

# Agent Harness 工程化（五）：记忆与状态管理

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 5 篇
> 上一章：[[ch04-tools-and-mcp|工具接口与 Skills/MCP]] · 下一章：[[ch06-orchestration-and-human-in-loop|任务编排与人机协同]]

## 先给结论

- 记忆结构是 harness 层的设计责任：in-context 记忆在规模下系统性失效，持久事实必须落进结构化检索层，由 harness 管理生命周期，而不是指望上下文窗口自己扛。
- 记忆的头号问题是**过期而非缺失**：一条过期、分支特定的记忆比没有记忆更危险。失效检测必须是记忆系统的核心组件，而不是写入之后的收尾工作。
- 两个深读案例给出同一原则的两种工业化实现：GitHub Copilot 用「即时校验 + 重存续命」做惰性自愈，OpenWiki 用「版本比对 + 增量修复」做确定性遗忘。两者都把复杂度预算押在验证侧，而非检索侧。
- 与 [[ch03-context-engineering|上下文工程]] 的分界线：上下文是单次会话内易变的工作集，记忆是带生命周期的外部状态。判据是事实的持久性与可验证性，而不是容量大小。
- 记忆系统值得建的标准只有一条：性能随时间提升。做不到这一点的记忆层只是延迟与维护负担，是负资产。

## 记忆何时值得建：从上下文容器到基础设施原语

清单作者的核心主张是：**记忆结构是 harness 层的设计责任，不能指望模型或上下文窗口自己扛**。论据来自对 in-context 记忆的量化失效研究——转述清单收录的 Facts as First Class Objects 一文的测量，上下文能稳定承载的事实大约在 8000 条量级，超过即溢出；一次上下文压缩会损毁约 60% 的事实；级联式摘要导致 54% 的行为漂移（`README:285`）。另一篇 Governance Decay 测到更尖锐的失效：治理类约束在全上下文时违反率为 0%，压缩后升到 30%，部分模型高达 59%（`README:286`）。

这组数字的含义是：把「记住」外包给上下文窗口，等于把持久事实托付给一个**有损且易挥发的容器**。压缩对「叙事性内容」也许是可接受的近似，对「约束与事实」则是确定性破坏。这正是概念底座的由来——Anthropic 的
[Building Effective Agents](https://www.anthropic.com/research/building-effective-agents)
把 in-context 记忆、外部记忆、程序性记忆并列为 harness 层关注点（`README:269`）；
[Letta (MemGPT)](https://github.com/letta-ai/letta)
的 core/archival/recall 三层记忆则是这组概念最常被引用的参考架构（`README:270`）。

那么什么时候值得建记忆？作者的衡量标准不是「存了多少条」，而是**任务表现是否随时间提升**。正向证据如 MAGE：任务成功率提升 7.8–20.4 个百分点，同时 token 消耗节省 55.1%（`README:295`）；TencentDB-Agent-Memory 的四层渐进管线报出 61% 的 token 缩减与 51% 的相对通过率提升（`README:273`）。反过来，如果记忆层只增加了写入与检索成本、却不改变第 N 次任务的表现，它就是负资产。

形态上，作者主张跨会话记忆应当做成**可移植、可自托管的基础设施原语**，而非供应商附加品。清单里的落地谱系很完整：engram 打成单二进制（`README:275`）；Stash 用一套 Docker Compose 起齐 Postgres + pgvector + 后台固化管线（`README:272`）；deja-vu 复用已有磁盘轨迹、零额外依赖（`README:296`）；agentmemory 用一个服务经 MCP 同时服务多家 harness（`README:277`）；trajectory 则把 15+ 种 harness 的原生会话记录归一为一种面向 agent 消费的格式（`README:297`）。

## 头号问题是过期，而非缺失

清单反复强调的一个判断：**过期、分支特定的记忆比没有记忆更危险**（`README:281`）。缺失记忆只是让 agent 退回无先验状态；错误记忆则会以「曾经被验证过」的高置信度把 agent 带向错误结论——而且这类错误往往在几步之后才暴露，归因困难。

因此失效检测被各方案不约而同地当作核心组件：OpenWiki 把 staleness 做成一等可检视状态（`README:282`）；mex 把事实锚定到代码符号并检测符号漂移（`README:279`）；MemArchitect 直面 zombie memory 问题（`README:283`）。下一节的两个深读案例，正是这个思路的两种完整实现。

## GitHub Copilot：仓库级记忆池与即时校验

原文见
[Building an Agentic Memory System for GitHub Copilot](https://github.blog/ai-and-ml/github-copilot/building-an-agentic-memory-system-for-github-copilot/)，
是一个已部署系统的完整复盘。

### 架构：仓库即信任边界

核心架构是「仓库级共享记忆池 + 跨 agent 读写」。记忆严格 repository-scoped，coding agent、code review、CLI 三类场景共用同一个池；写入走 agent 可调用的 `store_memory` 工具，每条记忆的结构为 `subject / fact / citations / reason`，其中 citation 是 `"src/client/sdk/constants.ts:12"` 这类文件：行号列表；会话启动时把该仓库的最近记忆注入 prompt。

权限模型的取巧之处在于：**记忆的信任边界与源码本身重合**。能影响仓库内容的人本来就能影响这些事实，记忆因此不需要独立于代码仓库之外的另一套权限体系。

### 关键取舍：放弃离线整理，改为即时校验

团队认为难点不在检索，而在「代码跨分支、跨时间演化之后，知识是否仍然成立」。离线 curation（写入时集中整理、定期清洗）在 GitHub 的规模下工程复杂度和 LLM 成本都过高，于是他们放弃了这条路，改为 just-in-time 校验：**不在写入时保证正确，而在读取时验证**。

这一步利用的是生成-验证不对称性：产出一条正确的记忆很难，但验证一条记忆的 citation 只是少量简单的读操作——把文件：行号对应的代码拉出来比对即可。团队实测校验未显著增加延迟。

### 失效处理：惰性自愈，重存即续命

系统没有删除、去重或主动失效服务，失效处理是「惰性 + 自愈」：agent 遇到一条记忆时实时校验 citations 对当前分支是否仍然准确——若矛盾，prompt 引导 agent 存储修正版记忆；若通过校验且确实有用，则重新存储、刷新时间戳。用原文的话说，记忆池随着 agent 基于自身观察存入修正版本而自愈。「重存即续命」把活跃度信号和正确性信号合并成了同一个动作：被反复验证的记忆自然浮到前排，无人问津且过期的记忆自然沉底。

工程上的刻意留白同样有信息量：v1 的检索策略只是「取目标仓库最近记忆注入 prompt」，搜索工具和加权优先级都在 roadmap——团队把全部复杂度预算押在了验证侧，检索侧保持最简。

### 效果与评测

评测方法可以整体移植：一是对抗注入——故意植入与代码库矛盾、citation 指向不存在位置的记忆，观察 agent 是否一致地校验并更新；二是模拟真实记忆池——故意过度表示已废弃分支的记忆，构造最坏噪声。GitHub 报告的数字：离线评测中 code review precision +3%、recall +4%；A/B 实验（p<0.00001）中 coding agent 的 PR 合并率 90% 对 83%，code review 评论的正面反馈 +2%。

## OpenWiki：把「会遗忘」做成确定性机制

原文见
[Building Self-Correcting Memory in OpenWiki](https://www.langchain.com/blog/self-correcting-memory-openwiki)，
是迄今最具体的记忆自纠机制设计。

### 版本比对：零模型调用的失效检测

每条事实声明（claim）的结构为 `{statement, evidence[]}`，evidence 指向具体代码位置（如 `repo://src/scheduler.ts#L393-L404`）并**存储写入当时的证据版本号**。每次 wiki 更新开始时，先对全量 claim 做证据版本比对——原文明确这一步 no model calls。一个版本指纹就足以把「可能过期」与「确认正确」机械地分开，失效检测由此从「用模型判断」降级为「用哈希比对」。

两个细节值得记住：其一，存疑是**可持久推导的状态**，不是一次性 flag——存储的证据版本本身就能在每次更新时重新推导新鲜度，原文称之为 "uncertainty remains durable until the evidence is rechecked"；其二，stale 不等于 wrong——stale 只意味着这条声明不能默认为真，仍需复验后才能定性。

### 增量修复：成本随变更量而非总量缩放

修复策略拒绝全量重生成：agent 从不主动清扫 claim 集，只在读取某个页面时把该页的 stale claim 内联呈现、顺带解决；未解决的保持标记，留给后续更新，**绝不静默丢弃**。成本性质随之改变——原文的说法是更新成本随「代码改了多少」缩放，而不是随「wiki 里存了多少 claim」缩放。这与 Copilot 的惰性自愈在结构上同构：都不设主动清理进程，都把修复搭在正常读取路径上。

### 信任级别与收敛证据

OpenWiki 还把信任级别编码进可移植格式（OKF v0.2）：可携带信任摘要的 Markdown 中，`sources` 记录证据投影，`generated` 记录最后生产者，`verified` 只在整页 claim 集全部对账之后才写入。启示是通用的：agent 产物对下游暴露时，应当携带机器可读的信任级别，而不是让下游自行猜测。

量化证据显示反馈环真实收敛（LangChain 报告，每类 n=2000）：接入 claims runtime 后 Supported 从 92.9% 升至 97.8%，Stale 从 3.5% 降至 0.5%，Hallucinated 从 0.7% 降至 0；一次运行中代码变更使 17% 的 claim 变 stale，到下一个检查点 staleness 归零——「标记 → 复验 → 修复」的回路可以收敛，而不是无限堆积。

这套设计的哲学浓缩在一句话里："A memory system is only as good as its ability to forget"。遗忘不是删除记忆，而是知道一条信念何时不再可信。

## 与上下文工程的分界：什么进上下文，什么进外部状态

[[ch03-context-engineering|上下文工程]] 一章处理的是单次会话内的问题：投递取舍、注意力预算、压缩何时停止。本章处理的是跨会话的持久性问题。两者的分界可以归纳为一条判据：

- **任务局部、短生命周期、用完即弃**的内容进上下文——当前文件的片段、中间推理、一次性的工具输出；
- **持久、可验证、跨会话复用**的事实进外部结构化记忆——带 citation 的事实、约束、项目约定与演化历史。

两个方向上的越界都有代价。持久事实依赖上下文承载，就会撞上压缩的确定性损耗（约束违反率 0% 到 30%，`README:286`）；反过来，一次性中间结果落进记忆库，则是让记忆层承担工作集职能，只会放大过期问题。状态外化的原则在 [[ch02-agent-loop-and-planning|智能体循环与任务规划]] 一章已经出现——把计划写成工件、把进度写回文件；记忆系统只是把同一原则推到跨会话尺度：状态归仓，上下文只留工作集。

分界本身是工程选择而非教条。LangChain 的 Agent Builder 把 COALA 三层记忆建在 PostgreSQL 上、却以虚拟文件系统的形态暴露给 agent，且每次记忆写入都要过人工审批闸，AGENTS.md 则充当程序性记忆锚（`README:280`）——存储在后、呈现为文件，恰好是两个世界的桥接。Codified Context 的生产架构给出了另一组刻度：283 个会话、10.8 万行代码库上验证的「热记忆宪法 + 19 个领域专家 agent + 34 篇按需冷记忆文档」（`README:284`）。

最后回到单机视角：[[pi-agent-deep-dive|Pi Agent 深度探索]] 解剖的 Pi 把会话保存、分支恢复与 compaction 做成一等能力，那是单个 harness 的状态管理——会话文件即状态。一旦需求升级为跨会话、跨 agent、跨工具共享记忆，问题就变成了带生命周期管理的数据基建。这正是 Copilot 与 OpenWiki 两个案例的共同出发点：它们都不是在回答「怎么记住」，而是在回答「怎么知道还没忘」。

## 本章小结

记忆与状态管理的核心不是「存得多」，而是「错得少、能变好」：持久事实必须离开有损的上下文容器，落进由 harness 管理生命周期的结构化检索层；而过期记忆比缺失更危险，失效检测因此必须是确定性、可持久推导的一等机制。Copilot 的即时校验与 OpenWiki 的版本比对在结构上同构——检索从简、验证做重、修复搭在读取路径上。衡量记忆系统的最终标准只有一条：性能随时间提升，否则它就是负资产。

下一章：[[ch06-orchestration-and-human-in-loop|任务编排与人机协同]]
