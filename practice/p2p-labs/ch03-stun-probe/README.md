# ch03-stun-probe —— 手搓 STUN 客户端 + 判型实验

把 [[ch03-nat-fundamentals|第三章：NAT——P2P 的头号敌人]] §3.5 的判型实验做成可运行
工程：**stun.c** 从零构造 RFC 5389 Binding Request（magic cookie、事务 ID、TLV 属性
遍历、XOR-MAPPED-ADDRESS 解异或），对多个服务器复用**同一个 socket** 查询，按
"同一本地端点在不同服务器眼中端口是否一致" 输出 EIM/对称 判定；
**mock_stun.c** 是离线等价的 STUN 服务器，`--offset N` 模拟对称 NAT 的映射漂移。

## 拓扑

```text
                    ┌─ mock_stun :12041  offset=0   ─┐
stun（单一 socket） ─┼─ mock_stun :12042  offset=100 ─┼─→ 判定表 + EIM/对称结论
                    └─ mock_stun :12043  offset=0   ─┘
真实环境：把参数换成公网 STUN（如 stun.stunprotocol.org:3478）即可测你家 NAT
```

## 编译

```bash
zig cc -o stun stun.c -lws2_32        # Windows（Linux/macOS 去掉 -lws2_32）
zig cc -o mock_stun mock_stun.c -lws2_32
```

## 复现（本机离线判型实验）

```bash
./mock_stun 12041 &                  # 三台"观察点"，两台同 offset、一台漂移
./mock_stun 12042 --offset 100 &
./mock_stun 12043 &
./stun 127.0.0.1:12041 127.0.0.1:12043   # → 映射一致：EIM（锥形）特征
./stun 127.0.0.1:12041 127.0.0.1:12042   # → 端口漂移 100：对称（APDM）特征
```

## 本工程自带的翻车记录（教学点）

第一版 `stun.c` 每次查询新开 socket——即使两台服务器 offset 同为 0，也判成"漂移"，
因为它们看到的根本是两个不同的本地源端口。教训即 ch04 §4.2 的纪律：**探测、判型、
打洞必须复用同一个本地端点**。修复后的代码在 main 里单 socket 贯穿全程，事故记录
同步留在了 `run.log` 与 `stun.c` 注释里。

完整真实输出见 `run.log`（Windows 10 / Git Bash / zig cc 0.17 编译运行）。
