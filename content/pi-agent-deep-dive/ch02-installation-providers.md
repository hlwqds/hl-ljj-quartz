---
title: "Pi Agent 深度探索（二）：安装、认证、Provider 与模型配置"
date: 2026-06-12 00:20:00
description: "用发布包快速开始，用源码工作区跟踪 main，并理解 Pi 的认证与模型解析路径"
tags: [pi-agent, coding-agent, provider, llm, nodejs]
---

# Pi Agent 深度探索（二）：安装、认证、Provider 与模型配置

> [!info] 源码基线
> 本文校验于 2026-06-12，基于 `earendil-works/pi` 的 `main` 分支提交
> `1da903983ad72c60995507e813a00bb2bd6faf09`。该快照的四个包版本均为 `0.79.1`，
> Node.js 要求为 `>=22.19.0`。

## 先选择使用路径

本系列采用双轨方式：

| 路径       | 适合场景                       | 优点                      | 注意事项                   |
| ---------- | ------------------------------ | ------------------------- | -------------------------- |
| npm 发布包 | 日常使用、先体验功能           | 安装简单、版本明确        | 与 `main` 可能存在差异     |
| 克隆源码   | 源码阅读、修改实验、跟踪新行为 | 实现与文章 SHA 可一一对应 | 需要构建，API 可能持续变化 |

前五章以使用行为为主；进入源码篇后，建议切换到源码工作区。

## 环境要求

当前快照的所有核心包都声明：

```json
{
  "engines": {
    "node": ">=22.19.0"
  }
}
```

先检查环境：

```bash
node --version
npm --version
git --version
```

本系列第一阶段实验提供一个只读检查脚本，不会安装包、执行登录或修改用户配置。

来源：[coding-agent package.json](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/package.json)

## 路径一：安装发布包

官方 Quickstart 当前推荐：

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

`--ignore-scripts` 禁止依赖安装阶段执行 lifecycle scripts。Pi 的正常 npm 安装不依赖这些脚本。

验证：

```bash
command -v pi
pi --version
pi --help
```

然后在目标项目目录启动：

```bash
cd /path/to/project
pi
```

如果不希望全局安装，也可以用 npm 的临时执行方式先检查 CLI：

```bash
npm exec --yes --package=@earendil-works/pi-coding-agent -- pi --version
```

临时执行仍会下载依赖到 npm 缓存，只是不把 `pi` 作为全局命令长期安装。

官方安装说明：
[Quickstart](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs/quickstart.md)。

## 路径二：从源码运行

要让源码和本文完全对应，固定到本文 SHA：

```bash
git clone https://github.com/earendil-works/pi.git
cd pi
git checkout 1da903983ad72c60995507e813a00bb2bd6faf09
npm install --ignore-scripts
npm run build
./pi-test.sh
```

若要跟踪最新 `main`，不要执行 `git checkout <sha>`，但应记录当时的：

```bash
git rev-parse HEAD
```

官方开发流程使用根工作区构建全部包，并通过 `./pi-test.sh` 从源码启动 Pi。
这条路径适合后续修改 `packages/agent` 或 `packages/coding-agent` 后立即验证。

