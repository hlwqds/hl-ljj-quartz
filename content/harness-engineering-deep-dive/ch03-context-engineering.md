---
title: "Agent Harness 工程化（三）：上下文工程"
date: 2026-10-21 00:30:00
description: "上下文投递的取舍：压缩的价值与代价、停止压缩的条件与注意力预算管理"
tags: [harness, ai-agents, context-engineering, llm]
---

# Agent Harness 工程化（三）：上下文工程

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 3 篇
> 上一章：[[ch02-agent-loop-and-planning|智能体循环与任务规划]] · 下一章：[[ch04-tools-and-mcp|工具接口与 Skills/MCP]]

## 先给结论

上下文工程要回答两个问题：**该进窗口什么（投递），满了怎么办（压缩）**。综合本系列
研读的两篇锚点文献——Anthropic 的 Effective Context Engineering 与 louisbouchard.ai
的 Why We Stopped Compacting——可以归纳出四条：

- **上下文是稀缺资源，要按预算管理**。token 不是越多越好：每个新 token 都在消耗模型
  的"注意力预算"，边际收益递减。设计目标是"完整勾勒期望行为的最小信息集"。
- **投递侧优先于压缩侧**。把上下文压力当成导航与检索问题来解，先不让垃圾进窗口，
  比满了再压缩更有效。
- **压缩有真实收益，也有两笔看不见的账**：有损重写会丢掉关键信息（初始指令、中间
  决策、风格规则）；在 prompt caching 普及后，改写缓存前缀还会触发全价重算。
- **"停止压缩"不是口号，而是一组条件成立时的结论**：缓存便宜、记忆质量敏感、窗口
  未到硬限时，全量保留加确定性 cap 反而更便宜也更准。两派真正共享的是同一句方法论：
  先命名真实约束，再选手段。

来源：

