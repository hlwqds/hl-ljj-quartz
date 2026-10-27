---
title: "Thread 调试实战（五）：路由与拓扑"
date: 2026-10-27 12:00:00
pin: false
description: "拓扑排障章：把「设备忽隐忽现 / 拓扑频繁抖动 / 两个 Leader 同时存在——分区」三类现象分层取证；拆地址体系 ML-EID/RLOC/Link-Local 的分工与 ping 哪个地址的取证意义；讲 Router 选举、REED 升降级门槛（Thread 规范口径）、router table 读取；重点覆盖 Partition 的成因（边界链路劣化）、合并过程与分区风暴的坏味道，netdata/leaderdata/router table 三板斧对照；再给拓扑稳定性取证（neighbor 表变化率、链路质量三档、state 变化日志），最后以「两台设备互踢」的教学复盘案例与根因速查表收束。ot-cli 命令真实可执行，拓扑图与日志为格式示意。"
tags: [thread-debug, Thread, OpenThread, Debugging, RF]
---

# Thread 调试实战（五）：路由与拓扑

> [!info] Thread 调试实战系列 0. [[thread-debug|系列索引]]
> 上一章：[[thread-debug-ch04-network-formation-commissioning|第四章：组网与入网]]
> **第五章：路由与拓扑**（当前章）
> 下一章：[[thread-debug-ch06-border-router|第六章：Border Router 与外网]]

> [!note] 本章证据口径
> ot-cli 命令（`state`/`router table`/`router list`/`leaderdata`/`netdata show`/`neighbor table` 等）以 OpenThread 官方 CLI 参考为准；Router 数量上限、REED 升降级条件、选举与分区合并机制引 **Thread Specification 1.2/1.3 口径**，个别超时参数随实现可配置的注明「实现可配/待核对」。拓扑图与日志样例均为**「格式示意」**；案例为**教学复盘案例，取材自常见故障模式综述**，不虚构实测读数。

## 5.1 现场引入：三类「网内不稳」

第四章把设备送进网；本章处理「进来之后站不站得稳」。现场口中的网内不稳至少三种病：

| 类型                    | 典型描述                                      | 问题域直觉                                  | 高频重灾区             |
| ----------------------- | --------------------------------------------- | ------------------------------------------- | ---------------------- |
| A：设备忽隐忽现         | 「后台拓扑图里某设备时有时无」                | 边缘链路/父子关系震荡、SED 节拍（引第七章） | 部署边缘、金属柜内     |
| B：拓扑频繁抖动         | 「router 角色来回切、邻居表天天变」           | 升降级门槛附近震荡、链路质量在阈值边缘      | 密集部署、信道拥挤     |
| C：两个 Leader 同时存在 | 「`leaderdata` 分区 ID 不一样、半个网一个网」 | **分区（Partition）**：网络被劣化链路劈开   | 大平面部署、跨房间多墙 |

判型前的第一动作依然是成本最低的一条命令：

```bash
# 在「怀疑不在同一边」的两台设备上各敲一次
ot-cli> leaderdata
Partition ID: 2147483649      # 两台一致 → 同分区,C 类暂排除
Weighting: 64
Leader Router ID: 44
```

Partition ID 一致则问题在 A/B（角色/邻居层面），不一致则直接进 5.4 的分区取证。这个先后次序的价值：C 类问题的解法（消除分区/合并）与 A/B（稳定单分区内的角色与链路）完全不同。

## 5.2 地址体系：ML-EID / RLOC / Link-Local 分工

Thread 设备身上同时挂着多个 IPv6 地址（`ot-cli> ipaddr` 可见），取证时**ping 哪个地址本身就是证据**：

| 地址类型                         | 形态                                  | 稳定性                            | 取证意义                                                                     |
| -------------------------------- | ------------------------------------- | --------------------------------- | ---------------------------------------------------------------------------- |
| Link-Local（fe80::/64）          | 按 EUI-64 派生                        | 永久                              | **只覆盖一跳链路**：ping 得通 = 这条无线链路活着                             |
| RLOC（Mesh-Local 前缀 + RLOC16） | `fdxx::ff:fe00:xxxx`（xxxx = RLOC16） | **随拓扑变化**：父子/角色一变就变 | 精确路由到「某个拓扑位置上的设备」：ping 它 = 测全 mesh 路由                 |
| ML-EID（Mesh-Local EID）         | `fdxx::` 随机 IID                     | **不随拓扑变**（重配网才变）      | 应用层应该用的「设备身份证」；ping 它与 ping RLOC 结果不一致时，差异就在路由 |

