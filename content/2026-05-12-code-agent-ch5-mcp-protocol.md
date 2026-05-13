---
title: "Code Agent Ch5: MCP 协议详解"
date: "2026-05-12"
tags: ["Code Agent", "MCP", "Protocol", "gsd2", "AI Agent", "JSON-RPC"]
description: "深入解析 Model Context Protocol (MCP) 协议架构、原语、SDK 实现及与 gsd2 的集成方案"
---

# Code Agent Ch5: MCP 协议详解

## 1. MCP 概述

### 1.1 起源

MCP（Model Context Protocol）是 Anthropic 于 2024 年 11 月正式推出的开放协议，旨在为 AI 大模型提供标准化的**工具调用**和**资源访问**能力。在 MCP 出现之前，每种 AI Agent（如 Claude Code、GPTs、Cursor 等）都各自定义工具调用协议，彼此不兼容。开发者每当需要让 AI Agent 调用外部工具（如文件系统、Git、数据库）时，都需要为每个平台编写独立的适配代码。

MCP 的核心设计哲学是：**将 AI 应用与工具提供者之间的通信协议标准化**，实现"一次编写，到处运行"。它借鉴了 LSP（Language Server Protocol）的成功经验——LSP 统一了 IDE 与语言服务器之间的交互，使得 VS Code、Neovim 等编辑器无需为每种编程语言单独实现语法分析、跳转、补全等功能。MCP 同样希望成为 AI Agent 与外部工具之间的"LSP"。

### 1.2 设计目标

MCP 协议在设计时有以下核心目标：

| 目标 | 说明 |
|------|------|
| **标准化接口** | 定义统一的工具（Tools）、资源（Resources）、提示（Prompts）接口规范 |
| **可扩展架构** | 通过 Server/Client 模式，支持任意数量的工具提供者 |
| **传输层无关** | 核心协议与传输层解耦，可基于 stdio、WebSocket、SSE 等传输 |
| **类型安全** | 使用 JSON Schema 定义接口契约，工具输入输出有强类型约束 |
| **双向通信** | 支持 Server 向 Client 主动推送（Notifications） |
| **安全隔离** | 支持认证、授权、输入验证等安全机制 |

### 1.3 与其他协议对比

MCP 并非唯一的 AI 工具调用协议。业界还有 OpenAI Functions、Tool Use (GPT-4v)、LangChain Tools 等方案。以下是横向对比：

| 特性 | MCP | OpenAI Functions | LangChain Tools | Tool Use (Anthropic) |
|------|-----|-----------------|-----------------|----------------------|
| **标准化程度** | 开放标准 (Apache 2.0) | OpenAI 专有 | 社区驱动 | Anthropic 专有 |
| **架构模式** | Host/Client/Server 三层 | 单点集成 | Chain/RAgent 模式 | Agent/Tool 直连 |
| **传输层** | 传输无关 (stdio/WS/SSE) | REST API | 库调用 | REST API |
| **资源抽象** | 原生支持 Resources | 不支持 | 需自行实现 | 不支持 |
| **提示模板** | 原生支持 Prompts | 不支持 | 需自行实现 | 不支持 |
| **SDK 多语言** | TypeScript/Python/其他 | 仅 OpenAI API | Python/JS | 仅 Anthropic API |
| **Server 发现** | 通过初始化握手发现 | N/A | 手动注册 | N/A |
| **双向推送** | 支持 (Notifications) | 不支持 | 有限支持 | 不支持 |

从对比可以看出，MCP 的最大优势在于其**完整的协议设计**——它不仅定义了工具调用，还定义了资源访问和提示模板，并且设计了清晰的三层架构（Host/Client/Server），使得协议可以在多种传输层上运行，同时支持双向通信。

## 2. MCP 协议架构

### 2.1 三层架构概述

MCP 协议采用经典的**三层架构**：

```
┌─────────────────────────────────────────────────────┐
│                     Host (宿主)                       │
│   AI 应用本体：gsd2、Claude Code、Cursor 等           │
│   负责任务协调、会话管理、结果聚合                      │
└──────────────────────┬──────────────────────────────┘
                       │ MCP Protocol (JSON-RPC 2.0)
              ┌────────▼────────┐
              │     Client      │
              │   (客户端中间件)  │
              │ 管理与 Server    │
              │ 的连接生命周期    │
              └────────┬────────┘
                       │ MCP Protocol
              ┌────────▼────────┐
              │     Server     │
              │  (工具提供者)    │
              │ 文件系统/Git/   │
              │ 数据库/ Slack   │
              └─────────────────┘
```

- **Host（宿主）**：AI 应用的核心进程，负责管理整个会话生命周期。它持有 Client 实例，协调来自用户或 LLM 的请求，将请求路由到合适的 Server。
- **Client（客户端）**：嵌入在 Host 内部的网络代理模块。它与 Server 建立一对一的持久连接（通常是 stdio 管道或 WebSocket），负责协议序列化和反序列化、请求-响应匹配、心跳检测等。
- **Server（服务器）**：每个独立的工具提供者。它暴露一组工具（Tools）、资源（Resources）和提示模板（Prompts），供 Client 调用。

### 2.2 连接生命周期

一次完整的 MCP 会话生命周期如下：

```mermaid
sequenceDiagram
    participant Host
    participant Client
    participant Server

    Note over Host: 启动阶段
    Host->>Client: 创建 Client 实例
    Client->>Server: initialize (协议版本/能力协商)
    Server-->>Client: protocolVersion + capabilities
    Client-->>Host: 初始化完成

    Note over Host: 工具发现阶段
    Host->>Client: 发送 tools/list
    Client->>Server: tools/list
    Server-->>Client: tools/list + result (工具清单)
    Client-->>Host: 返回工具清单

    Note over Host: 工具调用阶段 (可重复多次)
    Host->>Client: 发送 tools/call
    Client->>Server: tools/call (tool + arguments)
    Server-->>Client: tools/call + result
    Client-->>Host: 返回调用结果

    Note over Host: 资源订阅阶段
    Host->>Client: resources/subscribe (uri)
    Client->>Server: resources/subscribe
    Server-->>Client: 资源更新事件 (主动推送)
    Client-->>Host: 推送资源更新

    Note over Host: 关闭阶段
    Host->>Client: 关闭连接
    Client->>Server: 发送关闭信号
    Client-->>Host: 连接已关闭
```

### 2.3 能力协商机制

MCP 在初始化阶段使用**能力协商（Capability Negotiation）**机制。Client 和 Server 通过 `initialize` 请求互相声明自己支持的能力。这种设计允许不同版本的 Client 和 Server 相互兼容：

