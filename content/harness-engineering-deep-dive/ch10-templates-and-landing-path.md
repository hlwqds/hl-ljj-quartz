---
title: "Agent Harness 工程化（十）：模板四件套与落地路径"
date: 2026-10-21 01:40:00
description: "可直接复制的四件套模板、六条 AGENTS.md 写作纪律与分梯队落地路径"
tags: [harness, ai-agents, templates, best-practices]
---

# Agent Harness 工程化（十）：模板四件套与落地路径

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 10 篇（完结篇）
> 上一章：[[ch09-observability-and-operations|可观测性、调试与生产运维]]

## 先给结论

落地 harness 不需要从零发明。awesome-harness-engineering 仓库的 `templates/` 目录提供
四个可直接复制的模板文件——AGENTS.md、PLAN.md、IMPLEMENT.md、HARNESS_CHECKLIST.md，
合计不到 7 KB，README 导览表对它们的定位只有一句："Copy and adapt"。本章是全系列的
落地篇：先拆解四件套各自的用途与关键机制，再给出写 AGENTS.md 的六条实证纪律，然后
看长程任务的最小 harness 与值得通读的参考实现，最后按 T0/T1/T2 梯队给出落地路径，
并在文末附一张"按问题查章节"速查表。

四件套背后的理念可以压缩成三句话：

- **"完成"是可执行的验证门，不是 agent 的自我评价**——做完与否绑定在一条命令的退出码上；
- **长生命周期状态住在文件里，不住在提示词或对话里**——上下文会被压缩丢失，文件才能跨会话审计；
- **脚手架按"可拆除"设计**——每个组件都要写下"模型进化到什么程度，它就可以退役"。

## 模板四件套：可复制的起点

四件套的分工是：AGENTS.md 是仓库级持久层，PLAN.md 与 IMPLEMENT.md 是任务级流程件，
HARNESS_CHECKLIST.md 是 harness 变更上线前的评审门禁。前一件常驻仓库根，后三件随任务
与版本流动。

### AGENTS.md：仓库根的持久层

模板实测 80 行 / 2121 字节，是四件套中唯一"放仓库根、任何任务开始前先读"的文件。
骨架共 7 节：Project overview、Repository structure、Conventions、Tool permissions、
Known constraints、Verification gates、Contact/escalation。模板本身多为通用占位散文，
真正的价值在三个结构设计：

- **三档权限模型**：Allowed / Restricted (ask before proceeding) / Not allowed。关键在
  Allowed 层按"具体路径 + 具体命令"做白名单（`src/`、`tests/`、test、lint），而非
  "小心操作"式的软约束。模板注释里明言方法论："agents perform better with clear
  boundaries than vague restrictions"。Not allowed 层的措辞是 "without explicit
  instruction"——硬地板本身内建了人类明确指令的逃生门。
- **验证门是完成契约而非建议**：四个 checkbox——测试通过、linter 通过、无新增警告、
  改动文件在许可范围内。两个工程细节值得注意："No new warnings" 是差分条件而非绝对
  条件，agent 因此可以在带存量警告的代码库里工作；第 4 项把权限节闭环进"完成"的
  定义——越权改动不算做完。
- **受阻升级契约**：当推进需要超出许可范围的决策时，agent 应停下并清晰描述阻塞点，
  "rather than making an assumption"。它针对的失败模式是 agent 为推进而静默越权。

另有 Known constraints 一节是全模板唯一要求写"反直觉事实"的地方，注释直接给句式：
"The monorepo build tool is X, not Y"、"Tests require a running Docker daemon"——捕获
会让首次进入的 agent 踩坑的部落知识，是单位信息密度最高的定制点。

### PLAN.md 与 IMPLEMENT.md：任务级计划与日志