```text
                 Mesh-Local 前缀 fdab:1234::/48(由 dataset 派生)
                 ┌────────────────────────────────────────┐
                 │  RLOC: fdab:1234::ff:fe00:4400 (Leader) │ ← 拓扑位置
                 │  RLOC: fdab:1234::ff:fe00:1c00 (Router) │
                 │  ML-EID: fdab:1234::a1b2:... (某设备)   │ ← 稳定身份
                 └────────────────────────────────────────┘
```

三条取证经验：

- **ping Link-Local 通、ping RLOC 不通**：链路是好的，坏在 mesh 路由/网络数据同步——本章问题。
- **ping RLOC 通、ping ML-EID 不通**：路由表里少了该设备的 ML-EID 注册（地址解析/registration 路径），常见于刚震荡完、注册未收敛。
- **排障脚本统一用 ML-EID 作为设备标识**（拓扑再抖 id 不变），用 RLOC 判断「它现在挂在哪」。

RLOC16 的编解码（端口/Router ID 内嵌）属于 Thread 路由协议细节，`router table` 与 `child list` 输出里的 RLOC16 是后续所有命令的钥匙。

## 5.3 Router 机制：选举、REED 升降级、router table

### Router 与 Leader 的分工

- **Router**：转发 mesh 流量的全功能节点，持有 16 位 Router ID 与分配的 RLOC 段。
- **Leader**：Router 中的一个，负责维护 Network Data、分配 Router ID、裁决分区——**是「职务」不是「型号」**，任何 FTD Router 都可能成为 Leader。
- **REED（Router-Eligible End Device）**：有资格升 Router 但暂时以 End Device 角色工作的 FTD。

### 升降级门槛（Thread 规范口径）

| 机制                              | 触发                                     | 规范口径                                                                                                                                                                           |
| --------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Router Upgrade（REED → Router）   | 网络认为 Router 数量不足                 | 网络维持的 Router 数有目标区间（最多 32 个 Router ID；目标数量与抖动抑制由规范机制+实现参数共同控制，**上限 32 为 Thread Spec 口径**，升级触发阈值随 leader 配置，待核对具体数值） |
| Router Downgrade（Router → REED） | Router 数量过多/被 Leader 要求           | 同上，超配时降级收敛                                                                                                                                                               |
| Leader 更替                       | Leader 离网/故障，Router 间选出新 Leader | 选举依据 Leader Weight 与 Router ID（Thread Spec 口径；Weighting 可用 `leaderweight` 查看/设置）                                                                                   |
| 地址漂移                          | 升降级/换父                              | **RLOC 与 Child ID 随之变化**——5.2「RLOC 不作设备身份」的根源                                                                                                                      |

升级不是瞬时的：规范里有随机的抖动窗口避免集体升级风暴（实现可见为 `routerupgradethreshold` 类可配参数，OpenThread 命名以版本为准，待核对）。**这个抖动窗口正是 B 类「抖动」的温床**：Router 数恰好在阈值边缘时，节点升降级往复。

### router table 的读取

```bash
ot-cli> router table
| ID | RLOC16 | Next Hop | Path Cost | LQ In | LQ Out | Age |
| 44 | 0xb000   |       44 |         0 |     3 |      3 |   5 |   （格式示意）
| 21 | 0x5400   |       44 |         1 |     3 |      3 |   3 |
| 30 | 0x7800   |       63 |         2 |     2 |      2 |  10 |
Done
ot-cli> router list
[44 21 30]
Done
```

逐列读法：**Next Hop** 指向「我到该 Router 的下一跳」——Next Hop 等于自身 ID 表示直连；**Path Cost** 是到该 Router 的路径代价，跳数与链路质量的合成；**LQ In/Out** 链路质量三档（0-3，0 为未知，见 5.5）；**Age** 距上次路径信息刷新的时间。抖动诊断时重点看三件事：Router 列表长度是否反复增减（升降级震荡）、某个 ID 的 Next Hop 是否反复改写（路由震荡）、LQ 是否长期 ≤1（链路边缘）。