```typescript
// Client 声明的能力
interface ClientCapabilities {
  tools?: {
    listChanged?: boolean;  // 是否支持 tools/list 变更通知
  };
  resources?: {
    subscribe?: boolean;   // 是否支持资源订阅
    listChanged?: boolean; // 是否支持资源列表变更通知
  };
  prompts?: {
    listChanged?: boolean; // 是否支持 prompts 变更通知
  };
  experimental?: Record<string, unknown>;
}

// Server 声明的能力
interface ServerCapabilities {
  tools?: {
    listChanged?: boolean;
  };
  resources?: {
    subscribe?: boolean;
    listChanged?: boolean;
  };
  prompts?: {
    listChanged?: boolean;
  };
  experimental?: Record<string, unknown>;
}
```

## 3. JSON-RPC 2.0 基础

MCP 协议构建在 JSON-RPC 2.0 规范之上。理解 JSON-RPC 2.0 是掌握 MCP 的前提。

### 3.1 Request（请求）

JSON-RPC 2.0 的请求格式如下：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": {
    "cursor": "optional-pagination-cursor"
  }
}
```

其中 `id` 是必须的，用于匹配响应。如果不需要响应（如单向通知），可以省略 `id` 或使用 `id: null`。

### 3.2 Response（响应）

成功响应：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [...]
  }
}
```

错误响应：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32602,
    "message": "Invalid params: tool not found",
    "data": { "toolName": "nonexistent" }
  }
}
```

### 3.3 Notification（通知）

通知是**无响应**的请求，用于 Server 主动向 Client 推送消息：

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": {
    "uri": "file:///project/config.toml"
  }
}
```

通知不需要 `id` 字段，因为发送方不期望接收任何响应。

### 3.4 错误码

JSON-RPC 2.0 定义了一组标准错误码：

| 错误码 | 含义 |
|--------|------|
| -32700 | Parse error - 无效的 JSON |
| -32600 | Invalid Request - 请求格式错误 |
| -32601 | Method not found - 方法不存在 |
| -32602 | Invalid params - 参数无效 |
| -32603 | Internal error - 内部错误 |
| -32000 到 -32099 | 保留供 MCP 自定义错误 |

MCP 还定义了自己的错误码范围：

| 错误码 | 含义 |
|--------|------|
| -32000 | **Resource not found** - 资源不存在 |
| -32001 | **Resource already exists** - 资源已存在 |
| -32002 | **Resource not accessible** - 资源不可访问 |
| -32003 | **Tool execution failed** - 工具执行失败 |
| -32004 | **Tool not found** - 工具不存在 |
| -32005 | **Prompt not found** - 提示模板不存在 |

### 3.5 请求 ID 的类型

JSON-RPC 2.0 允许 `id` 为字符串、数字或 `null`。在 MCP 实现中，建议使用**字符串格式**的 ID，以便于调试和日志追踪：

```json
{
  "jsonrpc": "2.0",
  "id": "req-1698765432-001",
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": { "path": "/project/README.md" }
  }
}
```

## 4. MCP 核心原语

MCP 协议定义了三类核心原语：**Tools**（工具）、**Resources**（资源）、**Prompts**（提示模板）。每一类原语都有对应的操作方法。

### 4.1 Tools 原语

Tools 是 AI Agent 执行实际操作的核心机制。它使 Server 能够向 Client 提供可调用函数。

| 方法 | 方向 | 说明 |
|------|------|------|
| `tools/list` | Client → Server | 获取所有可用工具的清单 |
| `tools/call` | Client → Server | 调用指定工具并获取结果 |
| `notifications/tools/list_changed` | Server → Client | 工具列表变更通知（推送）|

`tools/list` 的响应结构：

```json
{
  "tools": [
    {
      "name": "read_file",
      "description": "读取指定路径的文件内容",
      "inputSchema": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "文件路径"
          },
          "offset": {
            "type": "integer",
            "description": "读取偏移量",
            "default": 0
          },
          "limit": {
            "type": "integer",
            "description": "读取字节数限制",
            "default": 65536
          }
        },
        "required": ["path"]
      }
    }
  ]
}
```

### 4.2 Resources 原语

Resources 是 MCP 中用于向 AI 提供**只读数据**的机制。与 Tools 不同，Resources 代表的是信息源（如文件内容、配置项），而不是可执行的操作。

| 方法 | 方向 | 说明 |
|------|------|------|
| `resources/list` | Client → Server | 获取所有可用资源的清单 |
| `resources/read` | Client → Server | 读取指定资源的内容 |
| `resources/subscribe` | Client → Server | 订阅资源变更通知 |
| `resources/unsubscribe` | Client → Server | 取消订阅 |
| `notifications/resources/updated` | Server → Client | 资源变更推送 |

`resources/list` 的响应结构：

```json
{
  "resources": [
    {
      "uri": "file:///project/README.md",
      "name": "项目说明文档",
      "description": "项目的 README 文件",
      "mimeType": "text/markdown"
    },
    {
      "uri": "config://app/settings",
      "name": "应用配置",
      "description": "当前应用的配置项",
      "mimeType": "application/json"
    }
  ]
}
```

Resources 的 URI 使用类 URL 的格式：
- `file://` - 文件系统资源
- `config://` - 配置资源
- `memory://` - 内存中的临时资源

### 4.3 Prompts 原语

Prompts 允许 Server 向 Client 提供**可复用的提示模板**。这对于构建领域特定的 Agent 非常有用。

| 方法 | 方向 | 说明 |
|------|------|------|
| `prompts/list` | Client → Server | 获取所有可用提示模板 |
| `prompts/get` | Client → Server | 获取指定提示模板（支持变量插值）|
| `notifications/prompts/list_changed` | Server → Client | 提示列表变更通知 |

`prompts/list` 的响应结构：

```json
{
  "prompts": [
    {
      "name": "code_review",
      "description": "代码审查提示模板",
      "arguments": [
        {
          "name": "language",
          "description": "编程语言",
          "required": true
        },
        {
          "name": "file_path",
          "description": "待审查的文件路径",
          "required": true
        }
      ]
    }
  ]
}
```

调用 `prompts/get` 时：

```json
{
  "name": "code_review",
  "arguments": {
    "language": "rust",
    "file_path": "src/main.rs"
  }
}
```

响应：

