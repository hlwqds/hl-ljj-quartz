---
title: "Agent Harness 工程化（九）：可观测性、调试与生产运维"
date: 2026-10-21 01:30:00
description: "分布式追踪、失败归因与 SRE 式可靠性证明：agent 生产化的观测与运维面"
tags: [harness, ai-agents, observability, sre]
---

# Agent Harness 工程化（九）：可观测性、调试与生产运维

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 9 篇
> 上一章：[[ch08-sandbox-and-permissions|沙箱、权限与审批]] · 下一章：[[ch10-templates-and-landing-path|模板四件套与落地路径]]

## 先给结论

前几章讨论的循环设计、上下文管理、沙箱与权限，解决的都是"让 agent 把任务做对"；这一章换一个视角：**当 agent 真的跑起来了，你怎么知道它哪里出了问题，又怎么证明它配得上生产流量**。围绕这个视角，本篇的四个核心判断是：

1. **agentic workflow 本质是一个分布式系统**。追踪应挂在 OpenTelemetry 标准上而不是自造日志格式；trace 数据应该是可 SQL 查询的基础设施，而非 dashboard 摆设。
2. **很多"agent 失败"该修的是 harness 而不是换模型**。faros.ai 对约 4000 个编码 agent 失败的归因分析（自述数据）发现，最大失败簇是 harness 自己写出来的指令冲突，而仓库难度对结果的影响约为模型选择的两倍。
3. **资源管控必须下探到 OS 层，并以工具调用为控制粒度**。AgentCgroup 论文实测（自述数据）OS 层执行占端到端延迟 55–60%（v3 修订口径），内存才是并发的真正瓶颈。
4. **上线前要像 SRE 那样证明可靠性**：用 pass^k（全部试验通过）而非 pass@k（成一次就算过）做上线门禁，回测数据集按黄金路径、边界、对抗、生产事故回归配比。

下面分四节展开。

## 追踪：把 agentic workflow 当分布式系统看

### 为什么这是分布式系统问题

