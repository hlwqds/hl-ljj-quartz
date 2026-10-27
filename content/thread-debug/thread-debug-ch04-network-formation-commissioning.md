---
title: "Thread 调试实战（四）：组网与入网"
date: 2026-10-27 12:00:00
pin: false
description: "入网排障章：先把「扫不到网 / attach 反复重试 / 两台设备各成一个网」三类现象分开，再拆 dataset 家族（Active/Pending、PAN ID/Extended PAN ID/Network Name/Channel/Network Key/PSKc/Mesh-Local Prefix），给出 dataset 导出对齐的完整流程；然后讲 thread start 后从零建网的选信道/选 PAN/Leader 诞生，commissioning 三条路（Commissioner+Joiner/PSKd、dataset 直传）与各自失败特征，attach 状态机（MLE Parent Request→Response→Child ID）分阶段取证表，最后以「两台设备各成一个网」的教学复盘案例与根因速查表收束。ot-cli 命令全部真实可执行，帧序列与日志为格式示意。"
tags: [thread-debug, Thread, OpenThread, Debugging, RF]
---

# Thread 调试实战（四）：组网与入网

> [!info] Thread 调试实战系列 0. [[thread-debug|系列索引]]
> 上一章：[[thread-debug-ch03-802154-sniffing|第三章：802.15.4 空口抓包]]
> **第四章：组网与入网**（当前章）
> 下一章：[[thread-debug-ch05-routing-topology|第五章：路由与拓扑]]

> [!note] 本章证据口径
> 本章 ot-cli 命令以 OpenThread 官方 CLI 参考为准（posix 仿真与 nRF52840/ESP32-H2 真机均适用）；dataset 字段、MLE 消息名与入网流程引 **Thread Specification 1.2/1.3 口径**（Master Key 在 1.2 起更名为 Network Key，正文标注）；PSKd/PSKc/J-PAKE 属 MeshCoP（Commissioning）子集，口径同上。**帧序列与日志样例均为「格式示意」**——字段结构真实、数值为教学排版编排；案例为**教学复盘案例，取材自常见故障模式综述**。实测读数不虚构。

## 4.1 现场引入：三类「入不了网」

第四章开始，症状五分类进入第一类「入不了网」。同一句「连不上 mesh」，背后至少是三种病：

| 类型                  | 典型描述                                     | 问题域直觉                                | 高频重灾区                            |
| --------------------- | -------------------------------------------- | ----------------------------------------- | ------------------------------------- |
| A：joiner 扫不到网络  | 「配网 App 转圈，扫不到设备发的入网信标」    | Beacon 未发/信道错/PSKd 没配/射频侧       | 全新设备首次配网、commissioner 侧配置 |
| B：attach 反复重试    | 「dataset 灌了，state 一直 detached/来回跳」 | dataset 半对半错、Leader 侧拒绝、链路质量 | 批量烧录、手工改过某个网络参数        |
| C：两台设备各成一个网 | 「两块板 state 都是 leader，互相看不见」     | **dataset 不一致**（多半是部分字段漂移）  | 手工逐条配参数、出厂预配流程混乱      |

A/B/C 的性价比排序很明确：**C 最先查、成本最低**——一条 `dataset active -x` 导出十六进制串对比即可定案。Thread 的入网条件是「同一个 dataset 的全部标识字段一致」，任何一字段漂移（哪怕只是 Network Name）都足以让两台设备鸡犬相闻、老死不相往来。这也是总索引里「先核对 dataset」纪律的本章。

三类问题最终都会落到同一张地图：**dataset 一致 → attach 状态机走通 → network data 同步**。先问断在哪一步，再问为什么。

## 4.2 dataset 家族：Active / Pending 与字段拆解

### Active 与 Pending 的分工

Thread 把网络配置放两份数据集：

| 数据集              | 作用                         | 谁在什么时机改                                                |
| ------------------- | ---------------------------- | ------------------------------------------------------------- |
| **Active Dataset**  | 当前生效的网络身份与运行参数 | 建网时 Leader 生成；此后原则上不改                            |
| **Pending Dataset** | 「下一版」配置，带延迟计时器 | Leader 计划切换信道/PAN 等时下发，延迟到期后原地转正为 Active |