```json
{
  "messages": [
    {
      "role": "user",
      "content": "请审查以下 Rust 代码...\n\n```rust\nfn main() {\n    println!(\"Hello\");\n}\n```"
    }
  ]
}
```

### 4.4 Roots 和 Sampling（高级特性）

除了三大核心原语，MCP 还定义了其他辅助机制：

**Roots** 机制允许 Client 向 Server 声明其工作空间的根目录，用于 Server 解析相对路径或进行访问控制：

```json
{
  "roots": [
    { "uri": "file:///home/user/project", "name": "工作区" }
  ]
}
```

**Sampling** 机制允许 Server 向 Client 请求 LLM 采样（即让 AI 生成文本），这是一个反向的数据流——Server 也可以"消费"AI 的能力：

```json
{
  "method": "sampling/createMessage",
  "params": {
    "systemPrompt": "你是一个代码审查助手...",
    "maxTokens": 1024
  }
}
```

## 5. MCP Tool 定义与调用（完整示例）

### 5.1 工具定义

让我们以一个实际的工具定义为例——实现一个"读取目录树"的功能：

```typescript
// TypeScript 类型定义
interface Tool {
  name: string;           // 工具唯一标识符
  description: string;   // 人类可读的描述（LLM 会看到）
  inputSchema: {         // JSON Schema，定义输入参数
    type: "object";
    properties: {
      path: {
        type: "string";
        description: "目录路径";
      };
      maxDepth: {
        type: "integer";
        description: "最大递归深度";
        default: 3;
      };
      includeHidden: {
        type: "boolean";
        description: "是否包含隐藏文件";
        default: false;
      };
    };
    required: ["path"];
  };
}

// MCP Server 返回的 tools/list 结果
const toolsListResult = {
  tools: [
    {
      name: "directory_tree",
      description: "列出指定目录的树形结构，用于了解项目布局",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "目录路径"
          },
          maxDepth: {
            type: "integer",
            description: "最大递归深度 (默认 3)",
            default: 3
          },
          includeHidden: {
            type: "boolean", 
            description: "是否包含隐藏文件 (默认 false)",
            default: false
          }
        },
        required: ["path"]
      }
    },
    {
      name: "grep_search",
      description: "在文件中搜索匹配的文本行",
      inputSchema: {
        type: "object",
        properties: {
          pattern: {
            type: "string",
            description: "正则表达式模式"
          },
          paths: {
            type: "array",
            items: { type: "string" },
            description: "要搜索的文件路径列表"
          },
          caseSensitive: {
            type: "boolean",
            default: false
          },
          contextLines: {
            type: "integer",
            description: "结果周围包含的行数",
            default: 0
          }
        },
        required: ["pattern", "paths"]
      }
    }
  ]
};
```

### 5.2 工具调用

当 AI Agent 决定调用工具时，Host 通过以下流程：

```mermaid
sequenceDiagram
    participant LLM as 大语言模型
    participant Host as MCP Host
    participant Client as MCP Client
    participant Server as MCP Server

    LLM->>Host: 决定调用 directory_tree
    Host->>Client: tools/call { name: "directory_tree", arguments: { path: "/project" } }
    Client->>Server: JSON-RPC Request: tools/call
    Server->>Server: 解析参数，执行实际操作
    Server-->>Client: JSON-RPC Response: { content: [ { type: "text", text: "..." } ] }
    Client-->>Host: 返回工具结果
    Host->>LLM: 将结果作为上下文返回给 LLM
```

`tools/call` 请求格式：

```json
{
  "jsonrpc": "2.0",
  "id": "call-1698765432-042",
  "method": "tools/call",
  "params": {
    "name": "directory_tree",
    "arguments": {
      "path": "/home/user/project",
      "maxDepth": 2,
      "includeHidden": false
    }
  }
}
```

`tools/call` 响应格式（MCP 规定必须返回 `content` 数组）：

```json
{
  "jsonrpc": "2.0",
  "id": "call-1698765432-042",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "project/\n├── src/\n│   ├── main.rs\n│   └── lib.rs\n├── Cargo.toml\n└── README.md"
      }
    ],
    "isError": false
  }
}
```

如果工具执行出错，响应结构如下：

```json
{
  "jsonrpc": "2.0",
  "id": "call-1698765432-043",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Error: path /nonexistent does not exist"
      }
    ],
    "isError": true
  }
}
```

### 5.3 工具调用的错误处理

工具执行过程中可能遇到的错误类型及处理策略：

```python
from enum import Enum
from typing import Any

class ToolError(Enum):
    INVALID_PARAMS = ("InvalidParamsError", -32602, "参数验证失败")
    NOT_FOUND = ("ToolNotFoundError", -32004, "工具不存在")
    EXECUTION_FAILED = ("ToolExecutionError", -32003, "工具执行失败")
    ACCESS_DENIED = ("AccessDeniedError", -32002, "访问被拒绝")
    
    def __init__(self, name: str, code: int, message: str):
        self.name = name
        self.code = code
        self.message = message
    
    def to_jsonrpc_error(self, data: Any = None) -> dict:
        return {
            "jsonrpc": "2.0",
            "error": {
                "code": self.code,
                "message": self.message,
                "data": data
            }
        }

# 使用示例
try:
    result = execute_tool("read_file", {"path": "/etc/shadow"})
except PermissionError:
    raise ToolError.ACCESS_DENIED.to_jsonrpc_error({"path": "/etc/shadow"})
```

## 6. MCP Resources 机制

### 6.1 资源类型

MCP Resources 是一种将外部数据引入 AI 上下文的机制。与 Tools 不同，Resources 强调的是**数据消费**而非**动作执行**。

**文件资源**是最常见的资源类型：

```json
{
  "uri": "file:///home/user/project/src/main.rs",
  "name": "main.rs",
  "description": "Rust 项目入口文件",
  "mimeType": "text/plain"
}
```

**配置资源**用于暴露应用的运行时配置：

```json
{
  "uri": "config://app/logging",
  "name": "日志配置",
  "description": "当前应用的日志级别和输出配置",
  "mimeType": "application/json"
}
```

**模板资源**用于返回预定义的内容片段：

```json
{
  "uri": "template://email/review_request",
  "name": "代码审查请求邮件模板",
  "description": "用于向审查者发送代码审查请求的邮件模板",
  "mimeType": "text/plain"
}
```

### 6.2 资源读取

资源读取通过 `resources/read` 方法进行：

```json
// 请求
{
  "jsonrpc": "2.0",
  "id": "res-read-001",
  "method": "resources/read",
  "params": {
    "uri": "file:///home/user/project/README.md"
  }
}

// 响应
{
  "jsonrpc": "2.0",
  "id": "res-read-001",
  "result": {
    "contents": [
      {
        "uri": "file:///home/user/project/README.md",
        "mimeType": "text/markdown",
        "text": "# Project\n\nThis is a sample project..."
      }
    ]
  }
}
```

注意响应中的 `contents` 是一个数组，这是因为某些资源可能包含多个部分（如一个大文件被分割成多个 chunk）。

### 6.3 资源订阅与变更通知

资源订阅机制允许 Server 在资源内容发生变化时**主动推送**通知给 Client：

```json
// 订阅请求
{
  "jsonrpc": "2.0",
  "id": "sub-001",
  "method": "resources/subscribe",
  "params": {
    "uri": "config://app/settings"
  }
}

// 响应
{
  "jsonrpc": "2.0",
  "id": "sub-001",
  "result": null  // 订阅操作无额外返回
}

