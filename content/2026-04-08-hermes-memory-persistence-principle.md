---
title: Hermes 持久化内存原理分析
date: 2026-04-08 22:00:00
tags: [Hermes, Memory, Architecture]
description: 深入分析 Hermes Agent 的持久化内存机制
---

# Hermes 持久化内存原理分析

## 概述

Hermes Agent 的持久化内存是通过 **文件系统 + 双存储设计** 实现的。核心文件位于 `~/.hermes/memories/` 目录。

## 存储结构

```
~/.hermes/memories/
├── MEMORY.md   # 代理的个人笔记
└── USER.md     # 用户画像信息
```

两个文件采用相同的格式，用 `§` (section sign) 作为条目分隔符。

## 字符限制

| 存储 | 限制 | 用途 |
|------|------|------|
| MEMORY.md | 2200 chars | 环境事实、项目规范、工具习惯、学到的可复用方法 |
| USER.md | 1375 chars | 用户偏好、沟通风格、工作流习惯 |

## Frozen Snapshot 模式

Hermes 采用 **写时持久化 + 读时快照** 的设计：

```
会话开始 → 加载文件 → 冻结快照 → 注入系统提示
                ↓
        会话中写入 → 立即持久化到磁盘
                ↓
        但不影响当前会话的系统提示（保持 prefix cache 稳定）

会话结束 → 下次会话重新加载 → 新的快照
```

**关键点**：
- 系统提示词在会话启动时冻结一次
- 会话中的写入立即持久化到磁盘
- 工具响应总是反映最新的内存状态
- 下一会话开始时自动刷新快照

## 原子写入实现

```python
# 使用 temp file + os.replace() 实现原子写入
fd, tmp_path = tempfile.mkstemp(dir=path.parent, suffix=".tmp", prefix=".mem_")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(content)
    os.fsync(f.fileno())  # 确保写入磁盘
os.replace(tmp_path, path)  # 原子替换
```

**为什么不用 open("w") + flock？**

因为 `open("w")` 会在获取锁之前就截断文件，导致并发读取者可能看到空文件。原子 rename 保证了读者要么看到旧文件，要么看到新文件，不会看到截断状态。

## 并发安全

使用 `fcntl.flock` 实现文件锁：

```python
@contextmanager
def _file_lock(path: Path):
    lock_path = path.with_suffix(path.suffix + ".lock")
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)  # 排他锁
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()
```

注意：使用独立的 `.lock` 文件而不是在目标文件上加锁，这样读取操作（无锁）可以并发进行。

## MemoryProvider 架构

```
MemoryManager
├── BuiltinMemoryProvider (始终启用，不可移除)
└── ExternalMemoryProvider (可选，但只能同时启用一个)
    ├── Honcho
    ├── Hindsight
    ├── Mem0
    └── ...
```

### 内置 Provider

`BuiltinMemoryProvider` 是始终运行的内置实现，提供 `memory` 工具：

| 操作 | 说明 |
|------|------|
| add | 添加新条目 |
| replace | 查找包含 old_text 的条目并替换 |
| remove | 查找包含 old_text 的条目并删除 |

### 外部 Provider

外部 Provider 通过插件机制接入，扩展记忆能力。同一时间只能启用一个外部 Provider，避免工具 schema 膨胀和后端冲突。

### Lifecycle Hooks

```python
class MemoryProvider:
    def initialize(self, session_id, **kwargs)      # 连接/创建资源
    def system_prompt_block(self) -> str            # 静态提示词块
    def prefetch(self, query) -> str                # 下一轮前召回
    def sync_turn(self, user, assistant)            # 每轮后异步写入
    def get_tool_schemas(self) -> List[Dict]        # 暴露的工具
    def handle_tool_call(self, tool_name, args)     # 处理工具调用
    def shutdown(self)                               # 清理退出

    # 可选钩子
    def on_turn_start(turn_number, message)         # 每轮开始
    def on_session_end(messages)                    # 会话结束
    def on_pre_compress(messages) -> str           # 上下文压缩前
    def on_memory_write(action, target, content)    # 内置内存写入时
    def on_delegation(task, result)                 # 子代理完成时
```

## 安全机制

`memory_tool.py` 实现了威胁检测，防止注入/外泄：

```python
_THREAT_PATTERNS = [
    # Prompt injection
    r'ignore\s+(previous|all|above|prior)\s+instructions',
    r'you\s+are\s+now\s+',
    r'do\s+not\s+tell\s+the\s+user',
    r'system\s+prompt\s+override',
    # Exfiltration via curl/wget
    r'curl\s+[^\n]*\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD',
    # Persistence via shell rc
    r'authorized_keys',
]
```

还检测不可见 Unicode 字符（U+200B, U+FEFF 等）。

## 与系统提示词的关系

```
┌─────────────────────────────────────────────────────────┐
│                    System Prompt                         │
├─────────────────────────────────────────────────────────┤
│  [Provider A system_prompt_block()]                      │
│  [Provider B system_prompt_block()]                      │
│  [Frozen Memory Snapshot: MEMORY.md content]             │
│  [Frozen Memory Snapshot: USER.md content]               │
│  [Skills (loaded on demand)]                            │
│  [Session context]                                      │
└─────────────────────────────────────────────────────────┘
```

## 与 Claude Code Memory 的对比

| 特性 | Hermes 内置 Provider | Claude Code Memory |
|------|---------------------|-------------------|
| 存储介质 | 文件 (MEMORY.md) | 文件 (.claude/memory.md) |
| 向量检索 | ❌ 无 | ❌ 无 |
| 语义搜索 | ❌ 无 | ❌ 无 |
| 字符限制 | 2200 (MEM) / 1375 (USER) | ~10KB |
| 扩展性 | 可插拔 Provider 架构 | 无 |

**结论**：内置 Provider 确实和 Claude Code Memory 类似，都是基于文件的键值存储，无向量检索能力。

## 外部 Provider（向量检索支持）

Hermes 支持通过 `memory.provider` 配置接入外部记忆服务：

```bash
hermes config set memory.provider mem0  # 向量检索 + LLM fact extraction
hermes config set memory.provider honcho # 语义搜索 + cross-session modeling
```

### mem0 Provider 特性

- **语义搜索**：基于向量数据库的相似度检索
- **Reranking**：搜索结果重排
- **自动去重**：LLM 提取事实时自动去重
- **工具**：`mem0_search`、`mem0_profile`、`mem0_conclude`

### honcho Provider 特性

- **语义搜索**：`honcho_search`
- **用户建模**：`honcho_profile`
- **上下文合成**：`honcho_context`（LLM 综合回答）
- **事实持久化**：`honcho_conclude`

## 总结

Hermes 的持久化内存设计简洁高效：

1. **文件系统优先**：无需外部数据库，纯文本文件便于调试和版本控制
2. **Frozen Snapshot**：平衡了持久化和性能
3. **原子写入**：保证数据一致性
4. **可插拔架构**：支持外部 Provider 扩展
5. **安全第一**：内置注入/外泄检测
6. **并发安全**：文件锁保护但不过度加锁