### 选举与权重的取证：leaderweight

Leader 选举依据是 **Leader Weight**（可设权重）与 Router ID 的组合排序（Thread Spec 口径），`leaderdata` 里的 `Weighting` 就是本分区 Leader 的权重。取证含义有二：

- 分区合并时谁说了算，看两分区的 Weighting——**想让某台设备稳定当「主导分区的 Leader」**，调它的权重即可（`ot-cli> leaderweight 128`，范围实现定义，OpenThread 口径待核对）；
- 反复「换 Leader」时，先查 Weighting 是否被误设为相同/极低值，导致裁决随链路波动来回翻转。

```bash
ot-cli> leaderweight        # 读本节点权重
64
ot-cli> leaderweight 128    # 提高权重(仅影响其成为 Leader 时的裁决优势)
Done
```

### 拓扑快照脚本：把「抖动」变成数字

抖动是时间维度的病，人眼盯串口必漏。给取证机挂一个最小采样循环（cron 或 shell while），把每天的拓扑写成快照序列：

```bash
# 每分钟采样一次 neighbor/router/state(真机经串口或 ot-ctl;伪代码骨架,格式示意)
while true; do
  echo "=== $(date +%H:%M:%S) ===" >> topo.log
  ot-cli state        >> topo.log
  ot-cli router list  >> topo.log
  ot-cli neighbor table >> topo.log
  sleep 60
done
```

事后 `diff`/`grep` 快照序列：`router list` 变化行数/小时 = 升降级震荡强度；某 RLOC16 出现次数占比 = 邻居稳定度。比记忆可靠的「变化率」由此而来。

## 5.4 分区（Partition）：两个 Leader 是怎么来的

### 成因：边界链路劣化把网络劈成两半

分区是 Thread 的**设计内行为**，不是崩溃：当网络内两组节点之间的边界链路质量劣化到 MLE 链路维持不住，各自内部仍互相连通时，每一边都会进行选举、产生自己的 Leader——两套 Partition ID、两套 Network Data 各自独立演化。Thread 用分区间「Leader Weight + Active Timestamp」规则在链路恢复后裁决合并（高权重/新 dataset 一方主导，Thread Spec 口径）。

```text
 健康:  [Leader-44]───[R21]───[R30]      一个分区,PID=X
 劣化:  [Leader-44]──✂(边界链路)──[R30]  劈成两半
        分区A PID=X,Leader 44        分区B PID=Y,Leader 30(新选)
 恢复:  链路重连 → 按 Weight/Timestamp 合并 → 回到一个分区
```

### 分区合并过程与「分区风暴」的坏味道

合并本身是自愈，但**频繁劈开-合并就是故障**（分区风暴），坏味道清单：

| 坏味道                  | 现象                                 | 指向                                              |
| ----------------------- | ------------------------------------ | ------------------------------------------------- |
| Partition ID 周期性翻转 | `leaderdata` 隔几分钟换一次          | 边界链路在合并阈值边缘徘徊（射频/干扰，回第九章） |
| 应用侧地址大面积失效    | 用 RLOC 做标识的集成每逢合并批量掉线 | 5.2 纪律被违反：该用 ML-EID                       |
| Network Data 反复覆写   | 前缀/服务忽有忽无（第六章出网症状）  | 两分区的 Network Data 合并冲突                    |
| active timestamp 争议   | 旧配置回流                           | 分区各自演化后 dataset 版本分歧                   |

### 取证三板斧对照

| 命令                   | 看什么                                      | 分区判读                                                         |
| ---------------------- | ------------------------------------------- | ---------------------------------------------------------------- |
| `ot-cli> leaderdata`   | Partition ID / Weighting / Leader Router ID | **两台对比 Partition ID**：不一致即分区实锤；ID 随时间翻转即风暴 |
| `ot-cli> netdata show` | 网络数据（前缀/路由/服务）版本与内容        | 两分区内容分歧=各自演化；合并后版本号跳变                        |
| `ot-cli> router table` | 全网 Router 集合与路径                      | 只看到本分区 Router；跨分区 Router 长期缺席=边界未恢复           |