// 当配置变更时，Server 推送通知
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": {
    "uri": "config://app/settings"
  }
}
```

这一机制对于监控配置文件变化、Git 仓库更新等场景非常有用。

### 6.4 资源列表分页

当资源数量较多时，`resources/list` 支持游标分页：

```json
// 首次请求
{
  "jsonrpc": "2.0",
  "id": "list-001",
  "method": "resources/list",
  "params": {}
}

// 响应（包含分页信息）
{
  "jsonrpc": "2.0",
  "id": "list-001",
  "result": {
    "resources": [...],
    "nextCursor": "eyJpZCI6MTAwfQ=="
  }
}

// 后续请求（使用游标）
{
  "jsonrpc": "2.0",
  "id": "list-002",
  "method": "resources/list",
  "params": {
    "cursor": "eyJpZCI6MTAwfQ=="
  }
}
```

## 7. MCP Server 实现

### 7.1 TypeScript SDK

TypeScript/Node.js 是 MCP 官方推荐的 Server 开发语言。官方提供了 `@modelcontextprotocol/sdk` 包：

```typescript
// 安装：npm install @modelcontextprotocol/sdk

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// 创建 Server 实例
const server = new McpServer({
  name: "filesystem-server",
  version: "1.0.0",
}, {
  capabilities: {
    tools: {
      listChanged: true,
    },
    resources: {
      subscribe: true,
      listChanged: true,
    },
  },
});

// 注册工具处理器
server.setRequestHandler("tools/list", async () => {
  return {
    tools: [
      {
        name: "read_file",
        description: "读取文件内容",
        inputSchema: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "文件路径",
            },
          },
          required: ["path"],
        },
      },
      {
        name: "write_file",
        description: "写入文件内容",
        inputSchema: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "文件路径",
            },
            content: {
              type: "string",
              description: "文件内容",
            },
          },
          required: ["path", "content"],
        },
      },
    ],
  };
});

server.setRequestHandler("tools/call", async (request) => {
  const { name, arguments: args } = request.params;

  if (name === "read_file") {
    const fs = await import("fs/promises");
    const content = await fs.readFile(args.path, "utf-8");
    return {
      content: [
        {
          type: "text",
          text: content,
        },
      ],
    };
  }

  if (name === "write_file") {
    const fs = await import("fs/promises");
    await fs.writeFile(args.path, args.content);
    return {
      content: [
        {
          type: "text",
          text: `Successfully wrote to ${args.path}`,
        },
      ],
    };
  }

  throw new Error(`Unknown tool: ${name}`);
});

// 注册资源处理器
server.setRequestHandler("resources/list", async () => {
  return {
    resources: [
      {
        uri: "file:///project/README.md",
        name: "README",
        description: "项目说明文档",
        mimeType: "text/markdown",
      },
    ],
  };
});

server.setRequestHandler("resources/read", async (request) => {
  const { uri } = request.params;
  
  if (uri.startsWith("file://")) {
    const fs = await import("fs/promises");
    const filePath = uri.replace("file://", "");
    const content = await fs.readFile(filePath, "utf-8");
    const mimeType = getMimeType(filePath);
    
    return {
      contents: [
        {
          uri,
          mimeType,
          text: content,
        },
      ],
    };
  }
  
  throw new Error(`Unsupported URI scheme: ${uri}`);
});

// 启动服务器
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Filesystem MCP Server started");
}

main().catch(console.error);
```

### 7.2 Python SDK

Python 是数据科学和 AI 领域的主流语言，MCP 也提供了 Python SDK：

```python
# 安装：pip install mcp

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    Tool,
    TextContent,
    Resource,
    GetPromptResult,
    PromptMessage,
)
import asyncio
import json

# 创建 Server 实例
server = Server("filesystem-server")


@server.list_tools()
async def list_tools() -> list[Tool]:
    """列出所有可用工具"""
    return [
        Tool(
            name="read_file",
            description="读取文件内容",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "文件路径",
                    },
                },
                "required": ["path"],
            },
        ),
        Tool(
            name="write_file",
            description="写入文件内容",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "文件路径",
                    },
                    "content": {
                        "type": "string",
                        "description": "文件内容",
                    },
                },
                "required": ["path", "content"],
            },
        ),
        Tool(
            name="list_directory",
            description="列出目录内容",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "目录路径",
                    },
                    "include_hidden": {
                        "type": "boolean",
                        "description": "是否包含隐藏文件",
                        "default": False,
                    },
                },
                "required": ["path"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    """调用工具"""
    if name == "read_file":
        path = arguments["path"]
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            return [TextContent(type="text", text=content)]
        except FileNotFoundError:
            return [TextContent(type="text", text=f"Error: File not found: {path}")]
        except PermissionError:
            return [TextContent(type="text", text=f"Error: Permission denied: {path}")]

    elif name == "write_file":
        path = arguments["path"]
        content = arguments["content"]
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            return [TextContent(type="text", text=f"Successfully wrote to {path}")]
        except Exception as e:
            return [TextContent(type="text", text=f"Error: {str(e)}")]

    elif name == "list_directory":
        import os
        path = arguments["path"]
        include_hidden = arguments.get("include_hidden", False)
        
        try:
            entries = os.listdir(path)
            if not include_hidden:
                entries = [e for e in entries if not e.startswith(".")]
            entries.sort()
            
            result = "\n".join(entries)
            return [TextContent(type="text", text=result)]
        except Exception as e:
            return [TextContent(type="text", text=f"Error: {str(e)}")]

    else:
        raise ValueError(f"Unknown tool: {name}")


@server.list_resources()
async def list_resources() -> list[Resource]:
    """列出所有可用资源"""
    return [
        Resource(
            uri="file:///project/config.json",
            name="项目配置",
            description="项目的配置文件",
            mimeType="application/json",
        ),
    ]


@server.read_resource()
async def read_resource(uri: str) -> str:
    """读取资源内容"""
    if uri.startswith("file://"):
        file_path = uri.replace("file://", "")
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()
    raise ValueError(f"Unsupported URI scheme: {uri}")


async def main():
    """启动服务器"""
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


if __name__ == "__main__":
    asyncio.run(main())
```

### 7.3 SDK 核心抽象

无论使用哪种语言，MCP SDK 的核心抽象都遵循相同的模式：

```mermaid
classDiagram
    class Server {
        +setRequestHandler(method, handler)
        +setNotificationHandler(method, handler)
        +sendNotification(method, params)
        +connect(transport)
    }

    class Transport {
        <<interface>>
        +start()
        +send(message)
        +close()
        +onMessage(handler)
        +onClose(handler)
    }

    class StdioTransport {
        +stdin: ReadableStream
        +stdout: WritableStream
    }

    class WebSocketTransport {
        +socket: WebSocket
    }

    class RequestHandler {
        <<interface>>
        +handle(request): Promise~response~
    }

    Server --> Transport
    Server --> RequestHandler
    StdioTransport --|> Transport
    WebSocketTransport --|> Transport
```

### 7.4 创建自己的 MCP Server

下面是一个更完整的例子——实现一个 Git 操作的 MCP Server：

```typescript
// git-server.ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { SimpleGit, simpleGit } from "simple-git";

const server = new McpServer({
  name: "git-server",
  version: "1.0.0",
});

server.setRequestHandler("tools/list", async () => ({
  tools: [
    {
      name: "git_status",
      description: "获取 Git 工作区状态",
      inputSchema: {
        type: "object",
        properties: {
          repoPath: { type: "string", description: "仓库路径" },
        },
        required: ["repoPath"],
      },
    },
    {
      name: "git_log",
      description: "获取 Git 提交历史",
      inputSchema: {
        type: "object",
        properties: {
          repoPath: { type: "string", description: "仓库路径" },
          maxCount: { type: "integer", description: "最大记录数", default: 20 },
          file: { type: "string", description: "只看某个文件的提交" },
        },
        required: ["repoPath"],
      },
    },
    {
      name: "git_diff",
      description: "获取文件差异",
      inputSchema: {
        type: "object",
        properties: {
          repoPath: { type: "string", description: "仓库路径" },
          file: { type: "string", description: "文件路径（可选）" },
          staged: { type: "boolean", description: "是否显示暂存区差异", default: false },
        },
        required: ["repoPath"],
      },
    },
  ],
}));

server.setRequestHandler("tools/call", async (request) => {
  const { name, arguments: args } = request.params;
  const git: SimpleGit = simpleGit(args.repoPath);

  if (name === "git_status") {
    const status = await git.status();
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(status, null, 2),
        },
      ],
    };
  }

  if (name === "git_log") {
    const log = await git.log({
      maxCount: args.maxCount || 20,
      file: args.file,
    });
    return {
      content: [
        {
          type: "text",
          text: log.all
            .map(
              (commit) =>
                `${commit.hash.slice(0, 7)} | ${commit.date} | ${commit.message} (${commit.author_name})`
            )
            .join("\n"),
        },
      ],
    };
  }

  if (name === "git_diff") {
    const diff = args.staged
      ? await git.diff(["--cached"])
      : args.file
        ? await git.diff(["--", args.file])
        : await git.diff();
    return {
      content: [{ type: "text", text: diff || "(no changes)" }],
    };
  }

  throw new Error(`Unknown tool: ${name}`);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
