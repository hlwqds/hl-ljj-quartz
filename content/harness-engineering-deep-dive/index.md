---
title: "Agent Harness 工程化系列索引"
date: 2026-10-21 00:00:00
pin: true
description: "从 awesome-harness-engineering 全文精读出发：上下文、工具、规划、验证、沙箱与运维——模型之外决定 coding agent 成败的支架工程"
tags: [harness, ai-agents, coding-agent, llm, series, index]
---

# Agent Harness 工程化系列

> [!tip] 系列定位
> 本系列是对 GitHub 精选清单
> [ai-boost/awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering)
> 的全文精读与再组织：19 个栏目逐条笔记，38 篇重点文献原文深读，按"解决的问题"
> 重排成十个主题章。目标不是罗列链接，而是回答一个问题：**模型之外，哪些支架组件
> 真正决定 coding agent 的成败，以及怎么把它们搭起来。**

## 这个仓库是什么

awesome-harness-engineering 收录 harness（脚手架）工程化资源：上下文投递、工具接口、
计划工件、验证回路、记忆系统与沙箱。正文以带注释链接为主（OpenAI / Anthropic 工程
博客、开源仓库、论文），按"解决的问题"而非厂商分栏，并附四个可直接复制的模板文件
（`AGENTS.md`、`HARNESS_CHECKLIST`、`PLAN`、`IMPLEMENT`）。

核心论点一句话：**harness 是被数字证明的一阶性能杠杆**——同一模型换不同 harness，
得分可以从 68% 到 88%；先改 harness，再谈换模型。

## 适合谁

- 为 Claude Code / Codex 类工具搭建或加固生产级 harness 的工程师与平台团队；
- 正在写或维护 AGENTS.md、验证门与权限体系的人；
- 读过 [[pi-agent-deep-dive|Pi Agent 深度探索]]（单个 harness 的源码解剖），
  想看横向方法论与实证数据的人。

## 章节

| #   | 章节                                                            | 主题                                       |
| --- | --------------------------------------------------------------- | ------------------------------------------ |
| 1   | [[ch01-why-harness-beats-model\|为什么 Harness 是一阶杠杆]]     | 仓库导览、作者三条立场、68% vs 88%         |
| 2   | [[ch02-agent-loop-and-planning\|智能体循环与任务规划]]          | 循环最小组件、计划工件、状态外化           |
| 3   | [[ch03-context-engineering\|上下文工程]]                        | 投递取舍、压缩何时停止、注意力预算         |
| 4   | [[ch04-tools-and-mcp\|工具接口与 Skills/MCP]]                   | 工具注释即风险词汇表、代码执行式接入       |
| 5   | [[ch05-memory-and-state\|记忆与状态管理]]                       | 自纠错记忆、检索边界、状态归仓             |
| 6   | [[ch06-orchestration-and-human-in-loop\|任务编排与人机协同]]    | 并行编排、brain/hands 解耦、审批疲劳       |
| 7   | [[ch07-evals-and-verification\|评测与验证闭环]]                 | 评测设计、基础设施噪声、CI 集成            |
| 8   | [[ch08-sandbox-and-permissions\|沙箱、权限与审批]]              | 沙箱边界、权限求值链、安全意图的结构化     |
| 9   | [[ch09-observability-and-operations\|可观测性、调试与生产运维]] | 分布式追踪、失败归因、OS 级资源管控        |
| 10  | [[ch10-templates-and-landing-path\|模板四件套与落地路径]]       | 可复制模板、AGENTS.md 写作纪律、分梯队落地 |

## 怎么用本系列

- **只读一章**：第 1 章给出全系列的坐标系与核心数据；
- **照着落地**：直接跳第 10 章——模板四件套、六条 AGENTS.md 写作纪律、分梯队落地路径；
- **带着问题查**：第 10 章末尾附"按问题查章节"速查表（审批疲劳、上下文爆炸、
  账单失控、agent 乱改文件……各对应哪几章）。

## 素材与核验口径

> [!warning] 引用边界
> 本系列是学习笔记：文中数据与主张转述自清单所收录的原文作者，各章已标注出处；
> 38 篇深读均抓取了原文，其中发现的链接失效与数据修订（如 AgentCgroup 数据 v3
> 修订为 55–60%）在第 1 章的核验口径一节集中说明。清单原文与四个模板以仓库
> 当日快照为准，后续可能继续演进。