调试视角的要点：设备入网时对齐的是 **Active**；如果 Leader 在做延迟切换（如信道迁移），Pending 会被复制下来——排障时两份都要看。信道迁移的完整机制在第五章网络数据部分还会遇到，本章先立住「Active 才是入网契约」这一条。

### 字段逐个拆（口径：Thread Spec 1.2+，OpenThread `dataset active` 输出）

| 字段                | 作用                                                         | 不一致的后果                        | 调试提示                                            |
| ------------------- | ------------------------------------------------------------ | ----------------------------------- | --------------------------------------------------- |
| Active Timestamp    | Active Dataset 版本号（单调递增）                            | 旧的 dataset 被新版本覆盖           | 「我以为写进去了，实际 Timestamp 低被丢弃」是经典案 |
| Channel             | 802.15.4 信道（2.4 GHz 为 11-26，IEEE 802.15.4 口径）        | 直接扫不到/收不到                   | 与第三章信道选择呼应                                |
| Channel Mask        | 可用信道掩码                                                 | 影响扫描与迁移范围                  | 建网时 Leader 从掩码中选信道                        |
| PAN ID              | 16 位短网络标识                                              | 同信道不同网互扰判别时看它          | 可用 `panid` 命令读取                               |
| **Extended PAN ID** | 64 位长网络标识，入网与配网（加入许可）判据之一              | **两台设备各成一网的头号字段**      | 手工配网时最常被漏改                                |
| Network Name        | 人类可读名（≤16 字节，Thread Spec 口径）                     | 不阻断 attach，但 App 扫描列表混乱  | 排障时只当辅助指纹                                  |
| Network Key         | 6LoWPAN/MLE 层加密密钥（Thread 1.2 前叫 Master Key，128 位） | **收得到帧解不开**：MLE 加密失败    | 空口抓包解密必须用它（第三章方法）                  |
| Mesh-Local Prefix   | 网内 ULA 前缀（fdxx::/48）                                   | 地址族对不上，attach 后互 ping 失败 | RLOC/ML-EID 都派生自它（第五章）                    |
| PSKc                | Commissioner 预共享密钥（由 passphrase 派生）                | commissioner 鉴权失败               | `pskc -p <passphrase>` 生成                         |
| Security Policy     | 密钥轮换时间/版本标志等                                      | 老设备入不了新网（版本策略）        | 跨版本混合部署时核对                                |

### dataset 复制与「先核对 dataset」纪律的完整流程

discipline 的可操作形态就是**导出-对比-导入对齐法**。在「已知正常」的设备（如 OTBR）上：

```bash
# 在参考设备（正常网的成员）上导出 Active Dataset 为十六进制串
ot-cli> dataset active -x
0e080000000000010000000300000b35060004001fffe002083321...（格式示意）
```

在问题设备上先看现状、再对齐：

```bash
ot-cli> dataset active          # 看人类可读的全部字段（信道/PAN/XPANID/名字…）
ot-cli> dataset active -x       # 导出本机十六进制串，与参考设备逐字符 diff
# 对齐方式一：整串灌入（推荐，杜绝逐字段手改的漂移）
ot-cli> dataset set active <参考设备的十六进制串>
ot-cli> ifconfig up
ot-cli> thread start
ot-cli> state                   # 观察 router/child/detached
```

> [!warning] 三条纪律
>
> 1. **禁止逐字段手改**对齐（`networkkey`/`extpanid` 各敲一遍）——漏一个字段就是本章 C 类案例的原料；用 `-x` 十六进制串整存整取。
> 2. 灌完 dataset 后必须 `thread start` 之前先 `ifconfig up`，且 reset 设备（`reset`）是更干净的验证起点。
> 3. Active Timestamp 只增不减：往旧设备灌新 dataset 没问题，反过来「新设备灌旧串」会被拒绝——怀疑生效与否时看 `dataset active` 回读的 Timestamp。

## 4.3 组网：thread start 之后发生了什么

### 从零建网的三步（第一个设备）

