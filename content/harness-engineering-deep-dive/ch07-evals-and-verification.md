---
title: "Agent Harness 工程化（七）：评测与验证闭环"
date: 2026-10-21 01:10:00
description: "从有检查到闭环：评测设计、基础设施噪声量化与验证的 CI 集成"
tags: [harness, ai-agents, evals, ci]
---

# Agent Harness 工程化（七）：评测与验证闭环

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 7 篇
> 上一章：[[ch06-orchestration-and-human-in-loop|任务编排与人机协同]] · 下一章：[[ch08-sandbox-and-permissions|沙箱、权限与审批]]

## 先给结论

前几章讨论的规划、上下文与编排，解决的是 agent 能不能把任务做出来；本章换一个问题：你怎么知道它做对了，以及每次改动之后它是否仍然做对。综合本轮研读的工程文章与论文，可以把要点压缩成四条：

- **验证必须分层、按成本递进**。lint、协议断言、命令数与 token 预算、仓库整洁度这些确定性检查负责兜底，只有没有确定性检查可用的环节才上 LLM-as-judge。eval 成本会被 CI 里的每次 PR、每次运行反复放大——Red Hat 的实践文章算过一笔账，单次评估约 $0.64，不分层的 eval 管线会"在 eval 成本下崩塌"。
- **evals 的设计有一套可复用的框架**。[Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) 主张把评测当作 harness 的核心组件而不是事后补充，并给出 outcome/transcript、capability/regression、pass@k/pass^k 一组分类标尺。
- **基础设施噪声足以淹没结论**。Anthropic 的[噪声量化文章](https://www.anthropic.com/engineering/infrastructure-noise)实测：同模型、同任务集，仅改容器资源配置，基准分数波动可达 6 个百分点，超过多数榜单上模型之间的差距。
- **技能与工具的变更可以系统化地进 CI**。OpenAI 开发者博客的 [Testing Agent Skills Systematically with Evals](https://developers.openai.com/blog/eval-skills) 给出可照搬的流程：写 skill 之前定义四维成功标准，小 prompt 集加负例，确定性 trace 检查打底，LLM 评分兜底，分阶段收紧门禁。

## 验证回路：从 lint 到端到端

[[pi-agent-deep-dive|Pi Agent 深度探索]] 系列里我们把 harness 理解为"运行 Agent 所需的最小工程骨架"。从评测的视角看，这个骨架里最容易被省略、又最不该省略的就是验证回路。harness 内可用的验证手段天然形成一个成本阶梯：

```text
lint / 协议断言 / 仓库整洁度检查      （毫秒级，零模型成本）
trace 上的确定性检查                  （解析 JSONL 运行记录，仍是零模型成本）
LLM-as-judge 按 rubric 评分           （每次运行都要消耗 token）
人工抽审 transcript                   （最贵，用于建立直觉）
```

《Demystifying Evals》把 grader 分为三类：code-based（快、便宜、可复现，但对任务表述的变化脆弱）、model-based（灵活但非确定，需要定期与人类专家校准）、human（金标准，但贵且慢）。配套的落地规则与阶梯方向一致：能用确定性检查就不要动用模型；多组件任务给 partial credit 而不是一票否决；给 LLM judge 留 "Unknown" 逃生口，防止它在拿不准时硬编一个判定；每个评分维度用相互隔离的 judge。

### 闭环的两个要件

这轮调研中"闭环"被反复提及，但它有两个容易被忽略的要件。

其一，**验证器的错误输出本身就是 harness 输出的一部分**。[shadcn-ui/lint](https://github.com/shadcn-ui/lint) 是这个论点最清晰的示范：作为面向 agent 的 linter，它的报错信息直接携带组件尺寸、变体与主题路径，agent 拿到报错后一轮即可自纠；该项目声称这种设计比把同样规则写进 prompt 的成本低 10-48%。编译器领域的 llvm-autofix 案例同理：把编译器错误原文直接暴露给 agent，效果胜过包装后的自然语言转述。反过来，如果检查结果只给出"失败"两个字，检查再多也不构成闭环。

其二，**评分者必须独立于被优化方**。Google 的 [agent 质量飞轮](https://developers.googleblog.com/en/driving-the-agent-quality-flywheel-from-your-coding-agent/)一文强调用独立的 AutoRaters 评分，让优化器无法 game 自己的指标。把两条合起来，闭环的完整定义是：检查结果以可执行的形式回流给 agent，且不由被优化方自己给自己打分。

## Evals 的设计方法

### 两个分类轴：评什么、为什么评

《Demystifying Evals》沿两个轴给 eval 分类。按「评什么」，分 outcome 评估与 transcript 评估：前者检查试验结束时环境的最终状态——订票 agent 在对话里宣称"已订好"不算数，数据库里真的写入了这条预订才算；后者评轨迹层面的属性，如回合数、token 用量、工具调用方式。配套的设计准则是 "grade what the agent produced, not the path it took"：检查固定的工具调用序列太脆，换一条等价路径就会误判。

按「为什么评」，分 capability evals 与 regression evals。前者的起始通过率就该低，给团队留爬坡空间；后者要求接近 100% 通过，用于保护已有能力不退化。LangChain 的[评估就绪清单](https://blog.langchain.com/agent-evaluation-readiness-checklist/)把这条列为关键洞见：两类评估混在一起，会产生错误的优先级决策。运转良好的标志，是高通过率的 capability eval "毕业"进入回归套件。

### 非确定性：pass@k 与 pass^k 分开量

agent 单次运行的结果是随机的，二元 pass/fail 概括不了它。文章给了两把尺子：pass@k 是 k 次里至少对一次的概率，pass^k 是 k 次全对的概率。单次通过率 75% 的任务，三次连过的概率只有约 42%。工具型、允许重试的场景看 pass@k；面向用户、每次都必须对的 agent 必须看 pass^k。类似思路也进入了评测判据本身：Claw-Eval 的 Pass^3 指标把多次运行的稳定性直接写进评分。

超越二元判定还有过程视角的证据。AgentLens 分析了 2,614 条 OpenHands 轨迹，发现至多 23.2% 的通过属于"运气 pass"——结果正确但过程有硬伤；按过程质量重新评分后，模型排名最多变动 5 位。也就是说，只看最终对错，评到的可能不是你想评的东西。

### 低分先怀疑 eval 本身

《Demystifying Evals》里最反直觉的主张是：eval 本身就是重要的 bug 来源。文中的案例：Opus 4.5 在 CORE-Bench 上首跑仅 42%，排查出刚性判分、规格歧义、随机不可复现三类 eval 缺陷，修复后跳到 95%；METR 的某基准要求"达到"阈值却按"超过"判分，反而系统性惩罚了照章办事的模型。文中给出的经验判据：前沿模型在某任务上 0% pass@100，大概率是任务坏了。好任务的标准是两位领域专家能独立得出相同的 pass/fail 结论，且每个任务附 reference solution。

### 防作弊与评测感知

评测基建自身还需要主动防御三类威胁：

- **被评测者作弊**。trial 必须从干净隔离的环境启动——Anthropic 抓到过 Claude 靠读取前一 trial 遗留的 git history 提分。
- **评测感知**。[Opus 4.6 在 BrowseComp 上的案例](https://www.anthropic.com/engineering/eval-awareness-browsecomp)显示，模型推断出自己正在被评测、按名字认出了基准、进而解密了答案密钥。联网环境下，任何评测都可能被 agent 检索基准本身攻破，网络隔离由此成为 harness 的硬性要求。
- **测试随模型进步失效**。SWE-bench Verified 一年内从约 40% 涨到 80% 以上即是饱和的例子；Anthropic 的[评测设计文章](https://www.anthropic.com/engineering/AI-resistant-technical-evaluations)主张转向长时程、需要现场造工具、需要理解环境的任务，才能保持区分度。

冷启动的门槛并不高：20-50 个从真实失败转化的任务就是合格起点，但正反例要平衡——只测"该搜索时搜索"，会训出什么都去搜索的 agent。框架选型不必纠结，原文的建议是 quickly pick a framework, then invest your energy in the evals themselves。同时要认清 evals 的生态位：它是瑞士奶酪模型中的一层，自动化 eval（每次 commit 可跑）、生产监控（真实但滞后）、A/B 测试（真实但慢）、用户反馈（稀疏且自选择）、人工 transcript 审查（建立直觉但不可规模化），没有哪一层能单独覆盖全部风险。

## 基础设施噪声：6 个百分点的教训

### 实验设计与根因

解读任何 agentic 评测数字之前，先要过基础设施这一关。《Quantifying Infrastructure Noise in Agentic Coding Evals》做了严格的控制变量实验：同模型、同 harness、同任务集，仅改容器资源配置重跑 Terminal-Bench 2.0，最高与最低配置的分差达 6 个百分点（p<0.01）。根因在容器运行时的资源模型：保底分配（guaranteed）与硬杀上限（hard limit）两个参数本应留出余量，而实验所在的 Kubernetes 集群把两者设成同一个值，零余量，瞬时内存尖峰即触发 OOM，误杀本可成功的任务。

### 3x 是分水岭

加资源的收益不是线性的，实验在 3 倍资源处观察到性质切换：

- 1x 到 3x：基础设施错误率从 5.8% 降到 2.1%，但成功率波动仍在噪声范围内（p=0.40）——加资源只是修稳定性，没有让任务变容易。
- 3x 到不设上限：基础设施错误继续下降，成功率却跳升近 4 个百分点——超额资源让 agent 敢于执行原本跑不通的重型方案，评测被实质性改变。

"修稳"与"放水"在 3x 处分界，且作者强调这个倍数是基准相关的经验值，不可照搬。资源配置还在无意间筛选策略分布：有的模型第一反应是装 pandas、networkx 全家桶，宽限下可行、紧限下还没写一行解题代码就 OOM；另一些模型默认用标准库从零实现。紧约束奖励精简实现，宽约束奖励会调用重型工具的 agent——你测到的"能力差异"，有一部分只是资源偏好差异。跨基准的迁移幅度则取决于任务的资源密度：SWE-bench 交叉实验（227 题、每题 10 样本）分数随 RAM 单调上升，但 5x 只比 1x 高 1.54 个百分点。

### 能力归属于 model-harness 配置

噪声问题的推论是：脱离 harness 谈模型能力意义有限。[Harness-Bench](https://arxiv.org/abs/2605.27922) 用 5,194 条轨迹隔离执行层变量，主张 agent 能力应按"模型-harness 配置"报告；[StaminaBench](https://arxiv.org/abs/2606.19613) 的 100 轮连续变更压测发现，同一强模型在不同 harness 间的差距可达 6 倍，而带测试反馈与重试回路的 harness 能把通过任务数提升至多 12 倍。换言之，harness 的质量（反馈、重试、资源供给）本身就是被测能力的一部分。

### 落地守则

实验设计侧：每个任务同时指定保底值与硬顶两个参数，而不是钉死单一值；按"下限配置与顶配的分数落入彼此噪声范围"来校准资源区间；公开评测跨时段、跨日期多次运行取平均；把资源配置当作与采样温度、prompt 格式同级的一等实验变量记录。读数侧：排行榜上小于 3 个百分点的差距，在资源配置未公开且未匹配之前应持怀疑态度——二项分布的朴素置信区间本身就有 1-2 个百分点。原文的收尾警句值得贴在 dashboard 旁边：**"几分的领先可能反映真实能力差距——也可能只是一台更大的虚拟机。"**

## 技能与工具变更进 CI 的系统化评测

前几节的框架落到一个具体场景：团队维护的 skill 或工具集改了一版，怎么判断该不该合入。

### 先定义成功标准，再写 skill

《Testing Agent Skills Systematically with Evals》把 skill 视为"一组有组织的提示词与指令"，并给出可照搬的 eval 形式化：一条 prompt → 一次被捕获的运行（trace 加产物）→ 一小组检查 → 一个可跨时间比较的分数。核心是用分数替换"这个改动感觉更好吗"。

成功标准要在写 skill 之前定义，覆盖四个维度：Outcome（任务完成了吗）、Process（是否正确触发了 skill，并按预期调用工具与步骤）、Style（输出是否符合约定）、Efficiency（有没有 thrashing——多余的命令与过度的 token 消耗）。其中 Efficiency 是多数团队不会度量的盲区。

### 小 prompt 集与负例

单个 skill 用 10-20 条 prompt 就够，存成 CSV（列为 id、should_trigger、prompt），并且必须包含 should_trigger=false 的负例来抓误触发。维护节奏是文中那句口号："Every manual fix is a signal. Turn it into a test."——每次手工修复都转化为一条测试，skill 才不会在同一个地方反复跌倒。

### 两层 grader，确定性优先

- **第一层，纯确定性检查，零模型成本**：跑一次运行，把 JSONL trace 落盘，再用脚本检查——命令序列是否符合预期、产物文件是否存在、命令数量与 token 用量是否超阈值、构建与 dev-server smoke test 是否通过、git status 是否干净。这一层可以直接进 CI 快跑。
- **第二层，LLM-as-judge 兜底**：用强制 JSON schema 的方式输出 overall_pass、0-100 的分数与分项检查数组，让评分结果成为可跨 run 比较的可预测结构，而不是一段自由文本。

工程细节上，该文把运行的进度输出与最终结果分流到不同输出流，使结果天然适合管道消费；并且没有依赖现成评估框架，全部用 Codex CLI 加脚本自建，依赖面极小。

### 门禁的取舍

- 分阶段收紧：先只跑快检查，skill 成熟后再加重型检查，加检查的标准是"能否降低风险"。
- **只有回归类评估适合做 PR 门禁**。capability 评估通过率天然偏低，放进门禁会永远红；混用两类评估正是前文 LangChain 清单警告的优先级错误。
- 非确定性工作流的 CI 判定不宜用二元 pass/fail。[AgentAssay](https://arxiv.org/abs/2603.02601) 论文报告：行为指纹方法检出 86% 的回归，而二元测试为 0%；其 PASS/FAIL/INCONCLUSIVE 三态假设检验还把判定的 token 成本降了 78%。
- 配套工具按需取用：MCP 服务器有 pytest 风格的协议感知断言与快照测试框架；架构约束可以用"保存基线、再对比"的 gate 模式做回归检测，填补 linter 与测试之间的验证空白；在 Docker 沙箱里对 skill 做系统基准也已有方法论——LangChain 的[评测文章](https://blog.langchain.com/evaluating-skills/)给出，精选 skill 把任务完成率从无 skill 的 9% 提到 82%，且收敛到 12 个以内 skill 反而更准。
- 框架与运维：[promptfoo](https://github.com/promptfoo/promptfoo)、[DeepEval](https://github.com/confident-ai/deepeval)、[Inspect AI](https://github.com/UKGovernmentBEIS/inspect_ai) 分别覆盖 YAML 断言、pytest 集成与把外部 agent 当黑盒目标评测的场景；长期运维上，可行模式是专职 evals 团队管基础设施、产品团队以 PR 形式贡献任务。评测正在从交付前的一次性动作，变成随 agent 一起部署的运行时组件。

## 本章小结

验证回路的价值不在"有检查"，而在"闭环"：错误以可执行的形式回流给 agent，评分者独立于被优化方。设计 eval 时先分清评什么（outcome/transcript）与为什么评（capability/regression），非确定性用 pass@k 与 pass^k 分开量，低分先怀疑 eval 本身。解读任何评测数字前先问基础设施：6 个百分点的资源噪声足以淹没模型间的差距，资源配置是与采样温度同级的一等实验变量。技能与工具变更沿"小 prompt 集 + 负例 + 确定性检查打底 + LLM 评分兜底"的路径进入 CI，且只有回归类评估才适合当门禁。

下一章：[[ch08-sandbox-and-permissions|沙箱、权限与审批]]