```

## 8. MCP Security

### 8.1 威胁模型

MCP 作为 AI Agent 访问外部资源的桥梁，面临以下安全威胁：

| 威胁类型 | 描述 | 示例 |
|---------|------|------|
| **工具注入** | 恶意构造的工具调用请求 | 通过 `path: "../../../etc/passwd"` 遍历目录 |
| **资源泄露** | 未授权访问敏感资源 | 读取 `/home/user/.ssh/id_rsa` |
| **权限提升** | 工具调用超出授权范围 | 读取配置的工具尝试执行写操作 |
| **提示注入** | 恶意内容注入 AI 上下文 | 在文件内容中注入恶意提示 |
| **供应链攻击** | 不可信的 MCP Server 包含恶意代码 | 使用来路不明的 Server |
| **通信窃听** | 传输层数据被窃取 | stdio 在某些环境下可能被日志记录 |

### 8.2 认证机制

MCP 协议本身不强制规定认证方式，但推荐使用以下机制：

**MCP 握手认证**：
```typescript
// 在初始化阶段交换认证信息
const initRequest = {
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {
      tools: { listChanged: true },
    },
    clientInfo: {
      name: "gsd2",
      version: "1.0.0",
    },
    // 认证信息（通过安全传输层传递）
    auth: {
      type: "bearer",
      token: process.env.MCP_AUTH_TOKEN,
    },
  },
};
```

**OAuth 2.0 认证流程**（适用于远程 MCP Server）：
```mermaid
sequenceDiagram
    participant Host
    participant AuthServer as 认证服务器
    participant Server as MCP Server

    Host->>AuthServer: 请求访问令牌
    AuthServer-->>Host: 颁发访问令牌
    Host->>Server: initialize + Bearer Token
    Server->>Server: 验证令牌
    Server-->>Host: 初始化成功
```

### 8.3 授权机制

MCP 建议实现基于** Capabilities 的授权模型**：

```typescript
// 权限策略定义
interface PermissionPolicy {
  // 工具调用权限
  allowTools?: string[];       // 允许调用的工具（glob 模式）
  denyTools?: string[];        // 明确拒绝的工具
  
  // 资源访问权限
  allowResources?: string[];   // 允许访问的资源 URI（glob 模式）
  denyResources?: string[];    // 明确拒绝的资源 URI
  
  // 操作类型权限
  readOnly?: boolean;          // 只读模式（禁止写操作）
  
  // 路径限制（文件系统场景）
  allowedPaths?: string[];     // 允许操作的路径前缀
  deniedPaths?: string[];      // 明确拒绝的路径
}

// 示例：只读文件系统策略
const readonlyPolicy: PermissionPolicy = {
  readOnly: true,
  allowTools: ["read_file", "list_directory", "grep_search"],
  denyTools: ["write_file", "delete_file", "execute_command"],
  allowedPaths: ["/home/user/project"],
  deniedPaths: ["/etc", "/root", "/home/*/.ssh"],
};

// 权限检查实现
function checkPermission(policy: PermissionPolicy, tool: string, args: any): boolean {
  // 检查工具是否在拒绝列表中
  if (policy.denyTools?.some((pattern) => globMatch(pattern, tool))) {
    return false;
  }
  
  // 检查工具是否在允许列表中
  if (policy.allowTools && !policy.allowTools.some((pattern) => globMatch(pattern, tool))) {
    return false;
  }
  
  // 路径检查（针对文件系统工具）
  if (args.path && policy.allowedPaths) {
    const normalizedPath = path.normalize(args.path);
    const isAllowed = policy.allowedPaths.some((prefix) =>
      normalizedPath.startsWith(prefix)
    );
    if (!isAllowed) return false;
  }
  
  if (args.path && policy.deniedPaths) {
    const normalizedPath = path.normalize(args.path);
    const isDenied = policy.deniedPaths.some((prefix) =>
      normalizedPath.startsWith(prefix)
    );
    if (isDenied) return false;
  }
  
  return true;
}
```

### 8.4 输入验证

所有来自 AI 的输入都必须经过严格验证。MCP 使用 JSON Schema 进行参数验证：

```typescript
import { z } from "zod";

