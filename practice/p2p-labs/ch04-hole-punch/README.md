# ch04-hole-punch —— 引路服务器 + UDP 打洞

把 [[ch04-nat-traversal|第四章：NAT 穿透]] §4.1 的打洞时序做成真实可跑的三进程实验：
**rendezvous.c** 是严格只做情报交换的引路服务器（控制面），**punch.c** 是打洞端——
登记（①REG 重试）→ 收情报（②PEER）→ 互射施工包（③PUNCH/PONG，首包被丢是施工
不是失败）→ 直连聊天 + 3s 周期 keepalive 维持 NAT 映射。全程单一 socket
（ch03 那次翻车的教训焊死在结构里）。

## 拓扑

```text
alice ──①REG(重试)──▶ rendezvous(:12050) ◀──①REG── bob
alice ◀──②PEER bob ip:port── rendezvous ──②PEER alice ip:port──▶ bob
alice ══③PUNCH/PONG 互射 + keepalive + 聊天══▶ bob      ← 服务器退场，数据面直连
```

## 编译

```bash
zig cc -o rendezvous rendezvous.c -lws2_32   # Linux/macOS 去掉 -lws2_32
zig cc -o punch punch.c -lws2_32
```

## 复现（本机三进程，三个终端）

```bash
./rendezvous 12050
./punch --server 127.0.0.1:12050 --room demo --name alice   # 先起，处于登记重试
./punch --server 127.0.0.1:12050 --room demo --name bob     # 后起，触发配对互射
```

真实互联网实验：把 rendezvous 部署到任一台有公网 IP 的机器，两台各自 NAT 后的
设备 `--server` 指过去——PEER 报文里的地址就是各自 NAT 的映射端点，EIM（锥形）
网络会在几百毫秒内打穿；若一直打不通，多半撞上了对称 NAT（ch03 的 probe 先去判个型）。

完整真实输出见 `run.log`（含三侧日志与时序对账，Windows 10 / zig cc 0.17 编译）。
