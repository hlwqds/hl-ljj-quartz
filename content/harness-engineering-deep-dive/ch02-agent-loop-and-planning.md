---
title: "Agent Harness 工程化（二）：智能体循环与任务规划"
date: 2026-10-21 00:20:00
description: "agent loop 的最小组件、计划工件与状态外化：长程任务不翻车的结构做法"
tags: [harness, ai-agents, agent-loop, planning]
---

# Agent Harness 工程化（二）：智能体循环与任务规划

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 2 篇
> 上一章：[[ch01-why-harness-beats-model|为什么 Harness 是一阶杠杆]] · 下一章：[[ch03-context-engineering|上下文工程]]

## 先给结论

**循环决定 agent 的行为骨架，规划决定长程任务的状态归宿：两者都应当由 harness 的确定性结构承载，而不是托付给提示词和模型自律。**

- Agent Loop 是其余 harness 组件的挂载骨架。一次迭代可拆成 observe → plan → act → verify，权限、上下文、记忆、验证最终都要回答"挂在循环哪个环节"。
- 可控行为来自确定性机制：可测量的停止条件、钩子与中间件、状态机约束——提示词只是其中一层，且被多篇案例证明"纯提示不够"。
- 规划的价值不在"想得周全"，而在把计划从一次性推理痕迹变成**可审查的持久工件**：里程碑绑定 verify 命令，让"完成"可以被一条命令的退出码判定。
- 任务一旦超出单上下文窗口，状态必须外化到仓库工件（计划文件、进度日志、机器可读的功能清单），每个新会话靠读文件恢复现场，而不是靠 compaction 硬传。
- 防"翻车"的两个具体抓手：编码会话**基线端到端测试先行**；功能清单只许 agent 改一个 `passes` 字段，测试本身不许动。

下文循着"循环 → 循环改造案例 → 规划工件 → 五件套 → 状态外化"的顺序展开，素材主要来自 Anthropic 与 LangChain 的工程博客及 OpenAI 的长程任务实践指南，文中数字均注明出处文章，属第三方作者主张。

## Agent Loop：最小组件与确定性增强

### 最小骨架

