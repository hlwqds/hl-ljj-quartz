---
title: "Pi Agent 深度探索（三）：TUI、运行模式、快捷键与消息队列"
date: 2026-06-12 00:30:00
description: "掌握 Pi 的 Interactive、Print、JSON、RPC 四种运行方式，以及运行中的 steering 和 follow-up 消息"
tags: [pi-agent, coding-agent, tui, json, rpc]
---

# Pi Agent 深度探索（三）：TUI、运行模式、快捷键与消息队列

> [!info] 源码基线
> 本文校验于 2026-06-12，基于 `earendil-works/pi` 的 `main` 分支提交
> `1da903983ad72c60995507e813a00bb2bd6faf09`，主要涉及
> `pi-coding-agent` 和 `pi-tui`。

## 四种模式解决四类问题

Pi 不是只有全屏交互界面。当前 CLI 提供四种主要运行模式：

| 模式        | 命令                   | 输入输出形态            | 典型用途                  |
| ----------- | ---------------------- | ----------------------- | ------------------------- |
| Interactive | `pi`                   | TUI + 键盘交互          | 日常编码、调试、长任务    |
| Print       | `pi -p "..."`          | 一次性文本输出          | Shell 管道、简单自动化    |
| JSON        | `pi --mode json "..."` | JSONL 事件流            | 事件记录、自定义展示层    |
| RPC         | `pi --mode rpc`        | stdin/stdout JSONL 协议 | IDE、桌面端、宿主进程集成 |

它们共享模型、工具、Session 和 Agent 运行时，但对交互方式的要求不同。

来源：

- [Using Pi](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs/usage.md)
- [JSON Mode](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs/json.md)
- [RPC Mode](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs/rpc.md)

## Interactive：默认的人机协作界面

直接运行：

```bash
pi
```

交互界面分为四个主要区域：

```text
┌─────────────────────────────────────────────────┐
│ Startup Header                                  │
│ 快捷键、上下文文件、Skill、Extension 等         │
├─────────────────────────────────────────────────┤
│ Messages                                        │
│ 用户消息、模型流式输出、工具调用和通知          │
│                                                 │
├─────────────────────────────────────────────────┤
│ Editor                                          │
│ 当前输入、补全、文件引用和队列提交              │
├─────────────────────────────────────────────────┤
│ Footer                                          │
│ cwd、Session、Token、Cost、Context、Model       │
└─────────────────────────────────────────────────┘
```

Editor 不只是单行输入框：

- 输入 `@` 模糊查找项目文件；
- `Tab` 补全路径；
- `Shift+Enter` 插入换行；
- `!command` 执行 Shell 并把输出放入模型上下文；
- `!!command` 执行 Shell，但不把输出放入模型上下文；
- `Ctrl+G` 使用 `$VISUAL` 或 `$EDITOR` 打开外部编辑器。

注意：`!!command` 只是控制输出是否进入模型上下文，不会把命令放进安全沙箱。

## Print：最简单的一次性调用

```bash
pi -p "Summarize this repository"
```

Print Mode 适合：

- Shell 脚本中的一次性任务；
- 把标准输入交给模型；
- 不需要在 TUI 中持续交互的请求。

例如：

```bash
cat README.md | pi -p "Summarize this text"
pi -p @src/app.ts "Explain the public API"
```

自动化场景建议显式控制 Session 和 Tool：

```bash
pi \
  --no-session \
  --tools read,grep,find,ls \
  -p "Review the repository without modifying files"
```

自然语言中的“不要修改”不是权限控制，真正限制写能力的是工具 allowlist。

## JSON：把内部事件变成数据流

```bash
pi --mode json "List the top-level files"
```

stdout 会输出 JSON Lines。事件包括：

```text
session
agent_start
turn_start
message_start
message_update
tool_execution_start
tool_execution_update
tool_execution_end
message_end
turn_end
agent_end
```

可以用 `jq` 过滤：

```bash
pi --mode json "List files" 2>/dev/null |
  jq -c 'select(.type == "message_end")'
```

JSON Mode 适合观察 Agent 行为和构建简单消费者，但它仍然是“一次启动一个 Pi 进程”。
如果宿主程序要长期控制会话、动态发送消息或查询状态，应使用 RPC 或 SDK。

## RPC：用协议控制长期进程

```bash
pi --mode rpc
```

RPC Mode 使用 stdin/stdout 上的 JSONL：

```json
{ "id": "req-1", "type": "prompt", "message": "Explain this project" }
```

进程返回带相同 `id` 的响应，并继续输出 Agent 事件。

RPC 与 JSON Mode 的区别：

| 能力             | JSON Mode            | RPC Mode              |
| ---------------- | -------------------- | --------------------- |
| 启动后追加命令   | 不作为主要控制方式   | 支持                  |
| 请求/响应关联    | 事件流为主           | 支持 `id`             |
| 查询当前状态     | 由消费者自行累积     | `get_state`           |
| 流式期间追加消息 | 不适合               | `steer`、`follow_up`  |
| 典型宿主         | 日志工具、事件分析器 | IDE、桌面端、服务进程 |