外加一条空口交叉验证（第三章方法）：在中间地带抓 MLE Advertisement，若同一时刻出现两个不同 Partition ID 的 Advertisement 流，分区坐实且边界位置可见。消解分区的对策按序：恢复边界链路（物理部署/天线）→ 增补中继节点 → 检查信道干扰（第九章）。**不要**用「降低 Router 目标数」之类的参数去「治」分区——那是症状抑制。

### 一次完整分区-合并的观察样张（格式示意）

把三板斧按时间排开，分区-合并的全貌一目了然（数值为教学示意）：

```text
时间      leaderdata(Partition ID)   netdata 版本   router list
09:00     X (全网点一致)              v12            [44 21 30 17]
09:41     边界链路断:44/21 一边,30/17 一边
09:42     X,Weight 64  |  Y,Weight 48 v13|v5(各自) [44 21] | [30 17]
10:05     边界恢复,合并裁决:X 主导(Y 并入)
10:06     X (全网一致)                v15(合流跳变)   [44 21 30 17]
```

读法三条：Partition ID 分裂的时刻与物理事件（家具搬动/干扰源开机/设备断电）对齐；netdata 版本在合并后跳变是正常合流，不是攻击；**合并瞬间 RLOC 变化的节点**（30/17 若换了父子关系）就是集成侧「批量掉线」的肇事名单——再次呼应 5.2 的 ML-EID 纪律。

## 5.5 拓扑稳定性取证

### neighbor 表与变化率

```bash
ot-cli> neighbor table
| RLOC16 | Age | LQ In | LQ Out | Timeout | Frame Err | Msg Err |
| 0x1c00 |  23 |     2 |      2 |      60 |      1.2% |   0.0% |   （格式示意）
| 0x0e64 |  40 |     3 |      3 |      60 |      0.4% |   0.1% |
Done
ot-cli> child list          # 本 Router 的孩子(父视角)
```

稳定性取证的量化做法：定时采样 `neighbor table` 与 `router list`（如每分钟一次，cron/脚本），统计**单位时间变化率**。经验判据（工程经验口径，非规范数值）：健康网内相邻采样差异接近零；每小时邻居表反复洗牌、某 RLOC16 反复进出，就是 A/B 类病灶的量化指纹。Frame Err 比例持续偏高则把嫌疑直接交回射频层（第九章）。

### 链路质量三档

MLE 维护的双向链路质量（LQ）分 0-3 四档（0=未知，1/2/3 = 差/中/好，Thread Spec 口径）：

| LQ  | 含义 | 处置直觉                               |
| --- | ---- | -------------------------------------- |
| 3   | 好   | 正常                                   |
| 2   | 中   | 关注趋势；连续采样走低即预警           |
| 1   | 差   | 抖动高危：换父/升降级/丢包都在这档发生 |
| 0   | 未知 | 刚发现/长期未通，按断链处理            |

SED 父子关系里的 LQ 与 poll 节拍（A 类「忽隐忽现」的另一半原因）是 [[thread-debug-ch07-sleepy-end-device|第七章 SED 低功耗终端]] 的主场——本章只提醒一句：**拓扑图里「时有时无」的设备先确认是不是 SED**，别把正常休眠节拍误诊为掉线。

### state 变化日志

把 `state` 的变化变成日志流（OpenThread 日志等级设置见第二章），抖动现场的时间线（格式示意）：

```text
10:02:11 state: router   (RLOC16 0x5400)
10:17:38 state: detached         ← 被 Leader 要求降级/失联
10:17:52 state: child
10:19:03 state: router           ← 又升回来:阈值边缘震荡的典型样子
```

state 在 router/child/REED 之间一天内多次往复 = 升降级震荡（5.3 抖动窗口问题）；detached 单点闪断 = 链路瞬断；长期 detached = 回第四章入网排障。

### 汇总：稳定性取证的动作清单

| 动作         | 命令/方法                           | 判读口径                                |
| ------------ | ----------------------------------- | --------------------------------------- |
| 分区判定     | 两台 `leaderdata` 对比 Partition ID | 不一致=分区；翻转=风暴                  |
| 邻居稳定度   | 定时采样 `neighbor table` 算变化率  | 经验口径：反复洗牌即病灶（见 5.5 开头） |
| 链路质量趋势 | LQ In/Out 与 Frame Err 走势         | 持续 1 档/Frame Err 走高 → 射频层       |
| 角色稳定度   | state 日志流                        | router↔child 多次往复 → 升降级震荡      |
| 路由稳定度   | `router table` Next Hop 演化        | 反复改写 → 路由震荡                     |
| 交叉验证     | 空口抓 MLE Advertisement（第三章）  | Advertisement 流的有无/Partition 对照   |