一次典型的 agentic 请求会穿过 integration 层、routing agent、若干 specialist agent、MCP server 与外部系统——这与微服务调用链没有本质区别。[Red Hat 的实践指南](https://developers.redhat.com/articles/2026/04/06/distributed-tracing-agentic-workflows-opentelemetry)直接把微服务时代的答案搬了过来：全链路统一 W3C TraceContext，carrier 就是 HTTP headers，包括异步 CloudEvent 边界，trace ID 跨所有服务保持不变。

这篇指南里最值钱的一条经验是：**框架边界是断链高发区**。作者明确指出，span context 不会从 Llama Stack server 自动传播到 MCP server（0.2.x/0.3.x 均如此），必须在工具调用时手动注入父上下文。对自建 agent 栈的直接启示是：不要假设推理网关或 agent 框架已替你打通传播，接好 Jaeger 之后第一件事，是检查工具调用是否还挂在根 trace 上。

插桩策略同样沿用分布式系统惯例：HTTP 出入口用现成的自动插桩库，框架没覆盖的地方（如 MCP server）手写 span 装饰器；span 命名层级化、自定义属性遵循语义约定、敏感值不进属性、每个操作记录 status 与异常。

trace 还有量化价值：文中示例一次约 3.75s 的请求里，LLM 推理占 3.54s，MCP 工具调用只有约 12ms——时间到底花在哪，span 瀑布图一目了然。

### 标准与生态

这批资料里的工具选择高度一致地指向 OpenTelemetry：[OpenLLMetry](https://github.com/traceloop/openllmetry) 把现有 OTEL 生态接进 harness；[OTel GenAI 语义约定](https://opentelemetry.io/docs/specs/semconv/gen-ai/)给出 `gen_ai.system` 等标准属性名，让 harness trace 在任意 OTEL 后端之间可移植。可移植性与避免厂商锁定，被放在厂商专属特性之前。

[Temporal × Braintrust 集成](https://temporal.io/blog/building-observable-ai-agents-temporal-now-integrates-with-braintrust)则展示了另一个可复用的模式：durable execution 与 LLM tracing 合一。每个 Workflow/Activity 成为 Braintrust 的一个 span，OpenAI SDK 设 `max_retries=0` 把重试权完全让渡给 Temporal——"20 次搜索成功后 synthesis 失败"只重试失败那一步，30 分钟的 deep research 工作流在第 29 分钟崩溃也不必从零开始。排障时两侧视图正交：Braintrust 回答"输出为什么差"（模型行为），Temporal 回答"执行为什么断"（Event History 与恢复路径）。

### trace 是可查询的基础设施

这批资料的另一个共识：观测数据要能被查询和复用，而不是画在 dashboard 上。Logfire 让全部 trace SQL 可查，coding agent 可以经 MCP 直接查询生产观测数据；[BigQuery Agent Analytics](https://cloud.google.com/blog/products/data-analytics/introducing-bigquery-agent-analytics/) 主张把评估器、回归测试和对话式调试直接建在生产 trace 上；Brainstore 则做全量 trace 检索免采样。

部署偏好上，Phoenix、Langfuse、Helicone 等自托管/本地优先方案占据了清单主位。还有一条反向提醒值得单列：[METR 对 Anthropic 内部 agent 监控系统的三周红队审计](https://metr.org/blog/2026-03-25-red-teaming-anthropic-agent-monitoring/)发现了多个新型漏洞——把监控系统当安全层信任之前，先对它本身做压力测试。

## 调试：从"看日志猜"到证据驱动的失败归因

### 可见性是被 harness 自己吃掉的

调试 agent 的第一个障碍恰恰来自 harness：claude-devtools 的立足点就是 Claude Code 默认 UI"有意折叠"了工具细节与思考步骤，需要从本地日志重建会话内部（按轮次 token 归因、子代理执行树、工具调用 diff）。另一条线索是 [/doctor](https://code.claude.com/docs/en/commands) 这类体检命令把配置漂移——重复的 CLAUDE.md、闲置的 skills/MCP/插件——当作调试目标，而不是盯着模型输出。

第二个障碍是规模：深度 agent 一跑数分钟、跨几十上百步，prompt 本身可能上千行，trace 数据量已超出人工排查能力。[LangChain 的做法](https://blog.langchain.com/debugging-deep-agents-with-langsmith/)是给 trace 分析再套一层 AI：应用内助手 Polly 用自然语言回答"agent 犯了什么错"；开源 CLI langsmith-fetch 把 trace 数据按 JSON 管道输送给编码 agent，形成"可观测后端 + 拉取 CLI + 本地编码 agent 做根因分析"的三段架构——用 agent 调试 agent。harness 的分层设计直接决定可观测的上限：[[pi-agent-deep-dive|Pi Agent 深度探索]] 系列拆解的 Pi，就是把可分支、可恢复的会话作为一等能力保存的 harness——留痕做得越完整，事后归因的起点越高。

### "不是模型的错"：faros.ai 的实证归因

调试这一主题里证据最扎实的，是 [faros.ai 的《Why AI Coding Agents Actually Fail (It's Not the Model)》](https://www.faros.ai/blog/why-do-ai-coding-agents-fail)。研究设计是：同一 harness 下跑 6 个模型 × 100 个 SWE-bench Pro 任务，产出约 4000 条逐条带理由的失败记录。作者自己也诚实声明了局限：LLM judge 有约 13% 的噪声底、单一 harness 单次运行——即这是作者自述的实证，未经第三方复核。其核心论据有三条：

**第一，最大失败簇是 harness 自己造成的指令冲突。** 排名第一的失败主题（247 条）来自 prompt 里那句防作弊禁令 "DO NOT MODIFY: Tests, configuration files"——但大量评分项又要求新增测试或更新断言，agent 过度字面执行，两头不是人。关键证据是：这是最弱模型与最强模型共同的头号失败主题，换更强的模型解决不了措辞问题。修复只需要一句话：把"不许削弱现有测试"与"不许碰任何长得像测试的文件"区分开——作者称这句修改的收益比某些模型升级更值钱。

**第二，第二大簇是变更卫生，而非能力缺陷。** 141 条失败属于"像赶时间的粗心工程师而非愚蠢的工程师"：调试脚本、临时文件、无关编辑被反射性的 `git add -A` 卷进 diff。对应的三条 harness 改造都不需要换模型：提交前强制 `git status` 审查、用结构化编辑替代 sed 类正则替换、对最终 diff 做一次自检。

**第三，仓库难度的影响约为模型选择的两倍。** 最好与最差模型的总差距是 22.7 个百分点，最易与最难仓库的差距是 42.1 个百分点。升级模型消除的是个性怪癖而非公共难题：297 条要求被全部 6 个模型共同失败，而最强模型的独有失败只占 2.2%。

作者由此给出的方法论排序是：先按失败原因聚类，先问"是否有任何模型能通过"，最后才花钱做模型对比。这与循环层面的调优互补——循环决定 agent 怎么跑，归因告诉你它为什么没跑成。

学术侧也在把失败归因系统化：AgentTrace 用因果图（而非 LLM 推理）区分根因与下游症状传播，论文自述 0.12 秒定位、比 LLM 分析快 69 倍；Microsoft Research 的 AgentRx 从工具 schema 综合约束做失败定位。这些数字均为论文/团队自述，但方向一致：回答"为什么失败"比报告"哪里失败"更可复用。

## 运维：资源管控要下探到 OS 层

### 规模化的缺口在运营能力

两份行业调查数据勾勒出当前缺口（均为调查自述数据）：G2000 中 72% 已让 agent 超出实验阶段，但仅 14% 完成组织级规模化；[LangChain 对 1300+ 从业者的调查](https://www.langchain.com/state-of-agent-engineering)显示 89% 已上可观测性，只有 52% 在跑评测。监控有了、评测缺位、事故响应不成体系——当前的短板是运营能力，不是模型能力。

### AgentCgroup：以工具调用为粒度的 OS 控制平面

这一主题的核心一手研究是 [AgentCgroup](https://arxiv.org/abs/2602.09345)（arXiv 2602.09345）。测量基于 144 个 SWE-rebench 任务、Podman 容器、1 Hz 采样（以下均为论文自述数据）：

- **OS 层执行占端到端延迟的大头**。注意版本口径：论文 v1 正文写 56–74%，当前 v3 摘要已修订为 55–60%，引用宜采用 v3 口径；LLM 推理仅占 26–44%。还要留意：深读材料未标注该时间分解属于哪个版本口径，两组数字之间不可直接换算对表。
- **并发瓶颈是内存而非 CPU**。平均 CPU 只用到单核的 13.2%/7.6%，但内存呈两层结构：约 185 MB 的稳定框架基线，加上工具调用驱动的 500 MB–2 GB 突发（峰均比 15.4×）。按峰值静态预留浪费一个数量级，按均值配额则必然 OOM。
- **资源需求本质不可预测**。跨任务峰值内存相差 20×，同一任务三次运行时长差 1.8× 且解法完全不同，对话轮数对峰值内存的预测力 r<0.11；重试还会放大压力：85–97% 的任务含重试循环，并伴随渐进内存滞留。

设计上，论文把"意图"（工具调用边界）做成 OS 控制平面：层级 cgroup v2 树让每个工具调用成为 workload 节点下的子 cgroup；eBPF 在内核内执行 CPU 调度与内存限流，微秒级反应；按 throttle→freeze→kill 分级降级，只因持续无进展才终止。

需要如实带出的限定：实测效果是 trace-replay 量级的——内存总配额 1100 MB 对需求约 1233 MB 时，基线"杀进程"策略存活率 66%，BPF 分级限流达到 100%，HIGH 档开销 +2.8%；论文自陈局限包括单一框架、单一 benchmark、未跑真实在线多租户。这是方向性证据，不是生产结论。对多租户沙箱工程的启示倒是清楚的：容量规划按内存而非 CPU 计；隔离与 QoS 的正确粒度是工具调用而非容器/会话；"意图"也可以由 harness 侧注入工具调用起止事件，不必依赖内核侧启发式识别。

### 当 agent 吞吐重塑基建

这个领域还出现了两条"agent 负载改写基础设施"的一手案例：[Anthropic 的合并量](https://www.anthropic.com/engineering/redesigning-source-control)从每日约 2,500 涨到 30,000+，Git 被压垮后自研 Scion VCS；[Stripe 的无人值守 agent 舰队](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)（周发 1300+ PR）则给出对称验证——为人类开发者做的基建投资（预热 devbox、集中式工具服务）对 agent 同样产生红利。成本侧，FinOps 实践把护栏做在[网关层](https://www.infoworld.com/article/4138748/finops-for-agents-loop-limits-tool-call-caps-and-the-new-unit-economics-of-agentic-saas.html)（循环上限、工具调用上限、单次 token 预算、墙钟超时、按租户预算），[self-heal 模式](https://blog.langchain.com/production-agents-self-heal/)则把评测与可观测性接成"检测回归→归因部署→自动开修复 PR"的闭环。

## 上线门禁：SRE 式回测

最后一环是上线前的可靠性证明。[DrDroid 的实践指南](https://drdroid.io/blog/backtesting-ai-agents-how-sre-teams-prove-reliability-before-production)把分布式系统的测试心智整个搬了过来。

**判据用 pass^k 而非 pass@k。** pass@k 是多次试验里成一次就算过；pass^k 要求全部通过。指南引用的量级证据（转引 Codebridge 调查）：单次成功率 60% 的场景，重跑 10+ 次后完全一致性只剩 25%。落地操作是每个黄金场景跑 20 次 Monte Carlo 试验，成功率低于 95% 或 token 用量波动超过 30% 即告警——本质是把测试工程的 flaky 治理搬上 agent 上线门禁。

**五个维度各带阈值。** 指南给出的可照抄配置（源自 Codebridge 框架，属实践建议而非已验证结论）：Consistency 要求 20 次运行成功率 ≥95%；Robustness 要求扰动下 ≥90%；Predictability 要求 agent 输出置信度且 Brier 分数 <0.2，低置信动作转人工审批；Safety 要求严重违规为 0（测试里埋负约束，agent 一碰就 build 失败）；Infrastructure & Cost 要求单次成本方差 <30%。CI 门禁取三条硬条件：成功率 ≥95%、安全违规 0、成本方差 <30%。

**数据集按 20/30/20/30 配比。** 20% 黄金路径、30% 边界用例、20% 对抗样本（prompt 注入、恶意工具输出、冲突的人类指令）、30% 生产事故回归。最有价值的数据源是 incident replay：用告警、日志和部署时间线重建历史故障让 agent 现场重解，回测套件随时间沉淀为运维知识的活档案。

**评估架构复用测试金字塔。** 自下而上：单元测试（工具 schema、prompt 模板、guardrail 逻辑，毫秒级确定性）→ 集成测试 → 仿真测试（回放告警流 + mock 工具 + 注入噪声）→ 回测（真实生产事件重放，pass^k 在这一层才真正发挥作用）。判定者分三层：确定性代码检查客观结果，LLM-as-a-judge 评主观项（指南转引 AaaJ 框架：与人类一致率约 90%、评审成本降 97%），人工审批兜底不可逆动作——三层共用同一份 reasoning trace 证据。

vendor 语境也要如实声明：这篇出自 DrDroid 官方博客，部分论述围绕自家产品叙事，上述阈值宜当设计起点，而非照抄的真理。

## 主要来源

- [Distributed Tracing for Agentic Workflows with OpenTelemetry（Red Hat）](https://developers.redhat.com/articles/2026/04/06/distributed-tracing-agentic-workflows-opentelemetry)
- [Building Observable AI Agents: Temporal Now Integrates with Braintrust（Temporal）](https://temporal.io/blog/building-observable-ai-agents-temporal-now-integrates-with-braintrust)
- [Why AI Coding Agents Actually Fail (It's Not the Model)（faros.ai）](https://www.faros.ai/blog/why-do-ai-coding-agents-fail)
- [Debugging Deep Agents with LangSmith（LangChain）](https://blog.langchain.com/debugging-deep-agents-with-langsmith/)
- [AgentCgroup: Understanding and Controlling OS Resources of AI Agents（arXiv 2602.09345）](https://arxiv.org/abs/2602.09345)
- [Backtesting AI Agents: How SRE Teams Prove Reliability Before Production（DrDroid）](https://drdroid.io/blog/backtesting-ai-agents-how-sre-teams-prove-reliability-before-production)
- [Red-Teaming Anthropic's Internal Agent Monitoring Systems（METR）](https://metr.org/blog/2026-03-25-red-teaming-anthropic-agent-monitoring/)

## 本章小结

这一章把视角从"让 agent 做对任务"转向"让组织敢把任务交给 agent"。追踪一节的核心是标准化与可查询性：OpenTelemetry 加上 SQL 可查的 trace 基础设施，让 agentic workflow 可以按分布式系统的成熟方法排障。调试一节的证据指向 harness 自身：指令措辞与变更卫生造成的失败，往往比模型能力差距更值得优先修复。运维两节给出工程化的管控与证明手段——以工具调用为粒度的 OS 层资源控制，以及 pass^k 加分层阈值的 SRE 式上线门禁。观测、归因、管控、证明四件事串起来，就是 agent 从演示走向生产的最后一公里。

下一章：[[ch10-templates-and-landing-path|模板四件套与落地路径]]