- [Effective Context Engineering for AI Agents（Anthropic）](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [Context Engineering in 2026: Why We Stopped Compacting Our Agent's Context（louisbouchard.ai）](https://www.louisbouchard.ai/context-engineering-2026/)

## 上下文是一种注意力预算

[Anthropic 的这篇文章](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
把上下文工程定位为提示工程的演进：核心问题从"怎么把指令写对"变成"什么样的上下文
配置最可能产生期望行为"，而且策展不是一次性动作，是 agent 每一轮推理前都要重复的
循环。

"上下文是有限资源"有架构层的依据。needle-in-a-haystack 类基准揭示的 context rot
现象是：token 越多，模型对上下文的召回精度越低。文章将其归因于 transformer 的全对
全注意力（n² 对关系）、训练分布以短序列为主、位置编码插值牺牲位置理解。关键的定性
是：**这是性能梯度而非悬崖**——每个新 token 都在消耗"注意力预算"，边际收益递减。
[OpenAI 的 Harness Engineering](https://openai.com/index/harness-engineering/) 从
另一侧给出同构判断：上下文的形状直接决定 agent 行为。

落到设计上，有三条可操作的准则：

- 系统提示要写在"正确海拔"（right altitude）：一端是把脆弱的 if-else 逻辑硬编码进
  提示，另一端是空泛的高层指导，中间找 Goldilocks 区；追求"完整勾勒期望行为的
  最小信息集"——minimal 不等于 short。
- 方法论是实验性的：先用最强模型跑最小提示，按实测失败模式逐步补指令与示例。
  Claude Code 作者 Boris Cherny 在 YC Startup School 的
  [分享](https://www.ycombinator.com/library/UN-boris-cherny-building-claude-code)
  给出了更激进的版本：删掉约 80% 系统提示而无 eval 回退——全删，只加回修复重复失败
  的行，每次模型发版重做。
- 工具集臃肿是工具侧最常见的失败模式：覆盖面过宽或职责重叠。原文的判据很直白——
  "如果人类工程师都无法确定该用哪个工具，就不能指望 AI 做得更好"。

## 投递侧：先决定什么进窗口

把这一主题下各家实践概括成一句话：**投递侧优先于压缩侧**。具体分两路。

第一路是 just-in-time 检索。Anthropic 主张：与其在推理前预处理全部数据，不如让
agent 持有轻量标识符（文件路径、查询、链接），运行时按需加载；文件层级、命名、
时间戳这类元数据本身就是行为信号。Claude Code 是混合范式的实例：CLAUDE.md 无脑
前置注入，配合 glob/grep 运行时导航。作者同时承认代价：运行时探索比预取慢，所以
建议"do the simplest thing that works"。

第二路是把拦截做在进窗口之前。生态里几个代表性实现：

- [Token Savior](https://github.com/Mibayy/token-savior) 按符号（函数/类/调用图）
  索引代码库，让 agent 用指针导航而非整读文件，作者报告省 77% token、76% 壁钟时间。
- [headroom](https://github.com/chopratejas/headroom) 在工具输出/日志/文件/RAG 块
  进入窗口前压缩，宣称省 60-95% active token 而答案不变，以库、代理、MCP 三种形态
  即插即用。
- Graft 把上下文压力定义为 "navigation problem, not just a compression problem"；
  A-RAG 则把检索改成 agent 循环内的工具拉取。

两条路方向一致：把"要不要进窗口"的判断，从 harness 的固定策略变成 agent 可自主
调用的导航能力。先不投垃圾，比事后压缩便宜。这也解释了为什么投递与压缩总被并在
一个主题下讨论：OpenAI 与 Anthropic 都把系统提示、工具定义、MCP 与消息历史当作
一份需要统一管理的上下文状态，"该进窗口什么"与"满了怎么办"，是同一份预算上的
两道闸门。

## 压缩：收益与两笔看不见的账

### 收益

Compaction 的标准形态是：接近窗口上限时，把旧历史摘要折叠。
[Claude API 官方文档](https://platform.claude.com/docs/en/build-with-claude/compaction)
在 100 轮网页搜索评测中报告省 84% token。在 Anthropic 的长程任务工具箱里，它与
结构化笔记、子代理架构并列为三板斧之一，调优原则是**先最大化召回、再提精度**，
最安全的轻量形式是只清除历史深处的工具原始结果、不动对话主干。要认清它解决的是
"还能继续跑"的问题，并不承诺"记得更准"。

值得注意的是业界的收敛。[Arize 对比](https://arize.com/blog/context-management-in-agent-harnesses/)
Pi、OpenClaw、Claude Code、Letta 四家 harness，发现独立实现殊途同归：读上限分页、
阈值触发压缩、超大结果落盘、子代理隔离。本系列读者对其中一家应该不陌生——
[[pi-agent-deep-dive|Pi Agent 深度探索]] 系列介绍过 Pi 在上下文接近上限时执行
Compaction 的设计，正是这套收敛模式中的一员。

### 代价之一：有损重写

[okhlopkov 对 Claude Code 自动压缩的拆解](https://okhlopkov.com/claude-code-compaction-explained/)
给出了存活清单：当前任务、近期错误、文件名倾向于存活；初始指令、中间决策、风格
规则倾向于丢失。结论是一条硬规则：**关键规则绝不能指望压缩幸存，要放进系统提示**
（CLAUDE.md），别赌压缩。

[LangChain](https://blog.langchain.com/autonomous-context-compression/) 指出另一种
失败模式：到限被动压缩会把 agent 打断在子任务中途，毁掉在途推理。他们的对策是把
压缩从固定阈值触发改成 agent 用专门工具自主择机触发。

### 代价之二：缓存失效

Prompt caching 的价值在于跨请求复用系统提示、工具定义与长文档的前缀，被视为
harness 层最有效的成本杠杆之一
（参考 [Claude 官方文档](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)）。
但压缩恰好作用在缓存最敏感的位置——改写历史就是改写缓存前缀，后续请求全部全价
重算。这笔账在 caching 普及之后变得足够大，大到有团队据此反转了压缩默认。

## 为什么有团队停止压缩

### 一组反转直觉的对照实验

louisbouchard.ai 的
[Context Engineering in 2026](https://www.louisbouchard.ai/context-engineering-2026/)
是一份带完整原文的生产对照实验报告：660 轮 + 植入事实探针，对比"全量保留"与
"生产压缩 preset"。作者报告，在 11-13 轮会话、Gemini 3.5 Flash 的实验条件下：

- full_history：$0.11/轮，92% 记忆召回；
- 压缩 preset：$0.24/轮，38% 记忆召回——少发 41% token，却贵一倍。

（注：该实验在不同转述中亦有 100% vs 58% 的数字口径，此处取注明实验条件的原文
数字。）即使把摘要调用本身做成缓存友好（摘要成本降 87%），总成本仍比"只做 cap +
全量保留"高 14%。文章引 Manus 的判断作为点题：**KV-cache 命中率是生产期 agent
最关键的单一指标**。

### 损伤跟随重写次数，而非上下文长度

实验里更本质的发现在损伤溯源：性能劣化跟随"有损重写的次数"，而不是在线上下文的
大小。0 次压缩事件的 run 全部通过记忆探针；5-6 次的只答对三分之一。每次压缩约
90:1 且在上一次摘要之上再压，损失是复利的。最扎眼的对照：压缩 preset 在 95k-195k
上下文下探针失败，full_history 在 363k-879k 下零失误——大上下文不是问题，重写
才是。顺带澄清一个流传甚广的结论：早年"200k 后崩塌"的说法，是该文作者自己
300 token 回答上限截断造成的伪影。

### 测量方法本身是个坑

> [!warning] 整体质量分对"静默遗忘"结构性失明
> 盲评 LLM judge 给压缩 preset 打出 97-99% 的"好回答"，而同批记忆召回只有 58%。
> 想看见这类失败，必须植入可独立判真伪的事实探针；该文的 ground truth 由真实
> 员工回复蒸馏成原子化可二判要点，judge 与人工标注一致率 98%。

### 划算的压缩是最便宜的那层

停止压缩不等于放任上下文膨胀。该文真正推荐的是无模型调用的**确定性 cap**：对工具
输出做稳定尺寸封顶，原则是 shrink the prefix, don't rewrite it。DeepSeek 上
414 轮/臂 × 3 试验的对照：单轮成本 $0.189 降到 $0.117（-38%），15 条配对轨迹赢
14 条，缓存命中率与记忆探针完全不变。

还有一个常被忽视的事实支撑这个选择：撑爆输入的是旧工具输出与检索载荷，聊天历史
只是零头。所以在工具输出这一层做 cap，就已经拿走了膨胀的大头。

## 两条路线的适用边界

louisbouchard 一文给出的决策框架是"先命名真实约束，再选手段"：

```text
窗口装不下 -> 检索而非塞入（本地 RAG 100% 正确 vs 整篇 stuffing 溢出）
账单撑不住 -> 先查缓存量价（缓存输入价低于约 $0.55/M token 时全量保留赢）
质量在腐化 -> 先定位再动手（用探针定位到压缩，再谈压缩策略）
```

文中补充：换更便宜的缓存模型是最大的成本杠杆。他们最终的生产配置是
DeepSeek V4 Flash + 混合检索 + 全量保留 + 稳定 cap，摘要触发线从 30k 挪到
800k——作者诚实标注：这是没被压到的护栏，不是调优参数。文章还附带几个负结果，
反而增加可信度：GraphRAG 在 41 个真实案例上输给普通混合检索（引用正确率与召回
打平、MRR 更低、输入 token +61%、单轮成本 +44%），故弃用；知识库 shell
（rg/grep/sed）在 89% 轮次被使用，但关掉后 grounding 几乎不动；BM25 全程 100%
命中，关键词检索通路必须保留。

Anthropic 一侧给的同样是选型而非站队。长程任务三板斧的选型建议：多轮往返选压缩、
里程碑式迭代选结构化笔记（NOTES.md/todo 式外部持久化）、可并行的调研选多代理——
子代理用数万 token 深潜，只回传 1-2k token 的蒸馏摘要。[LangChain 对子代理上下文
模式的讨论](https://www.langchain.com/blog/organizing-context-in-a-multi-agent-harness)
可以看作同一层的细化：isolated（全新启动，做上下文防火墙）vs forked（继承监督者
对话且保缓存）；决策规则是 fork 继续在途调查的 worker，isolate 必须独立判断的
verifier。

把两派放在一起，适用边界大致是：

- 有缓存红利、长程记忆敏感、窗口未到硬限：全量保留 + 确定性 cap——louisbouchard
  阵营的主场；
- 窗口硬限在即、多轮往返、可容忍有损：压缩，且把关键规则前置到系统提示——
  Anthropic/Claude Code 阵营的主场；
- 里程碑式迭代：结构化笔记；可并行调研：子代理隔离。

对 harness 实现者的启示是：与其押注某一路线，不如把两类开关都做出来——压缩的
触发条件、cap 的封顶尺寸、缓存断点的位置都暴露成配置，让评测数据决定默认值。

而无论哪一派，投递侧纪律是共享的底层：读上限分页、超大结果落盘、工具输出封顶——
确定性瘦身永远先于有损手段。对 Pi 运行效率的量化研究（SoL-Pi）则从另一头提醒：
这些效率机制本身可搜索、可度量（作者报告每小时节省 $8.75-13.50），取舍不该靠
信仰，该靠评测。

顺带说明：OpenAI 开发者博客另有一篇 Shell + Skills + Compaction 的长程技巧，主题
更偏技能组织与工具接口，本文不展开，留到下一章。

## 本章小结

上下文工程的预算观是本章的底座：token 是逐份折损的注意力预算，投递侧（什么进窗口）
永远优先于压缩侧（满了怎么办）。压缩有真实收益，但代价有两笔——有损重写丢关键
信息、改写缓存前缀触发全价重算；在 caching 普及后，后者大到足以让部分团队反转为
全量保留加确定性 cap。两派并非对立，真正可迁移的是同一套方法论：先命名真实约束
（窗口、账单、质量），用事实探针而非整体质量分来测量，确定性瘦身先于有损重写。

下一章：[[ch04-tools-and-mcp|工具接口与 Skills/MCP]]
