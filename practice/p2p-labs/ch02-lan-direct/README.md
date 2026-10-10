# ch02-lan-direct —— 对称聊天 · 广播发现 · 分块传输

把 [[ch02-first-peer-direct-connect|第二章：第一个 P2P 程序]] 的三段正文代码做成可编译
运行的最小工程：**peer.c**（对称 UDP 聊天，没有服务端身份）、**discover.c**（UDP 广播
发现同伴）、**filecast.c**（请求-数据块分块传输 + SHA-1 整体校验）——外加两个教学配套件：
**net_compat.h**（Winsock/POSIX 跨平台垫层，lwIP sys_arch 的微缩版）与 **sha1.c**
（教科书 SHA-1，ch08 造种子直接复用同款）。

## 拓扑

```text
peer.c / filecast.c：      A(任意端口) ⇄ UDP ⇄ B(任意端口)     双方同构，无 listen/accept
discover.c：               A ── HELLO(广播/单播) ──▶ B
                           A ◀──────── HERE(单播) ─── B
filecast.c：               recv ── HELLO ──▶ send
                           recv ◀─ META n sha1 ── send
                           recv ── GET i ───▶ send   （缺哪块要哪块，丢了重试）
                           recv ◀─ DATA i ─── send
```

## 编译

```bash
zig cc -o peer peer.c -lws2_32          # Windows（zig 自带 clang；或用任何 cc）
zig cc -o discover discover.c -lws2_32
zig cc -o filecast filecast.c sha1.c -lws2_32
# Linux/macOS：把 -lws2_32 去掉即可（cc -o peer peer.c）
```

## 复现（本机双进程）

```bash
# 1) 对称聊天（两个终端；A 先发的那条会丢——B 还没 bind，UDP 无握手，教学点）
./peer 12031 127.0.0.1:12032
./peer 12032 127.0.0.1:12031

# 2) 广播发现（两个终端，--target 指到对方模拟广播可达；真实局域网去掉 --target）
./discover --name alice --port 12033 --target 127.0.0.1:12034 --interval 500
./discover --name bob   --port 12034 --target 127.0.0.1:12033 --interval 500

# 3) 分块传输（100000B = 98 块，末块 784B 短块路径一并覆盖）
python -c "import os; open('test.bin','wb').write(os.urandom(100_000))"   # 或 dd 造随机文件
./filecast send test.bin 12030 &
./filecast recv 127.0.0.1:12030 out.bin
sha1sum test.bin out.bin   # 两行必须一致
```

完整真实输出见 `run.log`（Windows 10 / Git Bash / zig cc 0.17 编译运行）。