```text
ifconfig up → thread start
 ├─ ① 无网络可加入（扫描后无响应）
 │     → 选信道（按 Channel Mask + 能量扫描,避免拥挤信道）
 ├─ ② 选一个未占用的 PAN ID / Extended PAN ID(随机生成)
 │     → 生成 Network Key、Mesh-Local Prefix,组装 Active Dataset
 └─ ③ 自举为 Router 并赢得选举 → state: leader
       → 开始发 Enhanced Beacon、接受后续设备 attach
```

OpenThread 侧对应的可观察序列（`ot-cli`，格式示意）：

```text
> state
leader
> panid
0xabcd          （示意）
> extpanid
33215566778899a0（示意）
> leaderdata
Partition ID: 2147483649
Weighting: 64
Data Version: 12
Stable Data Version: 5
Leader Router ID: 44
```

第一台设备建成网络后，**它就是 Leader**——这也是 C 类现象（两台各成一个网）的机制根源：如果 dataset 不一致，两台设备都判定「周围没有我的网络」，于是各自走完①②③。

### 后续设备 attach（第二个设备起）

```text
ifconfig up → thread start
 ├─ ① 扫描:逐信道收 Enhanced Beacon(带 Extended PAN ID、joining 许可标志)
 ├─ ② 对齐 dataset 的字段 → 认定「这就是我的网」
 └─ ③ 走 attach 状态机(4.5):找父 → 拿 Child ID → state: child
       (符合升级条件后可能继续 router 升级,见第五章)
```

`thread start` 之后用 `state` 的变化速度做第一判据：秒级到 child/leader 是健康；停在 detached 并周期性跳回，是 4.5 的 attach 失败；永远 detached 且扫描空转，多半是 4.2 的字段不一致或射频侧问题（回第三章核实空口确实有 Beacon）。

## 4.4 Commissioning：外带入网的三条路

「配网」(commissioning) 指把一台新设备带入已存在的网络。Thread（MeshCoP，Thread Spec 口径）给三条路，各有适用面与失败指纹：

| 路线                            | 流程概要                                                                  | 适用                            | 典型失败指纹                   |
| ------------------------------- | ------------------------------------------------------------------------- | ------------------------------- | ------------------------------ |
| ① Commissioner + Joiner（PSKd） | 网内设备当 Commissioner 授权；新设备以 PSKd（配网口令）经 J-PAKE 鉴权入网 | 出厂设备的标准配网路径          | joiner 扫不到信标；J-PAKE 超时 |
| ② Dataset 直传                  | 把 Active Dataset 十六进制串直接灌入新设备                                | 开发/产线/调试                  | 见 4.2 纪律；Timestamp 冲突    |
| ③ 半自动（扫码/带外）           | App 从云端/二维码取出 dataset 或凭证转交                                  | Matter 配网的上游（第十章展开） | 凭证过期、渠道数据漂移         |

### 路线①的完整命令（OpenThread 口径）

网内一侧（任一已入网 FTD，或 OTBR）开 Commissioner 并登记 joiner：

```bash
ot-cli> commissioner start
Done
# 用 EUI-64 精确白名单（推荐）；`*` 表示任意 joiner，仅限调试
ot-cli> commissioner joiner add 4e57000000000001 7A7H9S3T00
Done
```

新设备一侧（出厂/擦除后）发起加入：

```bash
ot-cli> ifconfig up
ot-cli> joiner start 7A7H9S3T00     # PSKd 与 commissioner 侧一致
Done
# 成功后日志出现 Join success 提示(格式示意),随后:
ot-cli> thread start
ot-cli> state
child
```

PSKd 口径：长度与字符集按 Thread Spec 1.2 的规则（默认建议全大写字母数字、去掉易混淆字符；生成工具口径随生态实现，待核对具体 App 实现）。

### 每条路的失败特征速判