// 使用 Zod 定义更严格的验证
const ReadFileSchema = z.object({
  path: z.string()
    .min(1, "路径不能为空")
    .refine(
      (p) => !p.includes(".."),
      "禁止使用 .. 路径遍历"
    )
    .refine(
      (p) => !p.startsWith("/etc") && !p.startsWith("/root"),
      "禁止访问系统敏感目录"
    ),
  offset: z.number().int().min(0).default(0),
  limit: z.number().int().min(1).max(1024 * 1024).default(65536),
});

const WriteFileSchema = z.object({
  path: z.string()
    .min(1)
    .refine(
      (p) => !p.includes(".."),
      "禁止路径遍历"
    )
    .refine(
      (p) => !p.startsWith("/etc") && !p.startsWith("/root") && !p.startsWith("/usr"),
      "禁止写入系统目录"
    ),
  content: z.string()
    .max(10 * 1024 * 1024, "文件大小不能超过 10MB"),
  mode: z.enum(["overwrite", "append"]).default("overwrite"),
});

// 在工具处理器中使用
server.setRequestHandler("tools/call", async (request) => {
  const { name, arguments: args } = request.params;
  
  if (name === "read_file") {
    const parsed = ReadFileSchema.safeParse(args);
    if (!parsed.success) {
      return {
        content: [{ type: "text", text: `Validation error: ${parsed.error.message}` }],
        isError: true,
      };
    }
    // 执行实际读取...
  }
  
  if (name === "write_file") {
    const parsed = WriteFileSchema.safeParse(args);
    if (!parsed.success) {
      return {
        content: [{ type: "text", text: `Validation error: ${parsed.error.message}` }],
        isError: true,
      };
    }
    // 执行实际写入...
  }
  
  throw new Error(`Unknown tool: ${name}`);
});
```

### 8.5 安全最佳实践

```
┌──────────────────────────────────────────────────────────────┐
│                     MCP Security Checklist                     │
├──────────────────────────────────────────────────────────────┤
│  □ 所有 MCP Server 必须通过安全传输层 (TLS/mTLS) 连接           │
│  □ 使用 OAuth 2.0 或 API Key 进行认证                         │
│  □ 实施最小权限原则 - 每个 Server 只授予必要的权限              │
│  □ 路径操作必须进行规范化并验证，禁止 .. 遍历                  │
│  □ 文件写入必须验证目标路径，禁止覆盖系统文件                   │
│  □ 命令执行必须使用白名单，禁止 shell 注入                      │
│  □ 数据库操作必须使用参数化查询，防止 SQL 注入                  │
│  □ AI 输出的文件内容需要扫描提示注入攻击                        │
│  □ 限制文件大小和操作频率，防止资源耗尽                         │
│  □ 记录所有操作审计日志                                         │
│  □ MCP Server 应该以低权限用户身份运行                          │
└──────────────────────────────────────────────────────────────┘
```

## 9. 现有 MCP Server 生态

### 9.1 官方及社区生态概览

截至 2026 年初，MCP 生态已形成相当规模的 Server 库。以下是主要分类：

| 分类 | 代表 Server | 说明 |
|------|------------|------|
| **文件系统** | `filesystem`, `mcp-local-filesystem` | 本地文件读写、目录操作 |
| **Git** | `git`, `github`, `gitlab` | Git 操作、GitHub API |
| **数据库** | `postgres`, `mysql`, `sqlite` | 数据库查询和操作 |
| **Slack** | `slack` | Slack 消息发送、频道管理 |
| **GitHub** | `github` | PR、Issue、Actions 管理 |
| **搜索** | `google-search`, `duckduckgo` | Web 搜索 |
| **向量数据库** | `pinecone`, `qdrant`, `chroma` | 语义搜索、RAG |
| **S3** | `s3` | AWS S3 对象存储操作 |
| **Postman** | `postman` | API 测试 |
| **EverArt** | `everart` | AI 图像生成 |
| **AWS** | `aws-kb-retrieval` | AWS 知识库检索 |

### 9.2 典型 Server 实现示例

**filesystem-server**（文件系统操作）：
```json
{
  "name": "filesystem",
  "description": "提供本地文件系统访问能力",
  "tools": [
    { "name": "read_file", "description": "读取文件" },
    { "name": "write_file", "description": "写入文件" },
    { "name": "list_directory", "description": "列出目录" },
    { "name": "create_directory", "description": "创建目录" },
    { "name": "move_file", "description": "移动文件" },
    { "name": "delete_file", "description": "删除文件" },
    { "name": "search_files", "description": "搜索文件" }
  ]
}
```

**github-server**（GitHub API 集成）：
```json
{
  "name": "github",
  "description": "GitHub API 集成",
  "tools": [
    { "name": "create_pull_request", "description": "创建 PR" },
    { "name": "get_pull_request", "description": "获取 PR 详情" },
    { "name": "merge_pull_request", "description": "合并 PR" },
    { "name": "create_issue", "description": "创建 Issue" },
    { "name": "list_issues", "description": "列出 Issue" },
    { "name": "add_issue_comment", "description": "评论 Issue" },
    { "name": "get_file_content", "description": "获取文件内容" },
    { "name": "push_files", "description": "推送文件" }
  ]
}
```

**postgres-server**（PostgreSQL 数据库）：
```json
{
  "name": "postgres",
  "description": "PostgreSQL 数据库操作",
  "tools": [
    { "name": "query", "description": "执行 SQL 查询", "inputSchema": {
      "properties": {
        "sql": { "type": "string", "description": "SQL 查询语句" }
      },
      "required": ["sql"]
    }},
    { "name": "list_tables", "description": "列出所有表" },
    { "name": "describe_table", "description": "描述表结构" }
  ]
}
```

### 9.3 Server 发现与配置

MCP 没有中心化的 Server 注册中心，而是通过本地配置文件发现 Server：

```json
// ~/.config/mcp/servers.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/project"],
      "env": {}
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "ghp_xxxxxxxxxxxx"
      }
    },
    "postgres": {
      "command": "uvx",
      "args": ["mcp-server-postgres", "--host", "localhost", "--port", "5432"],
      "env": {
        "DATABASE_URL": "postgresql://user:pass@localhost/mydb"
      }
    },
    "slack": {
      "command": "uvx",
      "args": ["mcp-server-slack"],
      "env": {
        "SLACK_BOT_TOKEN": "xoxb-xxxx",
        "SLACK_TEAM_ID": "T0123456789"
      }
    }
  }
}
```

### 9.4 Server 生态对比

| Server | 语言 | 传输层 | 维护方 | 成熟度 |
|--------|------|--------|--------|--------|
| `server-filesystem` | TypeScript | stdio | Anthropic (官方) | ⭐⭐⭐⭐⭐ |
| `server-github` | TypeScript | stdio | Anthropic (官方) | ⭐⭐⭐⭐⭐ |
| `server-postgres` | Python | stdio |社区 | ⭐⭐⭐⭐ |
| `server-slack` | Python | stdio | 社区 | ⭐⭐⭐ |
| `server-aws-kb` | Python | stdio | AWS (官方) | ⭐⭐⭐⭐ |
| `server-gitlab` | TypeScript | stdio | 社区 | ⭐⭐⭐ |

## 10. MCP 集成到 gsd2 的方案

### 10.1 gsd2 现有架构分析

gsd2 是从 Claude Code 插件演进到基于 Pi.ai 框架的独立 Code Agent。其现有架构如下：

```
┌─────────────────────────────────────────────┐
│              gsd2 Host 进程                   │
│  ┌─────────────────────────────────────┐    │
│  │         Pi.ai 框架核心               │    │
│  │  ┌─────────┐  ┌──────────────┐     │    │
│  │  │ LLM API │  │ Session Mgr  │     │    │
│  │  └─────────┘  └──────────────┘     │    │
│  └──────────────────┬──────────────────┘    │
│                     │                       │
│  ┌──────────────────▼──────────────────┐    │
│  │        工具调用层 (原有)              │    │
│  │  ┌───────┐ ┌───────┐ ┌─────────┐    │    │
│  │  │ Shell │ │Git API│ │ File I/O│    │    │
│  │  └───────┘ └───────┘ └─────────┘    │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

