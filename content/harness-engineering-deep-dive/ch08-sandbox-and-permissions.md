---
title: "Agent Harness 工程化（八）：沙箱、权限与审批"
date: 2026-10-21 01:20:00
description: "沙箱边界、权限求值链与安全意图的确定性表达：481 份 CLAUDE.md 给出的教训"
tags: [harness, ai-agents, sandbox, permissions]
---

# Agent Harness 工程化（八）：沙箱、权限与审批

> [!info] 本文是 [[harness-engineering-deep-dive|Agent Harness 工程化]] 系列第 8 篇
> 上一章：[[ch07-evals-and-verification|评测与验证闭环]] · 下一章：[[ch09-observability-and-operations|可观测性、调试与生产运维]]

## 先给结论

本文素材来自笔者对 awesome-harness-engineering 清单的研读笔记（「权限与授权设计」「沙箱
与权限边界」两个栏目及对应深读小节）；文中数据均注明原始出处，工程判断归属各原文作者。

- **授权必须是 harness 层的确定性控制**，而非模型自律或提示词约定。一项对 481 份公开
  CLAUDE.md 的分析发现，只有约 4% 的自然语言安全规则有对应的内建控制（[When "Do Not" Is
  Not Deny](https://arxiv.org/abs/2608.23550)）——写进提示词的安全意图若不落到执行点，就不构成护栏。
- **人肉审批是概率性的**。Anthropic 公布的内部数据：用户批准了约 93% 的权限提示；其工程
  文章的原话是「any probabilistic defense has a non-zero miss rate」，确定性边界是所有概率性
  手段都漏掉之后被撞上的那一层。
- **范式正在从弹窗审批转向沙箱**。OS 级文件系统隔离与网络隔离合取后，84% 的权限提示安全
  消失（[claude-code-sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing)）。
- **求值链有严格顺序**。Agent SDK 权限文档给出六层求值：deny 永远先于 allow、在任何模式下
  生效；canUseTool 会被自动批准路径静默旁路；子代理继承 bypassPermissions 是官方点名的陷阱。
- **跨平台没有银弹**。OpenAI 在 Windows 上从零造沙箱的结论：「没有任何一个原语能直接映射
  为安全的自主编码 agent」，最终系统是多轮原型各解一角的杂交。

## 权限求值链：确定性从顺序开始

### 六层求值顺序

Claude Agent SDK 的
[Configure Permissions](https://code.claude.com/docs/en/agent-sdk/permissions)
是目前把「结构化授权」落成工程实现最具体的官方参考。研读笔记深读时确认：一次工具调用的
权限求值按固定顺序过六道闸（清单提名时写五层，现行文档已列为六步）：

1. **Hooks**：PreToolUse hook 排在最前，可直接 deny；但 hook 的 allow 不能跳过后面的
   deny/ask；
2. **deny 规则**：命中即拦，官方强调 even in bypassPermissions mode；
3. **ask 规则**：命中即发起审批；
4. **权限模式**：dontAsk / acceptEdits / plan / bypassPermissions；
5. **allow 规则**：放行，但绝不自动批准 critical path 的 rm/rmdir 与网络路径读；
6. **canUseTool**：兜底回调。

这个顺序本身就是设计宣言：deny 排在 allow 之前、且在任何模式下仍然生效，意味着「禁止」
是 harness 的硬约束，不是与「允许」讨价还价的软偏好。想做到「每次调用都检查」，唯一可靠
的位置是排最前的 PreToolUse hook。

### 模式语义与静默旁路

模式定义里藏着不少工程细节：

- dontAsk 把一切待确认调用直接判 deny，且 canUseTool is never called；
- acceptEdits 除了文件编辑，还自动批准 mkdir/touch/rm/rmdir/mv/cp/sed——但仅限工作目录与
  additionalDirectories 之内；
- bypassPermissions 在 root/sudo 且无沙箱时拒绝启动；
- plan 模式下文件编辑永不自动批准——allow 规则和 hook allow 都不行。

两个容易静默踩中的坑。其一，allowedTools 不约束 bypassPermissions：官方明示
allowedTools: ["Read"] 加 bypassPermissions 的组合 still approves every tool, including Bash,
Write, and Edit——限权必须用 disallowedTools。相邻的细节是两种 deny 的差别：裸名 deny
（如 "Bash"）在求值前就把工具从上下文整体移除，模型根本无法尝试；带参数的 deny（如
`Bash(rm *)`）才是逐调用拦截。

其二，canUseTool 会被自动批准路径静默旁路：allow 规则、acceptEdits、bypassPermissions 批准
的调用根本到不了回调——把权限检查写在这里，对该工具形同虚设。TS SDK 会发一次性 Node
warning（code=CLAUDE_SDK_CAN_USE_TOOL_SHADOWED）提示这种遮蔽。

子代理继承也有官方点名的陷阱：子代理默认跑在父会话的模式，bypassPermissions 永远不会从
子代理自己的定义被应用——「A subagent runs in bypassPermissions mode only when the parent
session itself does」。理由是子代理 system prompt 不同、行为约束更少，继承的
bypassPermissions 等于交给它全自主访问。配套提醒：一旦显式设置 settingSources，必须自己
带上 "project"，否则项目里的声明式规则静默失效。

最简锁定组合因此很短：allowedTools: ["Read", "Glob", "Grep"] 加 permissionMode: "dontAsk"
——能读、能搜，不能写、不能执行，且一切待确认调用直接判 deny。

### 单次调用之外

求值链规范的是一次调用内的秩序；放宽到整个系统，同一思路有更一般的形式。Microsoft 的
[Authorization Fabric](https://techcommunity.microsoft.com/blog/microsoft-security-blog/authorization-and-governance-for-ai-agents-runtime-authorization-beyond-identity/4509161)
主张 PEP/PDP 分离，每次工具执行前返回 ALLOW / DENY / REQUIRE_APPROVAL / MASK 四元确定性
决策；[OAP](https://arxiv.org/abs/2603.20953) 把「预行动同步拦截 + 密码学签名审计」做成开放
规范，笔记摘录的数据是中位延迟 53ms、对抗测试中限制性策略 0% 攻击成功率。名称不同，骨架
相同：把「此刻该不该由它为这个用户执行这个动作」从模型的临场判断，挪进 harness 的确定性
执行点。

## 从弹窗审批到沙箱：一次范式转移

Anthropic 工程文章
[Beyond permission prompts](https://www.anthropic.com/engineering/claude-code-sandboxing)
（2025-10-20 发布；提名原链已 404，正文现位于 claude-code-sandboxing）给这个领域定了调。

问题设定很日常：Claude Code 默认只读，改动与命令执行需逐次批准。持续 approve 造成
approval fatigue——用户不再细看就批准，安全提示机制反而让开发更不安全。配套的
[Auto Mode](https://www.anthropic.com/engineering/claude-code-auto-mode)
文章给出了量化版本：用户批准约 93% 的提示，审批在统计上已接近自动放行。

文章的核心主张是：安全与自主不是权衡，可以用结构化边界同时买到。结构指文件系统隔离与
网络隔离的合取，缺一不可——只有文件隔离没有网络隔离，SSH key 这类敏感文件可被外传；只有
网络隔离没有文件隔离，agent 能通过改文件逃逸拿到网络。两者合取后，即使提示注入完全成功，
损害也被关在笼内。内部数据：该方案安全地减少了 84% 的权限提示。

实现选型刻意避开容器，直接用 OS 原语——Linux bubblewrap、macOS seatbelt——约束覆盖命令
派生的全部脚本、子进程、子代理与 MCP server，零容器启停开销；沙箱运行时以 research
preview 开源，作者明确建议其他 agent 团队采纳。

全文最有移植价值的架构模式（笔记作者的评价）是网络代理：沙箱内进程只能经 unix domain
socket 连到沙箱外的代理出网，代理强制域名白名单、对新域名发起用户确认。这把「审批」从逐
操作的前置检查，重构为出站路径上一个可审计、可定制策略的 choke point。交互随之变成三分
模型：沙箱内自由执行不提示；越界立即通知、由用户决定放行与否——「自动放行安全操作、硬拦
恶意操作、只在必要时询问」。

凭据的处理是同一条思路的延伸：git 凭据、签名密钥绝不进沙箱；沙箱内 git 客户端持有自定义
的 scoped credential，代理校验凭据与交互内容（如只允许推送配置的分支）后附上真实 token
转发——agent 持有的是窄能力，而非完整密钥。

同一路线的旁证不止一家：Cursor 的
[agent sandboxing](https://cursor.com/blog/agent-sandboxing)
用 Seatbelt / Landlock+seccomp / WSL2 实现「边界内自由探索、仅对外部访问请求审批」，用户
打断减少 40%；其文档还专门提到，agent 需要被显式教会识别沙箱约束。

[[pi-agent-deep-dive|Pi Agent 深度探索]]系列第一章总结 Pi 的取舍时点明：本地、透明、可组合
的代价是「使用者必须认真处理权限、凭据、版本漂移和扩展信任」。把这句话放进本文语境，就是
同一条主线的另一面——harness 给了 agent 多大的本地自由，就要用同等级别的确定性边界把它
罩住。

## 跨平台现实：Windows 上从零造沙箱

macOS 有 Seatbelt，Linux 有 bubblewrap 与 seccomp，Windows 呢？OpenAI 的
[Building a safe, effective sandbox to enable Codex on Windows](https://openai.com/index/building-codex-windows-sandbox/)
（2026-09-11 发布）记录了完整决策链，笔记作者评价它是「可迁移性最强的实践指南」。

三个 Windows 原生方案被逐一否决，否决理由本身就值得背下来：

- AppContainer 是 capability 模型，要求应用预先声明所需资源，而 coding agent 驱动开放式
  工作流，形状完全不匹配；
- Windows Sandbox 隔离最强，但 Codex 必须直接操作用户真实 checkout，且 Windows Home SKU
  根本没有这个功能；
- MIC 低完整性标签改写的是宿主机文件系统的全局语义——把 workspace 标成 low integrity 不是
  「Codex 可写」，而是「所有低完整性进程都可写」。

第一版原型走零提权路线：合成 SID + write-restricted token + deny-ACE——给沙箱专属 SID 授予
工作区写权限，再对同一 SID 在 `.git` 等目录显式 deny，在可写目录里刻出「可写区内的只读
区」。它被否决的直接原因是网络封锁只是劝告性的：把 HTTPS_PROXY 指到 discard 端口、在
PATH 头部插 stub，拦不住不读环境变量的程序、绕过 PATH 的进程和自带网络栈的二进制。可
迁移结论：**环境变量级别的网络封锁对 agent 沙箱只能算 UX 兜底，不算 enforcement**。

最终方案的关键一跳，是把 restricted token 的 principal 从真实用户换成两个专建的本地用户
——CodexSandboxOffline（防火墙封全部 outbound）与 CodexSandboxOnline（不封），用「按用户」
维度的防火墙规则实现进程树级网络隔离。此前走不通的原因：Windows 不允许防火墙规则匹配
restricted token 的非主体身份，按二进制路径匹配管不住它 spawn 的 git/python，端口/地址规则
是完全错误的策略维度。跨用户 spawn 撞上 CreateProcessAsUserW 的特权墙，解法是两段式：先用
CreateProcessWithLogonW 把 codex-command-runner.exe 以沙箱用户身份拉起，限制动作全部发生在
沙箱用户一侧的登录边界内。

元结论两条：换 principal 有隐藏代价（沙箱用户默认读不了真实用户的 profile 目录，需补
read ACL）；以及作者自己的点破——**Windows 上没有任何一个原语能直接映射为「安全的自主
编码 agent」，最终系统是多轮原型各解一角的杂交；coding agent 的沙箱安全与经典应用安全是
两个物种**。

## 厂商侧实践：三套遏制架构与一个核心案例

Anthropic 的
[How we contain Claude across products](https://www.anthropic.com/engineering/how-we-contain-claude)
是笔记中唯一同时覆盖分产品遏制架构、模型层防御失效数据与 allowlist 外泄复盘的第一方深文。
三套遏制架构对应三种信任模型，隔离强度刻意对齐用户监督能力：

| 产品        | 边界形态               | 关键设计                              |
| ----------- | ---------------------- | ------------------------------------- |
| claude.ai   | 服务端临时容器         | gVisor + seccomp，每会话文件系统即抛  |
| Claude Code | 用户机器上的 OS 级沙箱 | Seatbelt / bubblewrap，网络默认拒绝   |
| Cowork      | 完整 VM                | 凭证留在宿主 keychain，挂载目录分三档 |

其中 Claude Code 的沙箱语义是「读放行、工作区内写放行、网络默认拒绝」，已开源为
sandbox-runtime；Cowork 的挂载目录分 read-only / read-write / read-write-no-delete 三档，且
符号链接解析必须发生在路径验证之前。

概率性防御的失效数据值得直接引用（均出自该文）：

- 用户批准了约 93% 的权限提示；
- Claude Code auto mode 拦截约 83% 的过度积极行为，漏过约 17%，误拦良性命令约 0.4%；
- Gray Swan 基准上，Opus 4.7 的 prompt injection 单次成功率约 0.1%，100 次自适应尝试后
  升到 5–6%。

文章的定性结论是两句引文：「any probabilistic defense has a non-zero miss rate」；「The
deterministic boundary is what gets hit when everything probabilistic misses」。2026 年 2 月的
一次内部演练进一步收紧了论证：25 次演练尝试中 24 次经用户本人通道把 AWS 凭据带出——指令
来源就是用户本人，分类器没有任何异常可抓。于是只剩一条可靠兜底：凭据根本不进沙箱或 VM。

核心案例是 allowlist 外泄复盘。Cowork 的 egress allowlist 正确放行了 api.anthropic.com；挂载
工作区中的文件携带隐藏指令与第三方的 API key，Claude 照做把数据经该 API 上传——原文的
概括是「The sandbox worked perfectly, and yet the data was exfiltrated.」。教训是把 allowlist
从「可通信目的地过滤器」重新理解为「能力授权」：任一放行域名上可达的每个功能都是暴露面。
修复方式是在 VM 内部署防御性代理，只放行携带 VM 自身会话令牌的请求。

「最弱的层是你自己搭的那层」：hypervisor、seccomp、gVisor 全都扛住了，事故都出在自建组件
——allowlist 代理，以及项目级 settings.json 中定义的 hook 在信任对话框出现前即被执行（三起
漏洞，修复是把项目配置的解析与执行推迟到用户接受信任提示之后）。工程含义：优先用经对抗
检验的成熟原语，自定义粘合代码才是审计重点。

还有两笔值得记录。其一：「An audited connector isn't the same as audited data」——GitHub
connector 审计过关，也能把携带注入内容的 README 直接载入上下文。其二，NVIDIA 的沙箱实践
指南从另一侧指出：能改写自己 MCP 配置与 hooks 文件的 agent 可以自我提权，标准沙箱隔离
防不住这类路径（笔记 §2.15 摘录）。

harness 本身的位置也有共识。OpenAI API 的
[Sandbox Agents](https://developers.openai.com/api/docs/guides/agents/sandboxes)
文档把 harness 控制面（auth、计费、编排）与沙箱算力面（文件、shell、端口）严格分离；
[The Agent Harness Belongs Outside the Sandbox](https://www.mendral.com/blog/agent-harness-belongs-outside-sandbox)
给出同构主张：agent loop 跑在沙箱外，凭据不进不可信容器，沙箱成为可挂起的 cattle 而非
会话命脉。

## 安全意图要写成确定性验证门

回到开头的数字。[When "Do Not" Is Not Deny](https://arxiv.org/abs/2608.23550) 分析了 481 份
公开 CLAUDE.md：只有约 4% 的自然语言安全规则有对应的内建控制支撑。结合 GitHub 项目
[nah](https://github.com/manuelschipper/nah)
的观察——同一个二进制因参数不同可善可恶，命令名黑白名单不可复现——笔记作者把结论压缩
成一句话：安全意图应从 prompt 挪进结构化执行点（deny 规则、hook、预执行拦截、意图分类）。

同一个安全意图，两种写法的差别：

| 规则写法               | 落点           | 实际效果                                   |
| ---------------------- | -------------- | ------------------------------------------ |
| 自然语言安全规则       | 无（模型自律） | 无确定性执行点，不构成护栏                 |
| deny 规则 `Bash(rm *)` | 求值链第 2 层  | 命中即拦，bypassPermissions 下仍生效       |
| PreToolUse hook        | 求值链第 1 层  | 每次工具调用必经，能兑现「每次调用都检查」 |

权限 UX 决定安全意图能否存活。一项 113 人用户研究
（[arXiv:2608.27443](https://arxiv.org/abs/2608.27443)）发现：用户自写的 allow/ask/never 预授权
策略几乎全部把规则设为 ask、随后照批不误，整体上比逐动作审批少挡约 20 个百分点的越权。
这与 93% 的批准率互相印证：审批疲劳既是效率问题，也是安全问题。Claude Code Auto Mode 的
应对不是加更多弹窗，而是重设计交互——两段式分类器（单 token 快门、仅对被标记的动作做
思维链）加 deny-and-continue，被拦的动作不停机、不惩罚，流程继续。

落到操作层面，可执行的收束是：把 CLAUDE.md / AGENTS.md 里每一句「不要做 X」盘点一遍，问
它有没有对应的执行点；没有的，要么补 deny 规则或 hook，要么明示它只是偏好而非护栏。安全
意图和正确性意图一样，只有写成确定性验证门，才会被持续兑现。

## 本章小结

权限系统的演化方向，是从「模型自律 + 人肉审批」走向「harness 层的确定性控制」：deny 先于
allow 的六层求值链、缺一不可的文件系统与网络双隔离、控制面与算力面分离，都是这条路线的
工程化身。概率性手段（提示词、分类器、审批弹窗）仍然有用，但 Anthropic 与 OpenAI 的实践
指向同一句话——确定性边界才是所有概率性防御都漏掉之后被撞上的那一层。对个体开发者，起步
动作很具体：盘点提示词里的安全规则，把真正要紧的那些，改写成 deny 规则、hook 或沙箱配置。

下一章：[[ch09-observability-and-operations|可观测性、调试与生产运维]]