| 现象                                   | 断点                                               | 首选取证                                                                                     |
| -------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| joiner 收不到任何入网信标              | commissioner 侧 joiner 没登记 / 网内无人放行       | `commissioner joiner` 回读列表；空口看 Enhanced Beacon（第三章方法，注意解密需 Network Key） |
| J-PAKE 阶段超时/失败                   | PSKd 两边不一致、信道边缘信号差                    | 两边各打印一次 PSKd 字节核对；缩短距离复测                                                   |
| `commissioner joiner add` 被拒         | PSKc 不对（commissioner 鉴权失败）                 | `pskc -p <passphrase>` 重新生成核对                                                          |
| dataset 直传后仍 detached              | 字段对了一半/Timestamp 问题                        | 4.2 的 `-x` 导出 diff                                                                        |
| joiner 成功但 thread start 后 detached | dataset 只覆盖了一半（仅 EUI 授权 ≠ dataset 一致） | `dataset active` 对比                                                                        |

## 4.5 attach 状态机：MLE 交互的分阶段取证

### MLE 流程（引 Thread Spec / 第三章帧解读）

入网的协议动作发生在 **MLE（Mesh Link Establishment）**，帧是 802.15.4 数据帧里的 UDP/19788（MLE 端口，Thread Spec 口径），多数受 Network Key 加密——解密方法见第三章：

```text
 新设备(Device)                          候选父节点(Parent)
   │ ── IEEE 802.15.4 Beacon Request ──► │
   │ ◄── Enhanced Beacon(XPANID/joining) │
   │ ── MLE Parent Request(广播) ──────► │ (也发给其他邻居)
   │ ◄── MLE Parent Response(单播) ───── │ 携带链路质量/优先级等
   │ ── MLE Child ID Request ──────────► │ 请求入网(带 Mode/超时等)
   │ ◄── MLE Child ID Response ───────── │ 分配 Child ID / 网络数据开始下发
   │      state: child                    │
```

（格式示意：实际还伴随 MLE Advertisement/Link Accept 等消息建立双向链路质量，教学图省略。）

### attach 失败分阶段取证表

| 卡在哪                                   | 用户/CLI 可见                   | 空口帧特征（第三章抓包）                                     | 最可能的根因                                                                       |
| ---------------------------------------- | ------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| ① 收不到 Beacon Response（无任何响应）   | `state` 停在 detached，扫描空转 | Beacon Request 发出、无 Beacon 回                            | 信道错/dataset 信道字段不一致；父设备射频异常                                      |
| ② Beacon 有但 Parent Request 无 Response | detached，周期扫描              | Parent Request 发出、无 Parent Response                      | Network Key 不一致（对端解不开 MLE 加密消息）；信号边缘                            |
| ③ Parent Response 有、Child ID 被拒      | detached/detached↔扫描循环      | Child ID Request 后无 Response 或被拒                        | Extended PAN ID/许可策略不符；父节点已满（容量口径见 Thread Spec，待核对具体上限） |
| ④ Child ID Response 后反复掉回           | state 在 child/detached 间跳    | Data Request 无应答、随后父发 Child Remove/Child Update 失败 | 链路质量边缘；两侧 dataset 半漂移（Pending 未同步）                                |
| ⑤ 入网即解密失败告警                     | joiner 成功后仍异常             | 抓包显示 MIC 校验失败（解密方视角）                          | Network Key/Key Sequence 复位混乱（key 轮换口径见 Security Policy）                |

> [!tip] 分阶段口诀
> **收不到 = 信道/射频；收到了解不开 = Network Key；解得开进不去 = XPANID/许可；进得去站不稳 = 链路质量或 Pending 漂移。** 每档对应的取证动作都只需一条命令或一个过滤器，成本极低。

ot-cli 侧的辅助证据：

```bash
ot-cli> state            # detached/child/router/leader
ot-cli> parent           # 当前父节点与平均 RSSI(真机口径)
ot-cli> router table     # 入网成功后可见全网 router(见第五章)
ot-cli> nbr              # 邻居与链路质量(实现版本命名或有差异,待核对)
```

## 4.6 教学案例：「两台设备各成一个网」复盘

**教学复盘案例，取材自常见故障模式综述。** 背景是一套两板教学实验：第一块板 A 已建成网络，第二块板 B 灌入手工整理的 dataset 后 `thread start`，结果两块板 `state` 都是 `leader`，互 ping 不通，Wireshark 里也只见各自的 Beacon。