来源：[仓库 Development](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/README.md#development)

## 认证方式不是只有 API Key

Pi 当前把认证大致分为四类：

| 类型             | 典型方式                    | 适合场景                    |
| ---------------- | --------------------------- | --------------------------- |
| 订阅登录         | 交互模式执行 `/login`       | Claude、Codex、Copilot 订阅 |
| 环境变量 API Key | `ANTHROPIC_API_KEY` 等      | 本地 Shell、CI、临时会话    |
| Auth File        | `/login` 后写入 `auth.json` | 本机长期使用                |
| 云凭据链         | AWS Profile、Google ADC 等  | 企业云环境                  |

### 订阅登录

启动 Pi 后执行：

```text
/login
```

当前内置订阅登录包括 Claude Pro/Max、ChatGPT Plus/Pro 的 Codex 接入和 GitHub Copilot。
OAuth Token 会保存在 `~/.pi/agent/auth.json`，并在需要时刷新。

### 环境变量

例如：

```bash
export ANTHROPIC_API_KEY="your-key"
pi
```

常见变量包括：

```text
ANTHROPIC_API_KEY
OPENAI_API_KEY
GEMINI_API_KEY
MISTRAL_API_KEY
DEEPSEEK_API_KEY
AWS_PROFILE
GOOGLE_APPLICATION_CREDENTIALS
```

不要把真实密钥写进 Git 仓库、文章示例或共享 Session。

### Auth File

Pi 可以把 API Key 或 OAuth 凭据保存在：

```text
~/.pi/agent/auth.json
```

官方实现会以用户读写权限创建该文件。凭据解析优先级为：

```text
--api-key
  > auth.json
  > 环境变量
  > models.json 中的自定义 Provider Key
```

完整说明：
[Providers](https://github.com/earendil-works/pi/blob/1da903983ad72c60995507e813a00bb2bd6faf09/packages/coding-agent/docs/providers.md)。

## Provider 与 Model 是两层选择

Provider 决定请求发往哪个服务以及如何认证；Model 决定该 Provider 下使用哪个模型。

命令行可以显式指定：

```bash
pi --provider anthropic --model claude-sonnet-4-5
pi --provider openai --model gpt-5.1
pi --model openai/gpt-5.1
```

交互模式中：

```text
/model
```

也可以使用：

- `Ctrl+L`：打开模型选择器；
- `Ctrl+P` / `Shift+Ctrl+P`：在 scoped models 中前后切换；
- `Shift+Tab`：切换 thinking level。

列出当前可识别模型：

```bash
pi --list-models
pi --list-models sonnet
```

## 自定义与本地 Provider

对于 Ollama、LM Studio、vLLM 或兼容 OpenAI/Anthropic/Google API 的服务，可以通过
`models.json` 声明 Provider 和模型。若认证或协议行为更特殊，则使用 Extension 注册
自定义 Provider。

这里应区分两种情况：

```text
协议兼容，只是 endpoint/model 不同 -> models.json
需要新协议、OAuth 或请求转换     -> Extension
```

本系列第 27 章会专门实现自定义 Provider。

## 最小诊断路径

### 1. 检查 CLI 是否正确

```bash
command -v pi
pi --version
pi --help
```

若命令不存在，检查全局 npm bin 目录是否在 `PATH`：

```bash
npm prefix -g
npm bin -g 2>/dev/null || true
```

### 2. 检查模型是否可见

```bash
pi --list-models
```

“能列出模型”不表示认证一定有效，只能说明模型注册与筛选路径工作。

### 3. 用无工具、无 Session 的一次性请求缩小范围

```bash
pi --no-tools --no-session -p "Reply with OK"
```

这一步仍需要有效凭据，但排除了工具执行和 Session 持久化问题。

### 4. 显式指定 Provider 与 Model

```bash
pi \
  --provider anthropic \
  --model claude-sonnet-4-5 \
  --no-tools \
  --no-session \
  -p "Reply with OK"
```

如果默认模型解析失败，显式参数有助于区分“认证失败”和“模型选择失败”。

### 5. 检查配置目录覆盖

以下变量会改变 Pi 查找配置或 Session 的位置：

```text
PI_CODING_AGENT_DIR
PI_CODING_AGENT_SESSION_DIR
PI_PACKAGE_DIR
```

排障时先确认它们是否被 Shell、容器或启动脚本设置。

## 安装后先做安全检查

1. 在有 Git 状态或文件快照的测试仓库启动；
2. 不要一开始就在 `$HOME`、生产目录或挂载大量凭据的容器中运行；
3. 对陌生项目的本地 Extension 和设置保持不信任；
4. 初次体验可限制为只读工具：

```bash
pi --tools read,grep,find,ls
```

5. 自动化模式中显式决定项目 Trust，不依赖交互弹窗。

## 卸载与残留数据

全局 npm 安装可用：

```bash
npm uninstall -g @earendil-works/pi-coding-agent
```

卸载 CLI 不会自动删除 `~/.pi/agent/` 中的设置、凭据、Session 和已安装 Package。
删除这些数据属于单独操作，执行前应先检查是否需要备份。

## 本章小结

日常使用优先选择发布包；源码阅读和修改实验使用固定 SHA 的源码工作区。认证、Provider
和 Model 是相互关联但不同的三层：先确定凭据来源，再确定服务，再确定模型。

下一章：[[ch03-tui-modes-queue|TUI、运行模式、快捷键与消息队列]]