现有架构中，工具调用是**硬编码**的：每个工具（如 Shell、Git、File I/O）都有对应的 API 调用，缺乏标准化抽象。

### 10.2 集成目标

gsd2 集成 MCP 的目标：

1. **标准化接口**：将现有工具调用重构为符合 MCP 协议的实现
2. **可扩展性**：支持动态加载 MCP Server，无缝接入社区生态
3. **双向通信**：利用 MCP 的 Notifications 机制实现 Server 主动推送
4. **资源抽象**：将项目文件、配置通过 MCP Resources 暴露给 AI

### 10.3 集成方案设计

**方案一：渐进式集成（推荐）**

采用适配器模式，在不破坏现有架构的情况下引入 MCP 支持：

```
┌─────────────────────────────────────────────────────┐
│                  gsd2 Host 进程                       │
│  ┌───────────────────────────────────────────────┐  │
│  │              Pi.ai 框架核心                    │  │
│  │  ┌─────────┐  ┌──────────────┐               │  │
│  │  │ LLM API │  │ Session Mgr  │               │  │
│  │  └─────────┘  └──────────────┘               │  │
│  └──────────────────────┬────────────────────────┘  │
│                         │                           │
│  ┌──────────────────────▼────────────────────────┐  │
│  │         MCP 适配层 (新增)                       │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │         MCP Client Manager              │  │  │
│  │  │  - Server 注册/注销                      │  │  │
│  │  │  - 连接生命周期管理                       │  │  │
│  │  │  - 请求路由与响应匹配                     │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │         Legacy Adapter                  │  │  │
│  │  │  - 将原有 Shell/Git/File 封装为 MCP Tool │  │  │
│  │  │  - 保持向后兼容                          │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └──────────────────────┬────────────────────────┘  │
│                         │                           │
│     ┌───────────────────┼───────────────────┐       │
│     ▼                   ▼                   ▼       │
│ ┌─────────┐       ┌─────────────┐    ┌───────────┐  │
│ │ Local   │       │ 社区 MCP    │    │ gsd2      │  │
│ │ MCP     │       │ Servers     │    │ Built-in  │  │
│ │ Server  │       │ (GitHub,    │    │ Server    │  │
│ │         │       │  Slack...)  │    │ (Shell,   │  │
│ │         │       │             │    │  Git...)  │  │
│ └─────────┘       └─────────────┘    └───────────┘  │
└─────────────────────────────────────────────────────┘
```

**方案二：完全重构**

将 gsd2 完全迁移到 MCP 架构，所有工具通过 MCP Server 提供。这种方案适合长期演进，但短期内迁移成本较高。

### 10.4 关键实现细节

**gsd2 MCP Client Manager**：

```typescript
// gsd2-mcp/src/client/manager.ts

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventEmitter } from "events";

interface ServerConfig {
  name: string;
  command: string;
  args: string[];
  env?: Record<string, string>;
  enabled?: boolean;
}

interface ToolDefinition {
  name: string;
  serverName: string;
  description: string;
  inputSchema: object;
}

class McpClientManager extends EventEmitter {
  private clients: Map<string, Client> = new Map();
  private servers: Map<string, ServerConfig> = new Map();
  private tools: Map<string, ToolDefinition> = new Map();

  // 注册 MCP Server
  async registerServer(config: ServerConfig): Promise<void> {
    this.servers.set(config.name, config);
  }

  // 启动所有已注册的 Server
  async startAll(): Promise<void> {
    for (const [name, config] of this.servers) {
      if (config.enabled !== false) {
        await this.startServer(name);
      }
    }
  }

  // 启动单个 Server
  async startServer(name: string): Promise<void> {
    const config = this.servers.get(name);
    if (!config) {
      throw new Error(`Server not found: ${name}`);
    }

    if (this.clients.has(name)) {
      console.log(`Server ${name} already running`);
      return;
    }

    const transport = new StdioClientTransport({
      command: config.command,
      args: config.args,
      env: config.env,
    });

    const client = new Client(
      {
        name: `gsd2-${name}`,
        version: "1.0.0",
      },
      {
        capabilities: {
          tools: {},
          resources: {},
        },
      }
    );

    await client.connect(transport);
    this.clients.set(name, client);

    // 订阅工具列表变更
    await this.syncTools(name, client);

    // 监听变更通知
    client.setNotificationHandler(
      "notifications/tools/list_changed",
      async () => {
        await this.syncTools(name, client);
        this.emit("tools-changed");
      }
    );

    this.emit("server-started", name);
    console.log(`MCP Server ${name} started`);
  }

  // 同步工具列表
  private async syncTools(serverName: string, client: Client): Promise<void> {
    const response = await client.request(
      { method: "tools/list" },
      { method: "tools/list", params: {} }
    );

    for (const tool of response.tools) {
      const key = `${serverName}:${tool.name}`;
      this.tools.set(key, {
        name: tool.name,
        serverName,
        description: tool.description,
        inputSchema: tool.inputSchema,
      });
    }
  }

  // 调用工具
  async callTool(
    serverName: string,
    toolName: string,
    arguments_: Record<string, unknown>
  ): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
    const client = this.clients.get(serverName);
    if (!client) {
      throw new Error(`Server not running: ${serverName}`);
    }

    const response = await client.request(
      {
        method: "tools/call",
        params: {
          name: toolName,
          arguments: arguments_,
        },
      },
      {
        jsonrpc: "2.0",
        id: `gsd2-${Date.now()}`,
        method: "tools/call",
        params: {
          name: toolName,
          arguments: arguments_,
        },
      }
    );

    return response as { content: Array<{ type: string; text: string }>; isError?: boolean };
  }

  // 获取所有工具
  listTools(): ToolDefinition[] {
    return Array.from(this.tools.values());
  }

  // 停止 Server
  async stopServer(name: string): Promise<void> {
    const client = this.clients.get(name);
    if (client) {
      await client.close();
      this.clients.delete(name);
      
      // 清理该 Server 的工具
      for (const [key, tool] of this.tools) {
        if (tool.serverName === name) {
          this.tools.delete(key);
        }
      }
      
      this.emit("server-stopped", name);
    }
  }

  // 停止所有 Server
  async stopAll(): Promise<void> {
    for (const name of this.clients.keys()) {
      await this.stopServer(name);
    }
  }
}

export { McpClientManager, ServerConfig, ToolDefinition };
```