**第一步：判型。** 两台都是 leader = 各自成网 = C 类。此刻不要碰射频，先做 4.2 的导出对齐：

```bash
# A 板
ot-cli> dataset active -x
0e080000...35060004001fffe002081122334455667788...（格式示意）
# B 板
ot-cli> dataset active -x
0e080000...35060004001fffe00208aabbccddeeff0011...（格式示意）
```

**第二步：结构化 diff。** 不逐字符硬瞪，按字段表（4.2）分组对比（示意）：

| 字段            | A 板             | B 板             | 判读               |
| --------------- | ---------------- | ---------------- | ------------------ |
| Channel         | 11               | 11               | 一致               |
| PAN ID          | 0xabcd           | 0xabcd           | 一致               |
| Extended PAN ID | 1122334455667788 | aabbccddeeff0011 | **不一致——铁证**   |
| Network Name    | OtTest           | OtTest           | 一致（掩盖了问题） |
| Network Key     | 55aa…（示意）    | 55aa…（示意）    | 一致               |

复盘要点：实验者当年是逐条手敲 `networkname`/`networkkey` 对齐的，恰好漏掉 `extpanid`；Network Name 一致让两台设备的 Beacon 在 Wireshark「看起来像同一个网」，极具迷惑性。机制上，B 板扫描时按 Extended PAN ID 匹配不到 A 板，判定「周围没有网」，走完 4.3 的从零建网三步自立为王。

**第三步：修复与验证。** 在 B 板整串灌入 A 板 dataset（`dataset set active` + `reset` + `thread start`），B 板依次出现 `child`（数秒内）→ 实验允许时升级为 `router`；`ping` 对方 Mesh-Local 地址互通，空口可见同一 PAN 内的双向流量。**修复只动了一个动作——整串导入，而非补改单个字段**。

**沉淀的检查项**：任何「两台 leader」现场，第一动作就是双向 `dataset active -x` 导出 diff；并检查双方 Active Timestamp——被覆盖的旧配置是漂移的常见来源。

## 4.7 根因速查表

| 现象           | CLI/可见特征                 | 空口特征（第三章）         | 根因                             | 对策                            |
| -------------- | ---------------------------- | -------------------------- | -------------------------------- | ------------------------------- |
| 扫不到网       | joiner 无响应、detached 空转 | 无 Enhanced Beacon         | commissioner 未放行 joiner       | `commissioner joiner add` 登记  |
| 扫不到网       | dataset 信道与现场不符       | 该信道无流量               | 信道字段不一致/信道被迁移        | `-x` 导出对齐；查 Pending       |
| attach 卡死    | 停 detached                  | Parent Request 无 Response | Network Key 不一致               | 整串灌入 dataset                |
| attach 被拒    | Child ID 无果                | Child ID Request 被拒/无视 | XPANID 不符/父容量满             | 对齐 dataset；减载或加节点      |
| 反复重试       | child↔detached 跳变          | Data Request 失败/Remove   | 链路质量边缘                     | 缩距/查天线（回第三/九章）      |
| 各成一网       | 双 leader                    | 两个独立 Beacon 流         | dataset 字段漂移（典型 XPANID）  | 导出 diff → 整串导入            |
| 半漂移         | 部分节点间歇异常             | 加密 MIC 失败/解密告警     | Network Key 或 Key Sequence 漂移 | 统一 Security Policy 与密钥轮换 |
| Timestamp 冲突 | 灌入不生效                   | —                          | 新设备灌旧 dataset               | 旧向新灌；核对 Timestamp        |

> [!summary] 本章收束
> 入网排障的骨架是三句话：**先核对 dataset（导出-导入整串对齐），再分阶段读 attach（收不到/解不开/进不去/站不稳），最后才动射频**。commissioning 的三条路里，调试期优先 dataset 直传（可控可 diff），出货路径才是 Commissioner/Joiner。设备入网之后，「站得稳不稳、拓扑怎么长」就是下一章路由与拓扑的主战场。
