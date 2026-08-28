# ex02 极简验证说明（nc 自带，无需额外依赖）

前置：QEMU 已按 `tools/run_qemu.sh` 启动，日志出现 `$$$ EX02ECHOREADY port=8210`。

## 1. 单连接往返

```bash
$ nc localhost 8210
hello ex02            # 手敲任意文本回车，服务端原样回显
hello ex02
^C                    # Ctrl-C 断开；guest 日志随即打印 conn #N ... CLOSED
```

一行式（发送即断）：

```bash
printf 'ping-from-host\n' | timeout 3 nc localhost 8210
# 预期输出：ping-from-host
```

## 2. 第二连接排队语义（串行 accept 实测）

终端 A：`nc localhost 8210`（保持连接不发数据）
终端 B：`nc localhost 8210` 敲 `from-B`
观察：B **收不到**任何回显；guest 日志也没有 B 的 ACCEPT 行。
关闭 A（Ctrl-C）：B 的 `from-B` 回显立刻到达；日志顺序为

```
conn #N A 的 CLOSED 行  →  conn #N+1 ACCEPT from ...
```

结论：单任务 accept 循环一次只服务一条连接，B 在内核 backlog 里排队，
直到 A 被 close 后才被 accept（详见 README「并发语义」节）。

## 3. 压测

```bash
python3 tools/bench.py --conns 4 --msgs 20 --size 512
```
