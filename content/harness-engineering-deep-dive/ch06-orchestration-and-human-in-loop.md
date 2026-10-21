---
title: "Agent Harness 工程化（六）：任务编排与人机协同"
date: 2026-10-21 01:00:00
description: "并行 agent 编排、brain/hands 解耦与审批疲劳：把人放在回路里而不被回路淹没"
tags: [harness, ai-agents, orchestration, human-in-the-loop]
---

# Agent Harness 工程化（六）：任务编排与人机协同

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 6 篇
> 上一章：[[ch05-memory-and-state|记忆与状态管理]] · 下一章：[[ch07-evals-and-verification|评测与验证闭环]]

## 先给结论

本系列前几章与 [[pi-agent-deep-dive|Pi Agent 深度探索]] 关注的都是单个 agent 的 harness 内部构造；本章把镜头拉远，看两件上层建筑的事：多个 agent 之间怎么编排，agent 与人之间的控制面怎么设计。先给结论（以下均系素材中原文作者的主张，本章按此口径转述）：

- **编排层越确定、越"薄"，系统越可靠。** Shopify Roast 把"非确定性是可靠性的敌人"写进设计哲学，Microsoft Conductor 用 YAML 静态编排做到编排层自身零 token 开销；而 Anthropic 的 16-Claude 并行实战干脆不用编排 agent，一切协调都落在 git 的事务语义上。
- **隔离优于协调。** Google Scion 的核心主张是让每个 agent 在独立容器、git worktree 与网络策略内完全自主——"碰不到彼此状态的 agent 就不会冲突"，护栏建在基础设施层而非提示层。
- **brain 与 hands 解耦是生产级编排的参考架构。** Managed Agents 把模型循环（brain）、执行环境（hands）与会话日志（session）拆成三个可独立失败、独立替换的无状态组件。
- **审批不是 yes/no 开关。** Claude Agent SDK 的 canUseTool 支持"批准并修改"、"批准并记住规则"等非二值形态；AWS 样例库则把 human-in-the-loop 归纳为工具调用链上四个可插入的拦截层。
- **人的注意力是稀缺的 harness 资源。** 实证数据显示成熟用户从逐动作审批走向"只干预"；Fowler 更进一步主张 "humans on the loop"——HITL 的终态是从"门"演化为"反馈机制"。

## 编排层的三个基本立场

进入实战案例前，先看素材从该栏目十余个项目中归纳出的三条共识。

### 确定性编排优先于纯自主