## 5.6 教学案例：「两台设备互踢」复盘

**教学复盘案例，取材自常见故障模式综述。** 某实验室 6 台 FTD 组网，运维反馈「拓扑图里 5 号和 6 号轮流消失」，且偶发整个网出网（Border Router 侧前缀消失——第六章症状）。完整取证链：

**第一步：三板斧定界。** 在 5、6 号上分别 `leaderdata`：Partition ID 不一致——**分区实锤**（C 类），不是普通邻居抖动。`netdata show` 两边内容也开始分歧。

**第二步：定位边界。** `router table` 显示 5 号只看得见 {44,21}，6 号只看得见 {30}——网络沿「21 ↔ 30」这条边界被劈开。空口在中间过道抓 MLE Advertisement（第三章方法），同一时刻存在两个 Partition ID 的 Advertisement 流，且两侧 LQ 均在 1 档徘徊。

**第三步：查物理。** 中间过道一周前新装了一台 2.4 GHz 无线 AP（默认 20 MHz 占满信道 11 附近），而 mesh 恰好工作在信道 11（`dataset active` 回读）。干扰让边界链路 LQ 跌到 1，反复断开/恢复 → 反复分区/合并。合并瞬间若 Leader Weight 裁决换边，Network Data（前缀）随之漂移，Border Router 视角就是「全网偶发出网失效」。

**第四步：修复。** mesh 迁移信道（Pending Dataset 延迟切换流程，回 4.2 的 dataset 纪律）到现场干扰低的信道；边界两侧 LQ 回 3，Partition ID 恒定，拓扑图不再闪。复盘要点有二：其一，**互踢是症状，分区是病灶，干扰是元凶**——三层不要混为一谈；其二，Partition ID 翻转同时出现的「全网性症状」（出网失效），根源往往就是这一次次合并。

## 5.7 根因速查表

| 现象           | CLI 特征                               | 空口特征（第三章）    | 根因                         | 对策                                           |
| -------------- | -------------------------------------- | --------------------- | ---------------------------- | ---------------------------------------------- |
| 忽隐忽现       | 邻居表某 RLOC 反复进出                 | LQ 1 档、重传多       | 边缘链路                     | 增补节点/查天线（第九章）                      |
| 忽隐忽现       | 该设备是 SED、Timeout 与 poll 周期吻合 | 间歇性 Data Request   | 正常休眠节拍被误读           | 见第七章                                       |
| 升降级震荡     | state router↔child 往复                | MLE 消息频繁          | Router 数在阈值边缘          | 调整部署密度；核对升级参数（实现可配，待核对） |
| 路由震荡       | Next Hop 反复改写                      | 路径更新频繁          | 中间链路边缘                 | 同上                                           |
| 分区           | 两台 Partition ID 不同                 | 两套 Advertisement 流 | 边界链路劣化                 | 恢复链路/加中继                                |
| 分区风暴       | Partition ID 周期翻转                  | Advertisement 交替    | 干扰/部署反复越界            | 换信道（第九章）+物理整改                      |
| 合并后批量掉线 | RLOC 大面积变化                        | —                     | 集成误用 RLOC 当标识         | 改用 ML-EID                                    |
| 出网间歇失效   | netdata 前缀忽有忽无                   | —                     | 分区合并致 Network Data 漂移 | 先治分区，再查第六章                           |

> [!summary] 本章收束
> 拓扑排障三板斧是 `leaderdata`（分区判定）→ `netdata show`（网络数据一致性）→ `router table`（路径与链路质量），配齐 neighbor 变化率与 state 日志就能把「网内不稳」拆到可归因。记住两个纪律：**ping 哪个地址就是哪种证据**（Link-Local 测链路、RLOC 测路由、ML-EID 当身份）；**分区是设计内行为，频繁分区才是故障**。网内站稳之后，下一章走出家门——Border Router 与外网世界。