[PLAN.md](https://github.com/ai-boost/awesome-harness-engineering/blob/main/templates/PLAN.md)
（1353 字节）把"计划"从愿望清单变成执行合同：每个里程碑自带 `verify:` 命令，且验证门
未过不得勾选；配套 in/out-of-scope 边界、开放问题与风险区。头部明确要求执行全程更新，
而非收尾补写。

[IMPLEMENT.md](https://github.com/ai-boost/awesome-harness-engineering/blob/main/templates/IMPLEMENT.md)
（1178 字节）定为 **append-only**：条目禁改旧记录，防止决策史被静默改写；每条按四段式
书写（What happened / Decision / Deviation / Next）；偏差汇总表带 "Plan updated?" 列，
强制把偏离回写进 PLAN.md，避免计划与实现悄悄分叉。

两件为什么要落在文件里？因为上下文会被压缩、会话会被切换，只有文件跨会话可审计。
这也是第 2 章讲"状态外化"、第 5 章讲"状态归仓"时反复出现的同一条原则——四件套把
它落成了可以直接拷贝的文件。

### HARNESS_CHECKLIST.md：上架前的评审门禁

模板实测 62 行 / 2357 字节，26 个条目全部用现在时、可判定的断言写成，刻意排除
"基本符合"这类模糊判定。执行语义写在开头：任一项 fail 即 blocker，skip 必须留下
书面豁免理由，没有第三种状态；末尾留 Reviewed 日期与 Reviewer 签字段闭环。它可以直接
当作 harness 上线前的 sign-off 仪式执行。

清单把 harness 审计分成六大子系统：Agent instructions (AGENTS.md)、Tool design、
Context delivery、Planning artifacts、Permissions & sandbox、Verification loop。值得
注意的一件事：整份清单里"模型"缺席——26 项审的全是你自己搭的脚手架，而非模型输出。
这与全系列的立场一致：先查 harness，再怪模型。

### 拆除条件表：四件套的哲学内核

清单结尾是一张三列空表：**Component / Exists because / Can be removed when**。定调
写在表前的引文里："Every harness component exists because the model can't do something
yet"。它强迫你逐组件写下"模型哪项能力进化到什么程度，这个组件就该拆"。

这张表把 harness 从"永久护城河"重新定价为**针对模型进步的技术债**：写不出拆除条件的
组件，等于承认自己永久存在；每次模型升级后重审一遍，就知道哪些脚手架该退役。这是
防止 harness 固化成永久复杂度的最简机制，也是整份清单理念的最浓缩落地。

### 组合用法

四件套的组合节奏是：AGENTS.md 常驻仓库根；每个非平凡任务开工先立 PLAN.md，执行中
随手写 IMPLEMENT.md；harness 变更上线前跑一遍 HARNESS_CHECKLIST 当 sign-off；每次
模型升级后重审拆除条件表。

## 写 AGENTS.md 的六条实证纪律

模板解决"往哪个骨架里填"，素材里散落的多项实证研究则回答"怎么填才有效"。综合成
六条纪律（每条注明出处，均为素材转述的第三方主张）：

1. **手写、极简、渐进披露**。ETH Zurich 对 138 份 agentfile 的研究显示：LLM 生成的
   指令文件反而有害（成本 +20%），人写的也只带来约 4% 的提升，目录/结构清单类内容
   无效。HumanLayer 自家的 AGENTS.md 控制在 60 行以内，细节靠渐进披露按需加载。
2. **只写普适指令**。每个仓库只放"对该仓库普适适用"的内容，一次性任务的注意事项
   不该占驻持久层。
3. **把反直觉事实写进 Known constraints**。用 "X, not Y"、"Tests require a running
   Docker daemon" 这类句式，捕获部落知识——这是新 agent 首次进入时最容易踩坑的部分。
4. **每条禁令与真实失败对表**。faros.ai 的失败聚类分析里，最大失败簇（247 条）就是
   harness 指令冲突："DO NOT MODIFY: Tests" 挡住了任务明确要求的加测试工作，且轻量
   模型与旗舰模型共同中招。修复只需要把 "don't weaken existing tests" 与 "don't touch
   anything test-shaped" 区分开——faros 作者称，这句措辞的收益比某些模型升级更值钱。
   没有对应真实失败的禁令，默认不该写。
5. **硬约束不写成散文**。对 481 份公开 CLAUDE.md 的统计显示，只有约 4% 的自然语言
   安全规则有对应的内建控制。安全意图应挪进 deny 规则、hooks、权限模式这类确定性
   执行点（第 8 章的权限求值链）；模板的 Verification gates 同理——把合规写成完成门，
   而非建议。
6. **知道加载机制再写**。以 OpenAI《Unrolling the Codex agent loop》的披露为例：Codex
   把 AGENTS.md 从 git 根到 cwd 逐层聚合，默认 32 KiB 上限，且内容会随对话进入
   prompt 前缀——改配置会影响缓存命中，配置变化应以追加消息表达，而不是频繁重写文件。

一句话总结：AGENTS.md 是"手写的、60 行以内的、每句都对得上真实失败的"文件；写不出
对应失败或验证门的句子，多半是噪音。

## 长程任务的最小 harness

四件套之外，素材里的两篇工程博客给出了更"重"的长程任务方案，两者可以互相印证。

**OpenAI 五件套**。出自《Run Long-Horizon Tasks with Codex》：
Prompt.md（冻结规格，带 "Done when" 完成检查）、plans.md（唯一事实源：里程碑 ×
Scope / Key files / Acceptance criteria / Verification commands，指导原则是
"Determinism over flash"）、implement.md（执行手册：不许中途停下提问、小步提交注明
里程碑、bug 四步法）、documentation.md（状态与决策日志）、AGENTS.md（环境约定）。
素材作者核验过：前四件真实存在于 OpenAI 实验仓库的 docs/ 目录下，不是修辞。与模板
四件套对照：PLAN.md ≈ plans.md，IMPLEMENT.md ≈ implement.md——两套工件是同一思想
的不同实例。

**Anthropic 变体**。出自《Effective Harnesses for Long-Running Agents》：初始化会话
不写业务代码，专职搭脚手架——init.sh 一键起服务、claude-progress.txt 工作日志、JSON
功能清单（每条含 category/description/steps/passes，agent 只许改 passes 字段；原文
强调 "It is unacceptable to remove or edit tests"）；编码会话固定开场协议：pwd →
git log → 清单 → init.sh → **基线端到端测试** → 开发。基线测试先行，是为了把"环境
本来就是坏的"与"agent 改坏的"区分开。

两个补充要点同样来自素材：

- **端到端验证要显式指定工具与方式**。Anthropic 的观察是：agent 缺省只写单元测试或
  curl 检查，常在功能实际不可用时照常报告完成；明确指示它用浏览器自动化 "as a human
  user would" 后，验证效果大幅提升。
- **选循环抽象先问"哪一环可以不经过我"**。Anthropic《Getting started with loops》的
  框架：turn-based 交出检查点、goal-based 交出停止条件、time-based 交出触发器、
  proactive 交出整个提示。goal 循环要用确定性停止条件（通过的测试数、Lighthouse ≥90）
  定义完成，别让模型自行判断"够好了"——这与第 2 章的循环设计、第 7 章的验证闭环
  一脉相承。

## 值得直接研读的参考实现

素材作者反复强调一个学习路径：**学 harness 的最短路径是读最小但完整的真实实现**，
而不是读概念综述。参考实现项目集里提名的项目都有一个共同特征——"一个下午能读完的
整个 harness"。如果想先看单个 harness 的源码级解剖，可以对照本站的
[[pi-agent-deep-dive|Pi Agent 深度探索]] 系列；本节则按素材的提名，给出横向书单。

### Skill Issue：先查 harness，再怪模型

[Skill Issue](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents)
被清单作者称为"最可操作的单页综述"（原文 the most actionable single-page synthesis），
逐项覆盖编码 agent 的全部 harness 配置点。核心论点：大多数 agent 失败是配置问题而非
模型局限，结尾原话："Before you blame the model, check the harness… The model is
probably fine. It's just a skill issue."。几个可直接落地的要点：

- **能用成熟 CLI 就别上 MCP server**：工具描述会全量注入系统提示，既是 token 成本也是
  注入面；文中案例把 Linear MCP server 换成一个 6 条命令的小 CLI，省下数千 token。
- **子代理是上下文防火墙，不是人格分工**：按 persona 划分子代理（"前端工程师"）实测
  失败，有效的是上下文隔离——父线程只见自己的 prompt 加子代理压缩后的结论；结果要
  强制带 `filepath:line` 或 URL 引用。
- **回压验证要"静默成功"**：hooks 把控制流从概率性提示词挪到确定性脚本；验证输出必须
  上下文高效——4000 行"全绿"输出反而诱发幻觉，正确姿势是成功零输出、只让错误浮出。
- **做减法的方法论**：真实失败后才加配置、迭代且舍得丢弃——作者扔掉的 hook 比留下的多。

### 御舆：一本逆向工程教科书

[御舆（Decoding the Agent Harness）](https://github.com/lintsinghua/claude-code-book)
被清单作者称为"最接近 harness engineering 教科书"的存在（原文 the closest thing to a
harness engineering textbook）：15 章逐层拆解 Claude Code 的 harness，每章讲设计决策
的 why。素材实测其规模约为 20 个 markdown 文件、157 个 mermaid 图块。几条最常被引用
的结论：

- 对话循环的正解是 AsyncGenerator + `while(true)`：yield 表达流式与背压，类型系统强制
  循环状态正确性；
- 上下文管理是一条按成本递增的四级压缩管线（Snip → MicroCompact → Collapse →
  AutoCompact），有效窗口要为压缩自身预留输出空间；
- 断路器有真实数据支撑：其推演引用的实测是 1,279 个会话出现 50 次以上连续压缩失败、
  每天浪费约 25 万次 API 调用——"阈值为 100 的断路器等于没有断路器"；
- 安全设计的一致哲学是 fail-closed：推测性权限分类器超时即回退人工确认，而非默认放行。

注意素材的如实说明：御舆是从可观测行为推演的架构分析而非源码泄露，具体常量会随版本
漂移，可靠的是结论层模式而非数字本身。

### 其余值得点名的实现

- [mini-coding-agent](https://github.com/rasbt/mini-coding-agent)：纯 Python 标准库、
  单文件实现 coding agent 六大核心组件，理解 agent loop 底层机制的最清晰起点；
  [smolagents](https://github.com/huggingface/smolagents) 约 1000 行核心代码，整个
  harness 一个下午能读完。
- [SmallCode](https://github.com/Doorman11991/smallcode)：为 8B–35B 本地小模型从零构建
  的终端编码 agent，素材引用的数据是 4B 激活参数拿到 87% 基准分——靠的全是 harness
  层补偿（两段式工具路由、宽容多格式解析器、patch-first 编辑、带中途驱逐的上下文预算
  引擎）。这是"harness 设计而非模型规模是可靠性约束条件"的最强案例。
- **元 harness 一线**（自动改进 harness 的外环优化）：
  [Meta-Harness](https://arxiv.org/abs/2603.28052) 把整个 harness 当联合优化目标，关键
  洞见是给 proposer 完整文件系统访问权以回溯失败（10M token 诊断上下文 vs 此前工作的
  26K）；[agentic-harness-engineering](https://github.com/china-qijizhifeng/agentic-harness-engineering)
  把 scaffold 分解为七个正交组件自动进化，素材引用其 Terminal-Bench 2.0 排名 #3
  （84.7%）且跨模型迁移。但反例同样在列：[HarnessDev](https://arxiv.org/abs/2609.01437)
  的 2207 实例基准显示，自动生成的 harness 在代码与深度研究任务上明显落后人工打磨的
  参考实现——**进化 ≠ 泛化**，人工打磨的参考实现仍是刚需。
- [Claude Agent SDK](https://platform.claude.com/docs/en/agent-sdk/overview)：把
  Claude Code 整套 harness 暴露为可编程 API，清单作者认为是构建生产 harness 的最高
  杠杆起点——直接继承整个工具执行层，而非重新实现。

## 向外扩展：同类清单与边界意识

素材的"同类精选清单"栏目本身不长，但组织原则值得学：**边界意识**。开场即声明收录的
是"覆盖相邻领域、重叠但范围不同"的清单，把 prompt/RAG、MCP 工具协议、agent 框架全景
等话题外链给专门的清单，避免自身范围蔓延；即使外链也坚持每条附一句"对本清单读者有
什么用"的定位注释——有立场的清单，而非目录。

两份提名的导航值得收藏：

- [Awesome Context Engineering](https://github.com/Meirtz/Awesome-Context-Engineering)：
  相邻主题中最完整的综述型清单。其形式化定义可操作——context 不是单条 prompt，而是
  instructions/knowledge/tools/memory/state/query 六类组件的动态装配；2026 年 3 月的
  编辑部转向"From Context Engineering to Agent Engineering"新增了 Agent Harnesses 节。
  使用建议（素材原话）：当地图用，不当书单信——部分条目存在占位链接与预印本问题。
- [Awesome Code as Agent Harness Papers](https://github.com/YennNing/Awesome-Code-as-Agent-Harness-Papers)：
  UIUC 综述《Code as Agent Harness》的官方配套库，按 Interface / Mechanisms / Scaling
  三层组织约 450 余条研究条目，全部带 arXiv/DOI 直链；Scaling 层把多智能体系统的差异
  还原为对共享 harness 的七个工程问题，做多 agent 架构选型时可当 checklist 对照。

另有一条提供"替代框架"的提名：Graph Engineering 清单把 harness 状态视为显式、可演化
的结构而非隐式 prompt 残留——素材作者称之为对同一批问题"真正不同的透镜"。

## 分梯队落地路径

素材给了一份按投入产出排序的阅读与落地路线，本章把它重组为三梯队。排序依据是素材内
的评价（README 自评、书单评语）与"深度使用 AI 编程工具的工程师"这一读者画像的匹配度。

### T0：先建坐标系（约半天）

| 资源                                                                                                                     | 用途                                                |
| ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| [Harness Engineering（OpenAI）](https://openai.com/index/harness-engineering/)                                           | 学科正名之作，所有后续讨论的定义原点                |
| [Unrolling the Codex Agent Loop（OpenAI）](https://openai.com/index/unrolling-the-codex-agent-loop/)                     | agent loop 权威解剖，理解后续所有"循环"条目的坐标系 |
| [Harness Engineering（Fowler）](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html)             | 素材评为对该学科最清晰的概念地图                    |
| [HARNESS_CHECKLIST.md](https://github.com/ai-boost/awesome-harness-engineering/blob/main/templates/HARNESS_CHECKLIST.md) | 还没建 harness 前，62 行先当"该建什么"的提纲用      |

### T1：当天就能落地

| 资源                                                                                                                                          | 用途                                                |
| --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| [templates/ 四件套](https://github.com/ai-boost/awesome-harness-engineering/blob/main/templates/AGENTS.md)                                    | AGENTS.md / PLAN.md / IMPLEMENT.md 三件当天可进仓库 |
| [Skill Issue（HumanLayer）](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents)                                | 单页覆盖全部 harness 配置点，对日常使用者命中率最高 |
| [Run Long-Horizon Tasks with Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex/)                                    | 三个 harness 工件可直接搬到自己的工作流             |
| [Effective Harnesses for Long-Running Agents（Anthropic）](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) | 素材称其为任务超出单上下文窗口时的参考设计          |

### T2：日常调优三主题

写好配置、管好上下文、建好验证：[Effective Context Engineering for AI Agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
与 [Context Engineering in 2026](https://www.louisbouchard.ai/context-engineering-2026/)
（上下文决策框架）、[Writing Effective Tools for Agents](https://www.anthropic.com/engineering/writing-effective-tools-for-agents)
（工具设计即 agent 的 UX）、[Agent SDK Permissions](https://code.claude.com/docs/en/agent-sdk/permissions)
（权限与审批的工程实现）、[faros.ai 失败分析](https://www.faros.ai/blog/why-do-ai-coding-agents-fail)
（读完就能改禁令措辞）、[Demystifying Evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
与 [eval-skills](https://developers.openai.com/blog/eval-skills)（评测总纲与 CI 管线）。
再往后的专题深入（编排、沙箱、记忆、可观测）与清单类索引，按需选修即可，对应本系列
第 4 至 9 章的各专题。

### 六步落地顺序

把上述资源折算成动作，素材给出的综合顺序是：

1. 拷贝四件套，填 AGENTS.md——手写、控制在 60 行左右、三档权限、Known constraints、
   验证门。
2. 首个非平凡任务立 PLAN.md（里程碑绑 verify 命令），执行中随手写 IMPLEMENT.md
   （append-only）。
3. 跑一轮 HARNESS_CHECKLIST 记录基线，fail 项当 blocker 处理。
4. 按 Skill Issue 纪律做减法：真实失败才加配置、舍得丢弃、能 CLI 不 MCP、子代理当
   上下文防火墙。
5. 建最小 eval：20–50 个从真实失败转来的任务 + 确定性 grader + 回归门；每次人工修复
   转成一条测试。
6. 每次模型升级的例行仪式：跑 eval → 对照失败聚类 → 重审拆除条件表 → 更新 checklist
   签字。素材还引了 Boris Cherny 的消融法作参照：全删系统提示，再只加回那些修复了
   重复失败的行。

## 按问题查章节

全系列按"解决的问题"重排过，最后给一张速查表：遇到具体症状时，直接跳对应章节。

| 症状                           | 对应章节                                                                                                                                                                                                               |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| agent 频繁停下来问、审批疲劳   | [[ch06-orchestration-and-human-in-loop\|任务编排与人机协同]]、[[ch08-sandbox-and-permissions\|沙箱、权限与审批]]                                                                                                       |
| 任务跑长就崩、忘事、上下文爆炸 | [[ch03-context-engineering\|上下文工程]]、[[ch05-memory-and-state\|记忆与状态管理]]、[[ch02-agent-loop-and-planning\|智能体循环与任务规划]]                                                                            |
| token 账单失控                 | [[ch03-context-engineering\|上下文工程]]（投递先于压缩）、[[ch09-observability-and-operations\|可观测性、调试与生产运维]]（成本护栏）                                                                                  |
| agent 乱改文件、越权动手       | [[ch08-sandbox-and-permissions\|沙箱、权限与审批]]（白名单与沙箱）、[[ch04-tools-and-mcp\|工具接口与 Skills/MCP]]（工具面收窄）、[[ch09-observability-and-operations\|可观测性、调试与生产运维]]（禁令措辞与失败归因） |
| 长程任务跑偏、静默宣称完成     | [[ch02-agent-loop-and-planning\|智能体循环与任务规划]]（计划工件与验证门）、[[ch05-memory-and-state\|记忆与状态管理]]（状态归仓）、[[ch07-evals-and-verification\|评测与验证闭环]]                                     |
| 不知道改动算不算变好           | [[ch07-evals-and-verification\|评测与验证闭环]]                                                                                                                                                                        |
| 多 agent 并行互相踩            | [[ch06-orchestration-and-human-in-loop\|任务编排与人机协同]]                                                                                                                                                           |
| 怀疑"是不是该换个更强的模型"   | [[ch01-why-harness-beats-model\|为什么 Harness 是一阶杠杆]]（68% vs 88%）、[[ch09-observability-and-operations\|可观测性、调试与生产运维]]（失败归因）                                                                 |
| 工具定义吃 token、MCP 接入选型 | [[ch04-tools-and-mcp\|工具接口与 Skills/MCP]]                                                                                                                                                                          |

## 本章小结

本章把全系列收拢为可执行的动作。模板四件套提供了当天可进仓库的起点，内核是"完成
即验证门、状态归仓、脚手架可拆除"三件事。AGENTS.md 的写作有实证边界：手写、极简、
每条禁令都要对得上真实失败。长程任务的最小 harness 与参考实现书单给出了进阶路径，
T0 到 T2 的分梯队路线把学习成本控制在半天到数天。harness 工程没有"搭完"的状态，只有
"搭好——验证——按模型进步拆除"的循环，拆除条件表就是这个循环最小的仪式。

回到系列索引：[[harness-engineering-deep-dive|Agent Harness 工程化]]