[Shopify Roast](https://github.com/Shopify/roast) 用 Ruby DSL 把确定性步骤与 agentic 步骤交错排列；[Microsoft Conductor](https://github.com/microsoft/conductor) 走 YAML-first 路线，Jinja2 做路由、静态并行组、按 agent 覆写模型，编排层自身不花一次模型调用。同一方向上还有把多 agent 目标编译成确定性执行 DAG 的 Hive，以及 40+ agent 零 LLM 协调回路的 bernstein。共同点很清晰：生产可靠性来自版本化、可 diff 的结构化控制层，而不是一个更聪明的协调者。[OpenAI 的 Harness Engineering](https://openai.com/index/harness-engineering/) 一文把任务运行器的职责同样定位在队列、并行度与进度汇报这类朴素事务上。

### 隔离优于协调

[Scion](https://github.com/GoogleCloudPlatform/scion) 自称"agent 虚拟机管理程序"：每个 agent 独立容器、独立 git worktree、独立凭据与网络策略，完全自主工作。协调成本高的场景，往往用隔离就能消掉——素材将 bernstein、Orca、sandcastle 都归为这一模式的变体。

### 状态外置，可恢复是一等公民

[Codex as a platform](https://developers.openai.com/blog/codex-as-a-platform) 给出了嵌入式 agent 分工的清晰表述："应用拥有界面、业务上下文、MCP 工具与审批门，app-server 拥有 agent loop 与沙箱执行"。配合这一解耦的是状态外置：[LangGraph](https://github.com/langchain-ai/langgraph) 的 checkpoint-resume 支撑多日可恢复任务，Google ADK 的 pause/resume 让容器可缩容到零，[Temporal](https://temporal.io/blog/orchestrating-ambient-agents-with-temporal) 把分布式系统的 durable execution 与重试语义引入 agent 编排。上一章 [[ch05-memory-and-state|记忆与状态管理]] 讨论的会话持久化，在这里落地为编排层的恢复语义。

## 实战标本：16 个 Claude 无中心并行编写 C 编译器

无中心并行这条路走得通吗？[Building a C Compiler with a Team of Parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler) 是目前最完整的公开实战记录。据原文作者统计：16 个 Opus 4.6 agent、约 2000 个 Claude Code 会话、两周时间、近 $20k 成本（2B 输入 / 140M 输出 token），产出 10 万行 Rust，多数测试套件通过率 99%（含 GCC torture tests），能编译 Linux 6.9 并跑在 x86/ARM/RISC-V 上。

### git 就是协调层

作者明确写道 "I don't use an orchestration agent"：agent 之间没有任何通信，一切协调都走同一个 bare git repo。每个 agent 跑在一个 Docker 容器里，驱动程序只是一个 bash `while true` 循环，反复启动全新的 `claude --dangerously-skip-permissions -p "$(cat AGENT_PROMPT.md)"` 会话（Ralph-loop 形态）。基础设施薄到极致，复杂度全部花在任务协议与测试框架上。

任务认领即文件锁：agent 向 `current_tasks/` 目录写文本文件认领任务；两个 agent 抢同一任务时，git push 的同步机制天然让后到者改选别的任务。素材作者的概括是：多 agent 并行不需要消息总线，git 的事务语义（push 冲突等价于二阶段锁失败）已是最小充分的协调层。

### 重启续接靠外部化状态

无限循环的每一轮都是零上下文的全新会话，续接依赖提示词强制要求的 README、进度文件与运行日志（日志文件名带当前 git commit 短哈希）。长程自治的前提是把"我现在在干什么"写进 repo——这与上一章的外部化记忆是同一个原则在编排场景的投影。

### 上下文污染是头号工程问题：测试框架是给模型用的 UX

作者说要 "constantly remind myself that I was writing this test harness for Claude and not for myself"。具体规则：测试输出最多几行，重要信息写文件不刷屏；出错时在同一行输出 `ERROR` 加原因，方便 grep；预先算好汇总统计。对长时间无输出的"时间盲区"，用低频增量进度输出加默认 `--fast` 随机采样解决——采样在单 agent 内确定性、跨 VM 随机，兼顾回归定位与全量覆盖。素材把这提炼为一条普遍规律：反馈回路的带宽决定并行成败——16 路并行若各自刷屏，污染的是每个 agent 自己的上下文。

### 真正的瓶颈是任务可分解性

各领小项目时 16 个 agent 顺风顺水；一旦目标是编 Linux 内核这种单一巨型任务，16 个 agent 全卡在同一个 bug 上互相覆盖改动。解法是以 GCC 为 oracle 的二分框架：随机让大部分内核文件仍用 GCC 编译、只留少量交给 Claude 编译器，按内核能否启动递归缩小范围；之后还需 delta debugging 定位"单独编译都过、合在一起失败"的文件对。素材的概括值得记住：**验证器能切多细，并行才走多深。**

### 上限与风险同样有据

这篇文章不是营销文，失败模式写得很实：生成代码的运行效率全开优化也不如 `-O0` 的 GCC；作者认为已逼近模型能力上限，只能靠严格 CI 强制测试兜底；运行中还出过 agent 执行 `pkill -9 bash` 杀死自己驱动循环的事故。作者结语直言不安：人不在场时，系统倾向于"看到测试通过就算完成"。

## brain 与 hands 解耦：Managed Agents 的三组件架构

无中心并行适合一批对等的研究型任务；长驻生产服务则需要另一套架构。[Scaling Managed Agents: Decoupling the brain from the hands](https://www.anthropic.com/engineering/managed-agents) 给出的三组件设计值得逐条看。

### Session、Harness、Sandbox 各自成层

Session 是 append-only 事件日志，持久化在沙箱之外；Harness 是调用模型并路由工具调用的循环，即 brain；Sandbox 是执行环境，即 hands。三者各自成为低耦合接口后，容器被降格为统一工具接口 `execute(name, input) -> string`——harness 不关心 hands 是容器、手机还是模拟器，hands 也可以在不同 brains 之间移交。

### 模型假设会腐烂

harness 内编码的模型假设是待过期资产。原文举的例子：Sonnet 4.5 有 "context anxiety"（临近上下文上限就提前收尾任务），harness 为此加了 context reset 逻辑；换到 Opus 4.5 该行为消失，reset 成了死代码。素材作者称之为 Bitter Lesson 的工程化表述——任何针对特定模型缺陷写的编排逻辑，都是按月过期的资产。

### session replay：harness 也是 cattle

事件日志在 harness 之外，意味着 harness 内不需要任何东西在崩溃后存活：新 harness 以 `wake(sessionId)` 拉起，从最后一条事件恢复。"Cattle not pets" 的真正动机是可诊断性而不只是弹性——旧的 pet 式单容器架构有三重痛点：容器挂则 session 丢失；唯一的观测窗口（WebSocket 事件流）无法归因故障；容器内含用户数据，不敢开 shell 进去调试。原文称这"实质上意味着我们失去了调试能力"。

量化数据（据原文，全文仅此一处）：解耦后 p50 TTFT 降约 60%，p95 降超 90%。机制是容器改为按需经工具调用供应，推理可直接从 session log 拉取 pending events 立即开始，不再预付容器冷启动成本；p95 降幅远大于 p50，说明尾部延迟几乎全是被消除的冷启动。

### 安全边界顺带修复

旧设计中不可信代码与凭据同处一个容器，prompt injection 只需诱导模型读自己的环境即可偷到 token。新方案里 token 从沙箱内不可达：git 用各仓库 access token 在初始化时 clone 并接本地 remote；MCP 的 OAuth token 存 vault，经专用 proxy 按会话注入，harness 自己也拿不到。

## 审批交互的工程模式

编排决定 agent 之间怎么协作，审批决定 agent 与人之间的控制面。Claude Agent SDK 的[审批文档](https://code.claude.com/docs/en/agent-sdk/user-input)是目前最完整的一份参考设计。

### canUseTool 是裁决点，不是观测点

canUseTool 回调在每个工具请求处暂停执行，返回 allow 或 deny；deny 时必须附 message——模型会看到拒绝原因并调整路线。最关键的工程事实是：**canUseTool 从不在自动批准的调用上触发**。要在每一次工具调用上插入审计、限流或通知逻辑，必须改用 PreToolUse hook。把"裁决点"误当"观测点"用，自动批准路径会静默旁路你写在回调里的检查。

### 非二值审批：approve-with-changes 与 approve-and-remember

allow 分支天然支持第三种动作：直接改写 `updatedInput` 再放行——比如把 Bash 命令里的路径重写到沙箱目录——且文档明示 "Claude sees the result but isn't told you changed anything"。这把 HITL 从 yes/no 审批升级为"人工修正管道"。回调第三参数携带的 suggestions（一组 PermissionUpdate）则支持"批准并记住"：筛选后回传，规则即持久化到本地设置，实现"一次审批沉淀为长期规则"的闭环。

### 结构化澄清与中途改向

AskUserQuestion 把"问人"做成结构化交互：每次 1–4 题，每题带短标签（header）与 2–4 个选项（label 加 description），响应以"问题全文 → 所选 label"的键值对回流。若要完全改向，用 streaming input 在工具请求挂起期间注入全新用户指令。

### 长时审批与无状态宿主

审批回调可以无限期 pending；但若宿主是 serverless 这类短生命周期进程，正解是注册 PreToolUse hook 返回 defer decision，让进程得以退出、之后从持久化 session 恢复。配套的 PermissionRequest hook 可在等待审批时外发通知（Slack/邮件/推送），适合无人值守长任务的远端审批。

## AWS 样例库：HITL 的四个拦截层

[aws-samples/sample-human-in-the-loop-patterns](https://github.com/aws-samples/sample-human-in-the-loop-patterns) 的价值在于可运行：四种模式对应工具调用链上四个不同的插入位置，基本穷尽了 HITL 可以安放的地方。下表归纳自该仓库 README 的对比维度：

| 模式                      | 拦截层      | 信任边界与审批延迟               |
| ------------------------- | ----------- | -------------------------------- |
| ApprovalHook 统一回调     | 框架层 hook | 审批者在会话回路内，实时         |
| 工具内 check_access       | 工具内部    | 会话回路内，实时，可顺带做 RBAC  |
| Step Functions + SNS 邮件 | 外部编排    | 系统之外，异步，延迟以小时/天计  |
| MCP Elicitation           | 协议层      | MCP 客户端 UI 内，协议原生，实时 |

素材作者的提醒是：README 只给出对比维度，选型决策需读者按"审批延迟、信任边界、集成约束"三个轴自行推导。样例中几个机制可直接移植：

- **信任的持久化（t(trust) 模式）**：批准后把 approval_key 写入 agent.state，粒度到工具+动作+对象（patient），后续同键调用跳过提示。键粒度精确到 action+patient 而非整个工具，是安全上的正确选择。
- **中断/恢复协议**：agent 暂停时 entrypoint 返回 `stopReason: "interrupt"` 附 interrupt ID，客户端收集人的决定后以 interruptResponse payload 回调，agent 从缓存恢复现场继续执行——这是 HITL 在无状态托管 runtime 上可行的关键机制。
- **超长审批三件套**：工具内有限轮询（最多 30 次 × 10 秒）→ 超时未决则把 execution ARN 移交给调用方 → 另设独立的状态查询工具凭 ARN 二次查询。专门解决"邮件审批远超单次工具调用窗口"的问题。

## 审批疲劳：把人的注意力当调度对象

审批机制设计不好，最坏的结局不是慢，而是人不再细看就点批准。围绕这一点，素材收集到几组互补的证据：

- [HiL-Bench](https://arxiv.org/abs/2604.09408) 向良定义任务注入 3–5 个现实阻塞物并提供 `ask_human()` 工具：顶级模型在全信息时约 90% pass@3，有阻塞物时显著下降——**模型该"问人"时普遍选择硬做**。"何时该升级给人"本身是可测量、需要专门设计的能力。
- Anthropic 对数百万真实 Claude Code 交互的[实测](https://www.anthropic.com/news/measuring-agent-autonomy)显示：新用户约 20% 的操作自动放行（逐动作审批），而 750+ 会话的成熟用户达到 40%——成熟用法是从逐动作审批转向"只干预"式监督。
- Martin Fowler 在 [Humans and Agents in Software Engineering Loops](https://martinfowler.com/articles/exploring-gen-ai/humans-and-agents.html) 中把人的参与分为三种姿态：在循环外、循环内、循环上。其主张是只有 "humans on the loop"——维护 harness、设计验证与抽查，而非逐条复核输出——才跟得上 agent 的吞吐。
- [LangChain](https://blog.langchain.com/human-judgment-in-the-agent-improvement-loop/) 进一步指出：人工输入不只在执行时当审批门，更是持续改进 prompt、工具、记忆与 evaluator 的监督数据。
- agent-chief 项目把这套思路做成了产品形态：本地优先的注意力编排层，用三级 worthiness 引擎决定一件事该打断人、派给 agent、还是沉淀为记忆。

把这些放在一起，本章的标题判断就成立了：HITL 的设计目标是**把人放在回路里，而不被回路淹没**——审批面从"门"演化为"反馈机制"，人的每次介入都应当同时是安全闸门和改进信号。

## 本章小结

本章收敛了 agent 系统的"上层建筑"。编排侧：确定性结构层（版本化、可 diff 的 YAML/DSL/DAG）加基础设施级隔离（容器、worktree、git 事务语义），比一个聪明的协调 agent 更可靠——Parallel Claudes 与 Managed Agents 分别给出了无中心与中心化两条路线的工程标本，而三组件解耦把可恢复性、可诊断性与安全边界一并解决。控制侧：审批正从二值开关演进为非二值修正管道与结构化澄清，审批疲劳的解法是把信任持久化、把人的注意力当稀缺资源调度，走向 "humans on the loop"。两条线索共享同一个底层判断：agent 系统的可靠性上限，取决于反馈回路的带宽与控制面的粒度，而不是模型的聪明程度。下一章讨论如何用评测与验证闭环，把这种可靠性变成可度量的工程事实。

下一章：[[ch07-evals-and-verification|评测与验证闭环]]
