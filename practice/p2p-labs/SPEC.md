# P2P 网络实验室 · 套件公约（P2P LABS SPEC）

本文件是 `practice/p2p-labs/` 套件全部工程的实现契约，配套系列
[[p2p-deep-dive|P2P 网络深度解析]]。

## 1. 定位与约定

- **定位**：把系列正文里的协议拆成**能在宿主机直接跑通的最小实现**——STUN 报文逐字节
  手搓、打洞时序真实发出、Chord/Kademlia 路由真实收敛、BitTorrent 线缆协议真实握手。
  追求"协议保真"而非功能完整：每个工程都只实现该章的核心机制，砍掉生产级的健壮性。
- 技术栈：**C11 + BSD socket，零第三方依赖**（网络工程配 `net_compat.h` 跨平台薄垫层，
  Windows 走 Winsock2、POSIX 走 sys/socket）。理由：本仓读者主阵地是 C（lwIP/F429 系列），
  协议教学的正统形态就是 Berkeley socket 的 C；DHT 模拟（ch06/ch07）是纯算法单文件，
  不碰网络。编译器不限：`zig cc` / gcc / clang 皆可——`zig cc` 一条命令零安装（自带
  clang 与 libc 头），是 Windows 上最省事的路径。
- 目录：`practice/p2p-labs/chNN-slug/`（NN 对应系列章节号）。
- 每工程必备：源码、`README.md`（中文，含拓扑图与复现命令、反向 wikilink 回所属章节）、
  `run.log`（真实运行留存，本仓先成文后实跑惯例的"实跑"部分在本机完成）。
- 端口号段：**12000–12199**（避开 lwip-examples 的 8200–8299）。演示脚本内不硬编码
  具体端口的场合用 0（系统分配）+ 输出回显。

## 2. 诚实性规则

- run.log 必须是**真实运行输出**，不做手工美化；失败与重试照留。
- 涉及外网的实验（公网 STUN、真实 NAT 打洞）在无外网环境下用 **mock/本地等价物**演示
  协议流程时，README 必须显式标注"本地等价演示"，并给出真实环境的复现参数。
- 模拟类工程（mini-chord/mini-kademlia 的进程内模拟）明确标注模拟边界：算法与协议
  语义保真，网络传输层（丢包/延迟）不在模拟范围。

## 3. 各工程一览

| 工程               | 章  | 验证的机制                                         |
| ------------------ | --- | -------------------------------------------------- |
| ch02-lan-direct    | 2   | 对称 UDP 端点、广播发现、分块传输 + SHA 校验       |
| ch03-stun-probe    | 3   | STUN Binding 报文构造/解析、映射行为判定           |
| ch04-hole-punch    | 4   | 引路-交换-互射的打洞三步、保活                     |
| ch06-mini-chord    | 6   | 一致性哈希定宿主、finger 路由 O(log N)、churn 自愈 |
| ch07-mini-kademlia | 7   | k-bucket、XOR 迭代查找、k 副本容错、女巫攻击       |
| ch08-mini-bt       | 8   | bencode、tracker 点名、peer 握手/请求/分片校验     |

## 4. 复现基线

- 参考环境：Windows 10 / Git Bash / `zig cc`（Zig 0.17 自带 clang）编译验证，Linux/macOS
  用系统 cc 直接可用。
- 每工程 README 的"复现"小节给出的命令应能在干净目录里按序执行并得到与 run.log 同构
  的输出；多进程实验提供一键脚本或分窗说明。