Node.js 或 TypeScript 应用若与 Pi 运行在同一进程，也可以直接使用 SDK，避免子进程和协议封装。

## 常用 Slash Commands

输入 `/` 可以打开命令补全。第一阶段最常用的是：

| 命令        | 作用                              |
| ----------- | --------------------------------- |
| `/login`    | 管理 OAuth 或 API Key             |
| `/model`    | 选择模型                          |
| `/settings` | 调整 thinking、主题和消息投递方式 |
| `/resume`   | 恢复历史 Session                  |
| `/new`      | 新建 Session                      |
| `/session`  | 查看当前 Session 信息             |
| `/tree`     | 在当前 Session 树中导航           |
| `/fork`     | 从旧用户消息创建新 Session        |
| `/clone`    | 复制当前活动分支到新 Session      |
| `/compact`  | 手动压缩上下文                    |
| `/reload`   | 重新加载配置和资源                |
| `/hotkeys`  | 查看当前快捷键                    |
| `/quit`     | 退出                              |

Extension、Skill 和 Prompt Template 还可以添加新的命令。

## 核心快捷键

以下是当前快照的默认绑定：

| 快捷键         | 行为                          |
| -------------- | ----------------------------- |
| `Enter`        | 提交输入；运行中提交 steering |
| `Alt+Enter`    | 运行中提交 follow-up          |
| `Escape`       | 中断当前操作                  |
| `Alt+Up`       | 把已排队消息取回 Editor       |
| `Ctrl+L`       | 打开模型选择器                |
| `Ctrl+P`       | 切换到下一个 scoped model     |
| `Shift+Ctrl+P` | 切换到上一个 scoped model     |
| `Shift+Tab`    | 切换 thinking level           |
| `Ctrl+O`       | 展开或收起工具输出            |
| `Ctrl+G`       | 打开外部编辑器                |
| `Ctrl+D`       | Editor 为空时退出             |

快捷键可以在 `~/.pi/agent/keybindings.json` 中覆盖，并通过 `/reload` 重新加载。

完整快照：
[Keybindings](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs/keybindings.md)。

## 运行中的两种队列

当 Agent 正在执行时，Pi 允许继续提交消息。两类消息的投递时机不同。

### Steering

在运行中按 `Enter` 提交：

```text
先不要改代码，先运行现有测试。
```

Steering 会在**当前 Assistant Turn 及其工具调用执行结束后**，在下一次模型调用前进入上下文。
它适合及时改变方向。

```text
当前模型响应
  -> 执行本回合 Tool Call
  -> 注入 Steering
  -> 下一次模型调用
```

Steering 不是在工具执行到一半时强制打断。若当前命令必须立即停止，应使用 `Escape` 中止。

### Follow-up

在运行中按 `Alt+Enter` 提交：

```text
完成后再生成一份变更说明。
```

Follow-up 会等 Agent 没有更多工具调用和 Steering 后再处理：

```text
当前任务完整结束
  -> Agent 原本准备停止
  -> 注入 Follow-up
  -> 开始新回合
```

这适合追加不需要改变当前执行路径的任务。

### Queue Mode

Steering 和 Follow-up 各自可以配置消息投递模式，例如一次取一条或一次取全部。
这影响排队多条消息时如何注入下一回合，不改变两种队列的基本时机。

底层 Agent Loop 先检查 Steering，在 Agent 原本准备结束时再检查 Follow-up：
[agent-loop.ts](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/agent/src/agent-loop.ts)。

## 中断与退出

### 中断当前运行

按：

```text
Escape
```

Pi 会中止当前 Agent 操作，并把排队消息恢复到 Editor。模型请求或工具命令是否能立即停止，
取决于相应实现是否正确响应 `AbortSignal`。

### 清空输入

```text
Ctrl+C
```

在默认 Editor 中主要用于清空输入或取消选择界面，不应与 Shell 中“永远代表终止进程”
混为一谈。

### 退出

Editor 为空时：

```text
Ctrl+D
```

也可以执行：

```text
/quit
```

## 模式选择建议

```text
需要持续对话和人工监督       -> Interactive
一次性文本任务               -> Print
只消费完整事件流             -> JSON
要双向控制长期 Pi 进程       -> RPC
Node.js 内同进程深度集成     -> SDK
```

先选择交互边界，再决定使用哪个模式。不要为了“自动化”默认使用 RPC；对于只执行一次的任务，
Print Mode 更简单，也更容易管理进程生命周期。

## 本章小结

Pi 的四种模式共享同一个 Agent 能力栈，但暴露不同的控制表面。Interactive 面向人，
Print 面向一次性命令，JSON 面向事件消费者，RPC 面向长期双向集成。运行中的 Steering
和 Follow-up 分别用于“改变当前方向”和“当前任务结束后追加工作”。

下一章：[[ch04-sessions-branching-compaction|Session、分支、恢复与 Compaction]]
