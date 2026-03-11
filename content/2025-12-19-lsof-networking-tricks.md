---
title: lsof 网络排查实战：不仅是查看端口，更是系统透视眼
date: 2025-12-19 10:00:00
pin: true
tags: [linux, tools, network, devops, lsof, troubleshooting, socket, process]
---

# lsof 网络排查实战：不仅是查看端口，更是系统透视眼

在 Linux 的世界里，**"Everything is a file"**（一切皆文件）。这是理解 `lsof` (List Open Files) 强大之处的关键。

对于 socket、管道、设备、目录，内核都把它们当作文件来处理。因此，`lsof` 不仅仅是一个查看“谁占用了端口”的工具，它是一个能将**网络连接**、**进程信息**和**文件系统**关联起来的透视眼。

本文整理了 `lsof` 在网络排查中的高频实战场景和救命技巧。

## 1. 核心参数：拒绝卡顿

在生产环境中运行 `lsof` 时，最常用的参数组合必须是 `-nP`。

- `-n`: **No Hostnames**。不要将 IP 解析为主机名（避免 DNS 超时导致的漫长等待）。
- `-P`: **No Port Names**。不要将端口号 8080 解析为 `http-alt`，直接显示数字更直观。

```bash
# 推荐起手式
lsof -nP -i
```

### 1.1 参数名背后的含义

了解这些缩写有助于记忆：

- **`-i`**: **Internet**。指 Internet 地址（如 TCP/UDP），与 `-U` (Unix Domain) 相对。
- **`-t`**: **Terse**。意为“简洁的”，只输出 PID，不带表头和详情，方便脚本调用。
- **`-n`**: **Number**。不将 IP 转换为域名。
- **`-P`**: **Port**。不将端口号转换为服务名。

## 2. 基础场景：精准定位连接

### 2.1 查找谁占用了端口

这是最基础的用法，替代 `netstat`。

```bash
lsof -i :80             # 占用 80 端口的进程
lsof -i :80-100         # 占用 80 到 100 范围内端口的进程
lsof -i :80,443,3306    # 离散多端口
```

### 2.2 区分 IPv4 / IPv6

```bash
lsof -i 4       # 仅列出 IPv4
lsof -i 6       # 仅列出 IPv6
```

### 2.3 仅查看 TCP 或 UDP

```bash
lsof -i TCP:80
lsof -i UDP:53
```

## 3. 进阶场景：复杂的条件过滤

`lsof` 支持逻辑与 (`-a`, AND) 操作，这让它可以进行非常精准的过滤。

### 3.1 指定用户的网络连接

查看 `nginx` 用户或 `www-data` 用户发起的所有网络连接：

```bash
lsof -a -u www-data -i
```

### 3.2 指定进程的网络连接

只想看 PID 为 1234 的进程打开了哪些网络端口：

```bash
lsof -a -p 1234 -i
```

### 3.3 查找指定状态的 TCP 连接

只想看谁处于 `ESTABLISHED` 状态（排除 LISTEN 和 TIME_WAIT）：

```bash
lsof -nP -i TCP -s TCP:ESTABLISHED
```

- _提示_: 配合 `-s TCP:LISTEN` 可以快速找出所有后台服务。

### 3.4 排除 root 用户

查看非 root 用户启动的所有网络进程（通常用来排查异常进程）：

```bash
lsof -i -u ^root
```

## 4. 骨灰级场景：全景关联排查

这是 `ss` 或 `netstat` 无法做到的领域。

### 4.1 杀掉占用端口的所有进程

开发时经常遇到“端口被占用”且不止一个进程。

```bash
# 危险操作，请谨慎使用
kill -9 $(lsof -t -i :8080)
```

- `-t`: Terse mode，只输出 PID，专门用于管道命令。

### 4.2 顺藤摸瓜：从端口反查程序位置

发现一个诡异端口 9999 被占用了，想知道是哪个脚本跑起来的？

```bash
# 第一步：找到 PID
PID=$(lsof -t -i :9999)

# 第二步：查看该 PID 打开的所有文件
lsof -p $PID
```

**输出的信息量极大**：

1.  **txt**: 进程的可执行文件路径。
2.  **cwd**: 进程启动时的当前目录。
3.  **1u/2u**: 标准输出/错误日志写入到了哪个文件。
4.  **.so**: 加载了哪些动态链接库。

### 4.3 恢复被误删的文件（包括 Socket 引用）

如果日志文件被 `rm` 了，但进程还在写，磁盘空间没释放。

```bash
lsof +L1
```

这会列出所有硬链接数 (nlink) 小于 1 但仍被打开的文件。你可以通过 `/proc/$PID/fd/$FD` 把内容救回来。

### 4.4 实时网络监控

不需要装 `iftop`，用 `lsof` 也能简单监视连接变化。

```bash
# 每 2 秒刷新一次，查看 443 端口的连接情况
lsof -nP -i :443 -r 2
```

### 4.5 处理 Unix Domain Socket

在 Linux 本地进程间通信 (IPC) 中，Unix Socket 非常常见（如 Docker, Database）。

- **查看所有 Unix Socket**:
  ```bash
  lsof -U
  ```
- **谁在用这个 .sock 文件？**:
  如果你发现一个路径为 `/run/user/1000/bus` 的文件，想知道谁在占坑：
  ```bash
  lsof /run/user/1000/bus
  ```
- **关联对等端 (Peer)**:
  `lsof` 查看 Unix Socket 有时较难看出谁连谁。此时推荐配合现代化工具 `ss`：
  ```bash
  # 查看所有 Unix Socket 连接及其所属进程
  ss -x -p
  ```

### 4.6 从 lsof 到 /proc：寻找真实的 FD

`lsof` 的输出中，**FD** 列直接对应了 Linux 内核 `/proc` 系统中的文件描述符。

- **查找路径**:
  若 `lsof` 显示某进程 (PID: 1234) 的 FD 为 `3u`，则其在系统中的位置为：
  `/proc/1234/fd/3`
- **查看 Socket 详情**:
  ```bash
  ls -l /proc/1234/fd/3
  # 输出示例：lrwx------ ... /proc/1234/fd/3 -> socket:[26478]
  ```
  这里的 `26478` 是该 Socket 的 **inode 编号**，它是关联进程与内核网络状态表的唯一纽带。

## 5. 总结

| 场景           | 命令                         |
| :------------- | :--------------------------- |
| **标准起手**   | `lsof -nP -i`                |
| **查端口**     | `lsof -i :8080`              |
| **查特定状态** | `lsof -i -s TCP:ESTABLISHED` |
| **只出 PID**   | `lsof -t -i :80`             |
| **全景透视**   | `lsof -p <PID>`              |

`ss` 胜在快和网络统计细节，而 `lsof` 胜在将**网络**与**文件系统**打通。在面对复杂的故障排查时，`lsof` 往往能提供更多的上下文线索。