几乎所有 agent harness 都建立在 ReAct 的 Thought / Action / Observation 结构上——这篇奠基论文（[arXiv:2210.03629](https://arxiv.org/abs/2210.03629)）定义的循环形态至今仍是各类实现的共同底座。OpenAI 在 Unrolling the Codex agent loop 一文中把一次迭代更细地拆为 observe → plan → act → verify 四步，成为讨论"循环各环节"的共同坐标。

```text
observe -> plan -> act -> verify -> (继续下一轮，或触发停止条件退出)
```

Anthropic 的 Getting started with loops 给出了一个极简的统一定义：loop 就是"agent 重复工作周期，直到停止条件满足"。文章按"你交出什么"区分四种循环原语：

- **turn-based**：交出检查权——每轮之间回到人这里确认，适合探索、决策类任务；
- **goal-based**：交出停止条件——用 `/goal` 一类机制声明完成标准，agent 自己迭代到达标；
- **time-based**：交出触发时机——`/loop`、`/schedule` 按时间点反复运行；
- **proactive**：交出整个提示——对持续流入且定义明确的活（issue 分诊、依赖升级）全自动响应。

选型建议是先问"哪一环可以不经过我"，而不是先挑工具。其中 goal 循环的核心杠杆是**确定性停止条件**：用可测量的标准（通过的测试数、分数阈值、Lighthouse ≥90）定义完成，模型就不必自行判断"够好了"而提前退出。

### 常见增强：把可控性交给结构

在最小骨架之上，被广泛采用、研读笔记中反复出现的增强模式有：

- **显式图与检查点**：LangGraph 把循环建模为带类型状态、条件边与检查点的有向图，终止条件、分支与中途持久化都有具体工程做法（[Low Level Concepts](https://langchain-ai.github.io/langgraph/concepts/low_level/)）。
- **钩子与中间件**：Codex Hooks 在 SessionStart、PreToolUse、PostToolUse 等循环事件点注入确定性脚本做护栏与审计，明确不依赖提示级信任（[Hooks – Codex](https://developers.openai.com/codex/hooks)）；LangChain 的 middleware 则提供 before_agent 到 after_agent 的六个可组合钩子，把脱敏、重试、人工中断做成不修改 agent 本体的中间件。
- **状态机收缩工具空间**：statewright 按工作流阶段约束可调用的工具，把开放式循环变成确定性状态迁移——其作者声称本地模型在 SWE-bench 子集上从 2/10 升到 10/10（[statewright](https://github.com/statewright/statewright)）。

这些条目的共同主张是：**循环的可控行为应来自 harness 结构设计，而非提示词或模型自律。**支持这一主张的证据还包括：LangChain 团队称只改 harness 不换模型，就让自己的 agent 在 Terminal Bench 2.0 从约 rank 30 升到 top 5；deepclaude 项目把同一套循环移植到 DeepSeek 仍保持同样行为，说明循环结构独立于具体模型；Life-Harness 则论证许多 agent 失败是接口错配而非推理缺陷——先查 harness 再怪模型。

循环各环节还藏着不少隐性约束，属于"不踩不知道"一类：扩展思考的 thinking block 不随工具结果回传会静默破坏多步推理；时间感知（当前时间、截止时间、预算）必须由 harness 注入而非假设模型自带；运行时持久化模式与训练语义错配，会导致高比例丢变量错误或数倍 token 开销。这些细节决定了"挂件"必须挂在正确的环节上。

顺带一提，[[pi-agent-deep-dive|Pi Agent 深度探索]] 系列里走读过的那个极简 harness，核心就是一个显式的主循环加一组工具执行规则——本篇要补的视角是：这个循环上还能挂什么，以及挂上之后行为会发生什么变化。

## 一次只改 harness 的对照实验

LangChain 的 Improving Deep Agents with Harness Engineering 是循环改造最完整的公开案例（[原文](https://blog.langchain.com/improving-deep-agents-with-harness-engineering/)）。实验设计干净：模型固定为 gpt-5.2-codex，只改 harness，deepagents-cli 在 Terminal Bench 2.0（89 个任务）上从 52.8% 提到 66.5%（+13.7 分），文章称约合从 top 30 开外进入 top 5。全部优化收敛到三个旋钮：System Prompt、Tools、Middleware。

几个值得照抄的做法：

- **最高杠杆单项是强制 build-verify 循环。**作者统计最常见的失败模式是：agent 写完方案后重读自己的代码、确认"看起来没问题"就停。修复做了两层：系统提示写入四阶段流程（Planning & Discovery → Build → Verify → Fix），并强调 Verify 要对照任务要求而非自己的代码；再用确定性的 PreCompletionChecklistMiddleware 在 agent 退出前拦截，强制对照任务规格再验证一轮。作者的结论很直接：纯提示不够，提示加确定性中间件才立得住。
- **上下文注入是 harness 工程师的本职。**启动时映射目录结构、探测环境工具；注入时间预算警告促使 agent 收尾转验证（agent 对时间的估计出了名的差）；明确告知"你的产出会被程序化测试评分、spec 里的文件路径必须严格照写"。
- **循环检测中间件是打补丁式的短期护栏。**统计每个文件的编辑次数，同一文件改到第 N 次就注入"考虑重新审视你的方法"。作者自己承认这是针对当前模型缺陷的启发式，模型进步后这类护栏大概率会拆除。
- **推理算力按阶段分配优于全程拉满。**文章给出的数据：全程最高推理档因超时只得 53.9%，全程中高档 63.6%，而"规划与最终验证给最高预算、实现阶段降档"的 reasoning sandwich 组合推到 66.5%。

另有一个常被忽略的附注：换成 Claude Opus 4.6 用早期 harness 只得 59.6%，差距来自没为它跑同等的改进循环而非模型不行——**harness 必须按模型定制**，护栏与提示的调参不能跨模型免迁移。

## 规划：从一次性推理到持久工件

### Plan-and-Execute 谱系

规划与执行拆层的源头通常追溯到 LangChain 2023 年的 Plan-and-Execute Agents（[原文](https://blog.langchain.com/plan-and-execute-agents/)）。模式定义极简，就两行伪代码：先"Plan steps to take"，然后对每个步骤"决定用合适的工具或最佳行动去完成该步"。Planner 几乎总该是一个语言模型，Executor 在最初实现里就是拿单个步骤当目标的小 agent。文章显式承认代价是"调用次数多得多"，押注在于关注点分离后 planner 与 executor 可以各自换成更小、更快、更便宜的模型——多花调用与延迟，换上下文效率和每环节可靠性，这是整个 plan-then-execute 谱系的核心 trade（思想源头标注为 BabyAGI 与 Plan-and-Solve，[arXiv:2305.04091](https://arxiv.org/abs/2305.04091)）。

原文列的四条局限——步骤线性传递、无重规划、无评估、单一执行链——事后看恰好是后续几年这条谱系的议程表。以重规划为例，Plan-and-Act（[arXiv:2503.09572](https://arxiv.org/abs/2503.09572)）补上了 replanner，并给出 planner 与 executor 可独立配置模型规模、工具与推理预算的证据（文章报告 WebArena-Lite 57.58%、WebVoyager 81.36%）。

### 计划工件与 verify 门

比"拆层"更进一步的主张是：**计划应当是 harness 的持久工件，而非模型的一次性推理痕迹。**这一派的做法从 Codex 的里程碑式 Plan.md / Implement.md，到 GitHub Spec Kit 的 spec.md → plan.md → tasks.md 三件套（[spec-kit](https://github.com/github/spec-kit)），再到 Anthropic 的特性清单 + git 提交 + 测试门，形态各异但同构：任务超出单上下文窗口时，朴素重启会丢失累积进度，只有文件化计划能跨会话保住状态；计划质量也因此成为可审查的工件，而不是转瞬即逝的推理轨迹。

其中最关键的机制是**里程碑绑定 verify 命令**：计划里的每个里程碑都带显式验证命令，"做完"的定义与一条命令的退出码绑定，而不是代理的自评。研读笔记里对这个机制的概括很准：它把计划从愿望清单变成可逐步判定的执行合同。Anthropic 的模板清单也把"代理能自己跑验证、验证在任务完成时自动执行、评测标准先于任务写下"列为检查项——因为无门的代理倾向于宣称完成。

## 长程任务的最小五件套

OpenAI 开发者博客的 Run Long-Horizon Tasks with Codex（[原文](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex/)）给出一套可直接搬运的规划工件。研读笔记核对过对应实验仓库，四个 Markdown 文件真实存在于仓库 docs/ 下，加上仓库根的 AGENTS.md，构成完整的五件套：

1. **prompt.md——冻结规格**。写目标与非目标、硬约束、交付物清单，以及"Done when"式的完成检查与演示流程，防止 agent 建出 impressive but wrong 的东西。
2. **plans.md——唯一事实源**。里程碑按序执行，每个固定四字段：Scope / Key files / Acceptance criteria / Verification commands；另配决策日志与风险登记册。验证清单带时间戳，防"事后补验"。
3. **implement.md——执行手册**。明令不在任何里程碑后停下来提问或等待确认；小步提交并注明里程碑；bug 四步法：先写复现失败的测试 → 修复 → 确认通过 → 在 plans.md 记说明；末尾硬性完成标准全满足才许停。
4. **documentation.md——状态与决策日志**。让人离开数小时后回来仍可审计当前进度与当时的取舍。
5. **AGENTS.md——环境约定**。提交前必跑的 typecheck / test / lint、提交纪律等仓库级规则，作为所有会话共享的常驻层。

两点迁移提醒（研读笔记核实）：原文中的文件命名与实验仓库实际文件名不完全一致（仓库里是小写的 plans.md 等），要搬的是章节模式而不是文件名；文中 25 小时、13M token、3 万行等数字为文章自述，无第三方复核。

这套五件套与 Anthropic 模板四件套（PLAN.md / IMPLEMENT.md / HARNESS_CHECKLIST.md / AGENTS.md）高度同构：PLAN.md 对应 plans.md，IMPLEMENT.md 对应 implement.md——两家工程团队的实践独立收敛到相近的骨架，这本身就是一个可参考的信号。

## 状态外化：跨会话的会话协议

Anthropic 工程博客的 Effective Harnesses for Long-Running Agents（[原文](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)）把状态外化讲得最透。核心论点：compaction 不足以支撑跨上下文窗口的任务，**状态必须外化为仓库工件**。作者把长时程任务比作换班制的软件项目——每个新 context window 开局对之前一无所知，而 compaction 不能保证把清晰指令完整传给下一个 agent；解法不是等更大的窗口，而是让进度状态持久化在 git 历史、进度文件与机器可读的功能清单里。

文章从两种失败模式反推出 harness 设计目标：一是 greedy one-shot——agent 试图一次性完成整个应用，上下文耗尽后留下无文档的半成品，靠"一次只做一个功能"的增量纪律约束；二是项目后期的"过早宣布完工"，靠外部可验证的完成判据约束。

具体的会话协议值得整段照抄到自己的工作流里：

- **初始化会话不写业务代码**，专职搭脚手架：一键起 dev server 的 init.sh、工作日志进度文件、初始 git commit，以及从用户提示扩展出的 JSON 功能清单——文中 claude.ai 克隆的例子扩展出 200 多项功能，全部初始标记为 failing。
- **功能清单用 JSON，且只许改一个字段。**每条含 category / description / steps / passes 四个字段；选 JSON 的实测理由是"模型不太会像改 Markdown 那样不当改动或覆盖 JSON 文件"。编码 agent 仅允许修改 `passes` 状态，并以强措辞约束"删除或编辑测试是不可接受的"。示意结构如下：

```json
{
  "category": "checkout",
  "description": "购物车结算流程",
  "steps": ["渲染表单", "提交订单", "显示确认页"],
  "passes": false
}
```

- **每个编码会话执行固定开场协议**：确认工作目录 → 读 git log 与进度文件热身 → 读功能清单选最高优先级的未完成项 → 跑 init.sh 起服务，**先做基线端到端测试**确认应用未坏，再开发新功能。基线测试先行，让遗留 bug 在新代码叠加之前暴露；会话结尾写描述性 commit 与进度总结，给下一个窗口留现场。
- **端到端验证必须显式指定工具与方式。**作者观察到 agent 缺省只写单元测试或 curl 检查，常在功能实际不可用时照常报告完成；明确指示用 Puppeteer MCP"像人类用户一样用浏览器完成所有测试"后，效果大幅改善。已知盲区也要写进预期：浏览器原生 alert 弹窗 Puppeteer 看不到。

值得注意的是文中两个 agent 只有初始 user prompt 不同，系统提示、工具集与 harness 完全一致——作者借此把增益归因于 harness 本身而非提示工程。

## 如果只做三件事

把本篇的做法压缩成最小落地集：

1. **给循环立确定性停止条件**：完成标准用可测量指标（通过的测试数、分数阈值）表达，别让模型自行判断"够好了"；在退出路径上加一道确定性的完成前检查。
2. **非平凡任务先立计划工件**：里程碑绑定 verify 命令，配套 append-only 的实施日志；计划是可审查的合同，不是聊天记录。
3. **跨会话任务外化状态**：功能清单、进度文件、git 历史三件齐备；每个会话基线端到端测试先行，agent 对验证清单只有"勾 pass"的权限。

## 本章小结

主循环 observe → plan → act → verify 是其余 harness 组件的挂载骨架，而可控行为应当来自停止条件、钩子、中间件这类确定性结构——提示词只是其中一层，多个案例证明纯提示立不住。规划的价值在于把计划从一次性推理变成可审查的持久工件，里程碑绑 verify 命令让"完成"可以被命令退出码判定。超出单上下文窗口的任务靠状态外化续命：计划文件、进度日志与只许改 `passes` 字段的 JSON 功能清单，都在做同一件事——让每个新会话能廉价、无歧义地恢复现场。最后，基线端到端测试先行是防"过早宣布完工"的关键一招，也是所有验证门里性价比最高的一道。

下一章：[[ch03-context-engineering|上下文工程]]
