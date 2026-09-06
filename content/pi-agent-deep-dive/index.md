---
title: "Pi Agent 深度探索系列索引"
date: 2026-06-12 00:00:00
pin: true
description: "从日常使用、Agent Loop、四个核心包源码到 Extension 与 SDK 二次开发的 Pi Agent 系统学习路径"
tags: [pi-agent, coding-agent, llm, agent, series, index]
---

# Pi Agent 深度探索系列

> [!tip] 系列定位
> 本系列从 Pi 的实际使用出发，逐步进入 Agent Loop、消息与工具协议、四个核心包源码、
> Extension 系统和 SDK 二次开发。目标不是背命令，而是能够解释一次请求如何运行，
> 并能写出可运行的定制 Agent。

Pi 是一个终端原生的 Agent Harness。它把模型接入、工具调用、会话树、上下文压缩、
终端 UI 和扩展机制组合为一套可嵌入、可替换的 Coding Agent 基础设施。

## 阅读前提

建议读者具备：

- Linux 或 macOS 终端基础；
- TypeScript、Node.js 和异步编程基础；
- 对 LLM、Prompt、Tool Calling 和 Token 有基本认识；
- 能阅读 Git diff，并理解命令可能修改当前工作目录。

完成本系列后，你应该能够：

1. 安装 Pi，配置 Provider，并管理交互会话；
2. 解释模型请求、流式事件、工具执行和 TUI 更新的完整链路；
3. 阅读 `pi-ai`、`pi-agent-core`、`pi-coding-agent`、`pi-tui` 的关键源码；
4. 开发 Tool、Command、Shortcut、Skill 和 Extension；
5. 使用 SDK 构建一个具备工具调用与会话恢复能力的最小 Coding Agent；
6. 判断 Pi 在权限、凭据、上下文和升级兼容方面的工程边界。

## 源码校验基线

本系列跟踪 `earendil-works/pi` 的 `main` 分支。首批文章使用以下快照：

```text
repository: https://github.com/earendil-works/pi
branch: main
commit: 1da903983ad72c60995507e813a00bb2bd6faf09
verified: 2026-06-12
package version at snapshot: 0.79.1
```

涉及实现细节的链接都固定到完整 commit SHA。`main` 会继续变化，因此阅读未来版本源码时，
应先核对文章记录的 SHA，再判断差异。

> [!warning] 权限边界
> Pi 默认继承启动它的用户和进程权限，不自带完整的文件系统、进程、网络和凭据沙箱。
> 在重要仓库或含敏感凭据的环境中运行前，应先使用 Git 检查点、容器或其他隔离机制。

## Part I：使用与整体认知

| #   | 章节                                           | 主题                             | 状态 |
| --- | ---------------------------------------------- | -------------------------------- | ---- |
| 1   | [[ch01-overview\|第一章]]                      | Pi 的定位、设计取舍与适用边界    | ✅   |
| 2   | [[ch02-installation-providers\|第二章]]        | 安装、认证、Provider 与模型配置  | ✅   |
| 3   | [[ch03-tui-modes-queue\|第三章]]               | TUI、运行模式、快捷键与消息队列  | ✅   |
| 4   | [[ch04-sessions-branching-compaction\|第四章]] | Session、分支、恢复与 Compaction | ✅   |
| 5   | [[ch05-monorepo-architecture\|第五章]]         | Monorepo 与四个核心包的协作关系  | ✅   |

## Part II：Agent 核心原理

| #   | 章节                                       | 状态 |
| --- | ------------------------------------------ | ---- |
| 6   | Coding Agent 的工作循环                    | 🚧   |
| 7   | Message、Tool Call 与 Tool Result 数据模型 | 🚧   |
| 8   | Streaming：增量事件与状态更新              | 🚧   |
| 9   | Context Window、Token 与上下文管理         | 🚧   |
| 10  | 中断、错误恢复与循环终止条件               | 🚧   |

阶段实验：实现一个没有 TUI 的最小 Agent Loop。

## Part III：四个核心包源码

| #   | 章节                                                | 状态 |
| --- | --------------------------------------------------- | ---- |
| 11  | `pi-ai`：统一模型抽象与 Provider 适配               | 🚧   |
| 12  | `pi-ai`：消息转换、流式响应与工具协议               | 🚧   |
| 13  | `pi-agent-core`：Agent 状态机与事件系统             | 🚧   |
| 14  | `pi-agent-core`：工具注册、执行与结果反馈           | 🚧   |
| 15  | `pi-coding-agent`：CLI 启动与依赖装配               | 🚧   |
| 16  | `pi-coding-agent`：Session 生命周期与持久化         | 🚧   |
| 17  | `pi-coding-agent`：内置 `read/write/edit/bash` 工具 | 🚧   |
| 18  | `pi-tui`：组件树、输入与事件分发                    | 🚧   |
| 19  | `pi-tui`：差量渲染、终端控制与性能                  | 🚧   |
| 20  | 一次请求的完整源码调用链                            | 🚧   |

阶段实验：记录一次真实请求的事件流，并还原跨包调用链。

## Part IV：定制与扩展

| #   | 章节                                             | 状态 |
| --- | ------------------------------------------------ | ---- |
| 21  | Context Files、System Prompt 与 Prompt Templates | 🚧   |
| 22  | Skills 的发现、加载和执行语义                    | 🚧   |
| 23  | Extensions 生命周期与事件钩子                    | 🚧   |
| 24  | 开发自定义 Tool、Command 和 Shortcut             | 🚧   |
| 25  | Pi Package：扩展的组织、安装与分发               | 🚧   |

阶段实验：实现一个包含工具、命令、快捷键和会话状态恢复的项目分析 Extension。

## Part V：SDK 与二次开发

| #   | 章节                                | 状态 |
| --- | ----------------------------------- | ---- |
| 26  | 使用 SDK 嵌入 Pi Agent              | 🚧   |
| 27  | 自定义 Provider、模型注册与认证存储 | 🚧   |
| 28  | 构建一个最小品牌化 Coding Agent     | 🚧   |

阶段实验：实现支持模型对话、文件读取、命令执行和会话恢复的独立 CLI。

## Part VI：工程化专题

| #   | 章节                                 | 状态 |
| --- | ------------------------------------ | ---- |
| 29  | 权限模型、容器化、凭据和工具安全     | 🚧   |
| 30  | 测试、调试、性能、升级兼容与源码贡献 | 🚧   |

## 配套实验

实验代码位于仓库的 `practice/pi-agent/`：

```text
practice/pi-agent/
├── phase-1-environment/
├── phase-2-minimal-agent/
├── phase-3-event-trace/
├── phase-4-project-extension/
└── phase-5-branded-agent/
```

当前已提供第一阶段的只读环境检查。后续实验会随对应章节交付，不提前放置空目录。

## 官方资源

- [Pi 官方仓库](https://github.com/earendil-works/pi)
- [Pi 官方网站](https://pi.dev)
- [首批文章对应的 README 快照](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/README.md)
- [Coding Agent 文档快照](https://github.com/earendil-works/pi/tree/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs)