**gsd2 内置 MCP Server 实现**：

```typescript
// gsd2-mcp/src/server/builtin.ts

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

export function createBuiltinServer(workspacePath: string): McpServer {
  const server = new McpServer({
    name: "gsd2-builtin",
    version: "1.0.0",
  });

  // Shell 执行工具
  server.setRequestHandler("tools/list", async () => ({
    tools: [
      {
        name: "shell",
        description: "执行 Shell 命令",
        inputSchema: {
          type: "object",
          properties: {
            command: {
              type: "string",
              description: "要执行的命令",
            },
            cwd: {
              type: "string",
              description: "工作目录",
              default: workspacePath,
            },
            timeout: {
              type: "integer",
              description: "超时时间（毫秒）",
              default: 30000,
            },
          },
          required: ["command"],
        },
      },
      {
        name: "read_file",
        description: "读取文件内容",
        inputSchema: {
          type: "object",
          properties: {
            path: { type: "string", description: "文件路径" },
            offset: { type: "integer", default: 0 },
            limit: { type: "integer", default: 65536 },
          },
          required: ["path"],
        },
      },
      {
        name: "write_file",
        description: "写入文件内容",
        inputSchema: {
          type: "object",
          properties: {
            path: { type: "string", description: "文件路径" },
            content: { type: "string", description: "文件内容" },
            mode: { type: "string", enum: ["overwrite", "append"], default: "overwrite" },
          },
          required: ["path", "content"],
        },
      },
    ],
  }));

  server.setRequestHandler("tools/call", async (request) => {
    const { name, arguments: args } = request.params;

    if (name === "shell") {
      try {
        const { stdout, stderr } = await execAsync(args.command, {
          cwd: args.cwd || workspacePath,
          timeout: args.timeout || 30000,
        });

        return {
          content: [
            {
              type: "text",
              text: stdout + (stderr ? `\nSTDERR:\n${stderr}` : ""),
            },
          ],
        };
      } catch (error: any) {
        return {
          content: [{ type: "text", text: `Error: ${error.message}` }],
          isError: true,
        };
      }
    }

    if (name === "read_file") {
      const fs = await import("fs/promises");
      const content = await fs.readFile(args.path, "utf-8");
      return {
        content: [{ type: "text", text: content }],
      };
    }

    if (name === "write_file") {
      const fs = await import("fs/promises");
      const mode = args.mode || "overwrite";
      if (mode === "append") {
        await fs.appendFile(args.path, args.content);
      } else {
        await fs.writeFile(args.path, args.content);
      }
      return {
        content: [{ type: "text", text: `Written to ${args.path}` }],
      };
    }

    throw new Error(`Unknown tool: ${name}`);
  });

  return server;
}

// 启动内置 Server
export async function startBuiltinServer(workspacePath: string): Promise<void> {
  const server = createBuiltinServer(workspacePath);
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
```

**gsd2 配置文件**：

```json
// gsd2-mcp/config/servers.json
{
  "mcpServers": {
    "gsd2-builtin": {
      "type": "builtin",
      "enabled": true,
      "config": {
        "workspacePath": "/home/user/gsd2-workspace"
      }
    },
    "filesystem": {
      "type": "npm",
      "package": "@modelcontextprotocol/server-filesystem",
      "args": ["/home/user/gsd2-workspace"],
      "enabled": true
    },
    "github": {
      "type": "npm",
      "package": "@modelcontextprotocol/server-github",
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      },
      "enabled": false
    },
    "postgres": {
      "type": "pip",
      "package": "mcp-server-postgres",
      "args": ["--host", "localhost", "--port", "5432"],
      "env": {
        "DATABASE_URL": "${DATABASE_URL}"
      },
      "enabled": false
    }
  }
}
```

### 10.5 集成路线图

```
阶段一（v2.1）：基础设施
├── 引入 MCP SDK 依赖
├── 实现 McpClientManager
├── 配置加载与验证
└── 基础日志与错误处理

阶段二（v2.2）：内置 Server
├── 实现 gsd2-builtin MCP Server
├── Shell/Git/File 工具迁移
└── 资源订阅机制

阶段三（v2.3）：外部 Server
├── 接入 filesystem server
├── 接入 github server
└── Server 热插拔支持

阶段四（v2.4）：高级特性
├── MCP 安全策略引擎
├── 社区 Server 发现机制
└── 性能监控与优化
```

### 10.6 注意事项与已知限制

| 问题 | 说明 | 应对方案 |
|------|------|----------|
| **stdio 调试困难** | stdio 传输难以在运行时调试 | 使用 MCP Inspector 或添加 debug 日志 |
| **Server 进程管理** | stdio Server 崩溃不会自动重启 | 在 Client Manager 中实现进程监控 |
| **版本兼容性** | 不同版本的 MCP 协议可能不兼容 | 严格锁定 protocolVersion |
| **工具数量膨胀** | 接入过多 Server 导致工具爆炸 | 实施按需加载和工具分组 |
| **资源竞争** | 多个 Server 同时访问同一文件 | 依赖底层文件系统权限控制 |

## 总结

MCP（Model Context Protocol）作为 AI Agent 与外部工具之间的标准化通信协议，填补了 AI 应用生态中的关键空白。通过 Host/Client/Server 三层架构、JSON-RPC 2.0 传输层、以及工具/资源/提示三类核心原语，MCP 为 AI 应用的工具集成提供了完整的技术基础。

gsd2 作为 Code Agent 领域的探索者，通过渐进式集成 MCP，可以在保持向后兼容的同时，显著提升工具调用的标准化程度和可扩展性。随着 MCP 生态的持续发展，预计将有更多高质量的 Server 实现涌现，gsd2 可以通过配置化方式无缝接入这些能力。

---

**相关资源**：
- MCP 官方规范：https://modelcontextprotocol.io
- MCP SDK (TypeScript)：https://github.com/modelcontextprotocol/typescript-sdk
- MCP SDK (Python)：https://github.com/modelcontextprotocol/python-sdk
- gsd2 项目仓库：https://github.com/pi-ai/gsd2
