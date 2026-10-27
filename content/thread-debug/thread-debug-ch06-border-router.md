---
title: "Thread 调试实战（六）：Border Router 与外网"
date: 2026-10-27 12:00:00
pin: false
description: "出网排障章：从「网内 ping 通但外网访问失败 / App 远程控制失效 / OTBR 重启后全网失联」三类现象切入，拆 OTBR 架构（otbr-agent/otbr-web、wpantund 的历史位置、RCP 模式拓扑）；讲出网机制——Border Router 前缀分发（PIO）、SLAAC 生成 GUA、NAT64/DNS64 打通 IPv4 世界、mDNS/Discovery Proxy 支撑手机发现设备；给出四段式排查阶梯（netdata 前缀→ping BR 的 RLOC→ping 外网地址→DNS 分段验证）与 otbr-agent 日志要点（格式示意）；覆盖家宽路由器的防火墙与 mDNS 跨网段常见坑，最后以「App 远程失效→NAT64 前缀丢失」的教学复盘取证链与根因速查表收束。ot-cli/OTBR 命令真实可执行，日志样例为格式示意。"
tags: [thread-debug, Thread, OpenThread, Debugging, Hardware]
---

# Thread 调试实战（六）：Border Router 与外网

> [!info] Thread 调试实战系列 0. [[thread-debug|系列索引]]
> 上一章：[[thread-debug-ch05-routing-topology|第五章：路由与拓扑]]
> **第六章：Border Router 与外网**（当前章）
> 下一章：[[thread-debug-ch07-sleepy-end-device|第七章：SED 低功耗终端]]

> [!note] 本章证据口径
> ot-cli 命令（`netdata show`/`ipaddr`/`ping` 等）以 OpenThread 官方 CLI 参考为准；OTBR 侧以 OpenThread Border Router 官方文档为准（Docker/apt 安装路线通用，wpantund 属历史 NCP 方案，正文标注）；NAT64/DNS64 引 RFC 6052/6146/6147 口径（IPv4-嵌入 IPv6 前缀经典值 64:ff9b::/96 与 Thread 生态自定义前缀并存时以现场 Network Data 为准）；SLAAC/PIO 引 RFC 4862/Thread Spec 1.3 口径。**OTBR 日志样例均为「格式示意」**；案例为**教学复盘案例，取材自常见故障模式综述**。

> [!tip] 一句话定位
> 出网故障先问「通行证（netdata 前缀）在不在」——在，往上游查；不在，回到 OTBR 本体。这一问能立刻把故障空间砍掉一半。

## 6.1 现场引入：三类「出不了网」

第五章保证网内站稳；本章的病都发生在**边界**——Thread 网与家庭/办公 IP 网的交界处：

| 类型                   | 典型描述                              | 问题域直觉                                         | 高频重灾区                |
| ---------------------- | ------------------------------------- | -------------------------------------------------- | ------------------------- |
| A：网内通、外网不通    | 「ot-cli 互 ping 全通，访问云端失败」 | BR 侧出网机制缺件（前缀/NAT64/默认路由）           | OTBR 刚装好、上游路由变化 |
| B：App 远程控制失效    | 「在家局域控制正常，出门就失联」      | 服务发现或云端路径断（mDNS/Discovery Proxy/NAT64） | 家宽路由器换固件/换网段   |
| C：OTBR 重启后全网失联 | 「树莓派一重启，所有设备显示离线」    | dataset/前缀漂移、Network Data 未恢复              | 断电恢复、自动升级后      |

与第四章 C 类「各成一网」的区别：本章 C 类的设备**彼此还在一个网里**（互 ping 通），失联的是「网与外界的桥」。取证总原则：**先证明 Thread 网完好，再证明边界在，再证明外网通**——顺序反了就会把 mesh 问题误诊成宽带问题，或反之。

```text
   Thread 世界              边界(BR)              IP 世界
[设备]──mesh──[BR:otbr-agent]──eth0──[家宽路由]──Internet
     第五章管辖        第六章管辖        6.5 管辖
```

## 6.2 OTBR 架构：otbr-agent / otbr-web / RCP 模式

### 组件分工

| 组件                    | 职责                                                                      | 挂了的表现                                       |
| ----------------------- | ------------------------------------------------------------------------- | ------------------------------------------------ |
| **otbr-agent**          | 跑 OpenThread 栈的 Border Router 角色：前缀分发、NAT64、Network Data 管理 | 网内瞬间群龙无首式异常；前缀消失                 |
| **otbr-web**            | Web 管理界面 + **Discovery Proxy**（mDNS 跨网段代理，服务发现路径）       | Web 打不开；手机发现不了 Thread 设备（App 症状） |
| mdns 折射层（Avahi 系） | 把网内 mDNS/DNS-SD 服务映射到本地 LAN                                     | 手机能看到 App 列表但连不上/发现超时             |
| wpantund（历史）        | 早期 NCP 模式下的网络管理守护（「Thread 的 wpa_supplicant」）             | 仅老版本路线出现；新 RCP 路线不需要              |

wpantund 的历史位置：OTBR 早期经 NCP（主机侧跑 wpantund 管理协议栈芯片），现主流为 **RCP 模式**——无线芯片只做 802.15.4 射频与 MAC（RCP），Thread 栈整个跑在树莓派上（`otbr-agent`），两者之间走 Spinel 协议（串口/USB/UART）。排障意义：**先确认这段「总线」是好的**，RCP 断连会伪装成全网失联。

### RCP 模式拓扑（text）

```text
┌────────────── 树莓派(OTBR 主机) ──────────────┐
│  otbr-web ── otbr-agent ──(Spinel/串口)── RCP │
│      │           │                             │
│   Discovery    Thread 栈(Border Router/        │
│   Proxy        Leader 可能在此)                │
└──────┼──────────┼──────────────────────────────┘
     LAN 侧      802.15.4 空口 ←→ [Thread 设备…]
```

状态快查（Linux 侧命令真实可执行）：

```bash
# 服务状态(Docker 路线用 docker ps 对应容器;apt/systemd 路线)
systemctl status otbr-agent
# RCP 链路与 Thread 状态(经 otbr-agent 的控制接口,具体 CLI 入口随安装路线,官方文档口径)
ot-ctl state            # 期望: leader 或 router
ot-ctl netdata show     # 前缀在不在(6.4 展开)
```

### 版本/模式自查清单

现场接手一台来历不明的 OTBR 时，先花两分钟把「是什么模式、什么版本」钉死，避免拿 NCP 时代的文档排 RCP 时代的障：

| 自查项          | 命令/位置                                   | 期望                                                  |
| --------------- | ------------------------------------------- | ----------------------------------------------------- |
| otbr-agent 版本 | `otbr-agent --version`（或容器 tag）        | 记录入档，变更管理基线                                |
| RCP 固件版本    | `ot-ctl version`                            | 与 otbr-agent 版本匹配（官方兼容矩阵口径）            |
| 运行模式        | systemd 单元/Docker compose                 | RCP（无 wpantund 单元）或旧 NCP（有 wpantund）        |
| 上行接口        | otbr-agent 启动参数的 `-B`（绑定的 LAN 口） | 与实际有网的接口一致——**绑错接口=前缀发了但上游不通** |

「RCP 固件与 otbr-agent 版本错配」是自建 OTBR 的高频暗坑：Spinel 协议行为随版本演进，错配常表现为 RCP 频繁复位、`ot-ctl state` 间歇 unreachable——伪装成「全网不稳」，而 mesh 本身无辜。

## 6.3 出网机制：前缀分发、SLAAC、NAT64/DNS64、mDNS

### 前缀分发与 SLAAC 生成 GUA

Border Router 把一个 Mesh-Local 之外的前缀（现场通常是运营 ULA 或家宽 IPv6 前缀派生）放进 **Network Data**；网内设备凭前缀信息（PIO 语义，RFC 4862 SLAAC 口径）自拼全局地址（GUA）。这个前缀就是「出网通行证」的载体——**Network Data 里没有它，全网的 GUA 集体消失**：

```text
BR → Network Data 发布前缀 fd12:3456::/64 (PIO 语义)
设备 SLAAC → 自生成 fd12:3456::xxxx(GUA)
设备 → 目的地在外网? → 默认路由指向 BR 的 RLOC → BR 转发
```

### NAT64/DNS64：IPv4 世界的桥

家宽上游与云端服务器仍以 IPv4 为主时，走 NAT64：BR 维护 IPv6↔IPv4 转换。地址合成引 RFC 6052：把 IPv4 地址嵌入 96 位前缀之后（公网经典前缀 64:ff9b::/96；Thread/OTBR 实现可用自定义 NAT64 前缀，以现场 Network Data 为准）。DNS64（RFC 6147）则把 A 记录合成为上述前缀的 AAAA，让只认 IPv6 的设备拿到可路由地址。取证含义：**NAT64 前缀是 Network Data 里的一条独立数据**，会单独地「有/没有」——6.6 案例正是它单独丢失。

合成与转换的手算示例（教学示意，帮助看懂段3取证命令）：

```text
目标 IPv4:  192.0.2.1  → 十六进制 c0.00.02.01
合成 IPv6:  64:ff9b::c000:0201
            └─ 96 位 NAT64 前缀 ─┘└─ 32 位 IPv4 ─┘

设备视角(纯 IPv6):  发往 64:ff9b::c000:0201
BR 视角(NAT64):     剥掉 96 位前缀 → 还原 192.0.2.1 → IPv4 转发
回程:               对应会话表(RFC 6146 状态化转换)逆映射回 IPv6
```

配套的 DNS64 判别：同一域名，问出 AAAA 且地址落在 NAT64 前缀内 = DNS64 生效（BR 代答合成）；只有 A 没有 AAAA = DNS64 未参与。OpenThread 侧 `dns resolve` 的返回地址直接可读前缀，一条命令完成判别。

### mDNS/Discovery Proxy：手机怎么「发现」设备

手机 App 找 Thread 设备靠 DNS-SD/mDNS 服务记录；但手机在 LAN、设备在 Thread 网，跨网段多播不通，于是由 **otbr-web 的 Discovery Proxy** 把 Thread 网内的 mDNS 记录折射到 LAN（反向亦然）。这条链断裂时，设备的局域控制与 Matter 配网发现全灭，但「数据面」毫发无损——**发现路径与应用数据路径是两条独立的命**，排障时分开测。

## 6.4 排查阶梯：从 netdata 到 DNS 的分段验证

四段阶梯，每段一条命令、一个明确判据，断在哪段问题就在哪段：

```text
段1  netdata 前缀在不在(通行证)
段2  ping BR 的 RLOC(mesh 路由到边界)
段3  ping 外网地址(边界转发/NAT64)
段4  DNS 解析(名字服务)
```

```bash
# 段1:在任一网内设备上
ot-cli> netdata show        # 或 netdata show -p 只看前缀
# 期望看到:前缀条目(PIO 语义) + NAT64 前缀条目 + 默认路由(R 段)
# 缺前缀 → 出网通行证没了,回 6.2 查 otbr-agent;缺 NAT64 前缀 → IPv4 云端必失联

# 段2:ping Border Router 的 RLOC(第五章地址纪律:RLOC 测路由)
ot-cli> ping fdab:1234::ff:fe00:4400 4 2   # <地址> <次数> <间隔秒>
# 不通 → 问题在 mesh/BR 的 Thread 侧,回第五章;通了 → 边界可达

# 段3:ping 外网地址(直接用 IPv4 合成地址,绕开 DNS)
ot-cli> ping 64:ff9b::c000:0201 4 2        # 以 64:ff9b::/96 + 192.0.2.1(示意)合成
# 不通 → BR 侧 NAT64/上行路由问题,回 6.2/6.5

# 段4:DNS 分段
ot-cli> dns resolve mydevice.local          # 网内名字(Discovery 路径)
ot-cli> dns resolve example.com             # 外网名字(DNS64 路径)
```

BR 侧（树莓派）的日志要点（**格式示意**，otbr-agent 日志等级可用环境变量/参数调整，官方文档口径）：

```text
otbr-agent[712]: BorderRouter: Netif 'wpan0' link local address fe80::... (示意)
otbr-agent[712]: Plat: Uart read/write...            ← RCP 总线流量
otbr-agent[712]: otrbr-agent: Nat64 state: PREFIX    ← NAT64 前缀状态行(实现随版本)
```

重点盯三类行：RCP 串口读写错误（总线断，伪装成全网失联）、Network Data/前缀增删行（通行证变化时刻）、Nat64 state 行（前缀存在与否）。开 debug 级别后行数剧增，现场建议先 info 定位再升 debug 取证。

### 决策树：把四段结果翻译成结论

```text
netdata 有前缀?
 ├─ 否 → otbr-agent 侧问题(服务未起/RCP 断/上行接口绑错) → 6.2 自查清单
 └─ 是 → ping BR 的 RLOC 通?
      ├─ 否 → mesh 侧问题 → 回第五章(注意:BR 也是网内成员,先确认它 state)
      └─ 是 → ping 外网合成地址通?
           ├─ 否 → NAT64 状态/上行路由 → 6.5 家宽侧 + BR 日志
           └─ 是 → DNS 解析分段
                ├─ 网内名字失败 → Discovery Proxy/mDNS 折射
                └─ 外网名字失败 → DNS64(查 NAT64 前缀条目)
```

这棵树的每个叶子都对应一个具体组件，配合 6.2 的自查清单与 6.5 的家宽清单，四段阶梯走完基本无死角。留一条基线纪律：**部署验收时把 `netdata show` 输出留档**，此后任何「出网异常」先 diff 基线——6.6 案例能十分钟定位，靠的正是有留档可比。

## 6.5 家宽路由器的角色：防火墙与 mDNS 坑

OTBR 的 eth0 插在家庭 LAN 里，家宽路由器是 OTBR 的「上游守门人」，两类高频坑：

| 坑                          | 机理                                                                            | 症状                                                         | 处置/取证                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| **AP/客户端隔离**           | 家宽路由把 LAN 内主机互相隔离                                                   | OTBR 有网但手机 ping 不到 OTBR；Discovery 反向折射手机收不到 | 手机与树莓派互 ping；关隔离验证                                                                |
| **mDNS 不跨 VLAN/网段**     | 多播不路由，跨 VLAN 即断                                                        | App 在同一 WiFi 能发现设备，跨 VLAN/访客网就超时             | 手机与 OTBR 确认同网段；网关侧开 mDNS 反射（如 Avahi reflect / 路由器 mDNS relay，实现随品牌） |
| 防火墙阻断高位端口/特定协议 | 远程接入（Thread 的「远程访问经云端」路线不经此，但 Matter 控制器直连路线需要） | 局域控制正常、远程失效                                       | 抓 LAN 侧包确认 SYN 出去无回                                                                   |
| ISP 光猫桥/路由模式变更     | 上游换网段、换 NAT 方式                                                         | OTBR 拿到新网段，旧静态配置/端口映射全失效                   | OTBR 侧 `ip addr` 与路由表比对                                                                 |

一条纪律：**把 OTBR 当成 LAN 里的一台普通 Linux 主机来测**（ping/路由/mDNS 全按主机标准），测通了再考虑 Thread 侧——很多「Thread 出网问题」其实是树莓派本身在家宽网里就孤岛了。

主机标准四连（树莓派上，命令真实可执行）：

```bash
ip -br addr                 # 上行接口拿到地址了吗(IPv4/IPv6 各看一眼)
ip route show default       # 默认路由指向谁(网关变更会先反映在这)
ping -c 3 192.168.1.1       # 网关通不通(按现场网段改)
ping -c 3 223.5.5.5         # 出公网通不通(绕开 DNS)
avahi-browse -art | head -40 # 本 LAN 的 mDNS 服务全景(手机发现路径的地基)
```

四连的判读：接口无地址 → 上游/DHCP 问题；有地址无默认路由 → 上游配置；ping 网关通而公网不通 → 家宽上行/账号；mDNS 列表为空或缺失 OTBR 自己发布的服务 → Avahi/折射层，进 6.4 决策树的发现分支。这四条把「边界世界」里最容易被误算到 Thread 头上的一半问题提前筛掉。

## 6.6 教学案例：App 远程失效 → NAT64 前缀丢失

**教学复盘案例，取材自常见故障模式综述。** 现象：30 台 Thread 设备，局域控制一切正常；App 出门后远程全部超时；两天前现场刚给 OTBR 主机做过一次系统升级+重启。

**第一步：判层。** 网内 `ot-cli` 互 ping 全通、`state` 稳定——mesh 完好（排除第四/五章），问题锁边界（本章 A/B 类）。App 远程失效通常指向「设备↔云端」路径：DNS → NAT64 → 上行。

**第二步：跑阶梯。** 段1 `netdata show`（格式示意）：

```text
Prefixes:
fd12:3456:7890::/64 paros onlow 400 mc s      ← 现场前缀在
Routes:
fdab::/64 s mc
Services: ...
```

对比升级前的留档：**NAT64 前缀条目消失了**（且默认路由段尚在）。段2 ping BR RLOC 通；段3 ping `64:ff9b::` 合成的云端 IPv4 地址不通；段4 `dns resolve example.com` 无 AAAA 返回（DNS64 无前缀可用）。四段结果自洽：断在 NAT64 前缀缺失这一环。

**第三步：归因到根。** OTBR 侧（树莓派）`ot-ctl netdata show` 同样缺 NAT64 前缀——不是 mesh 分发问题，是 BR 根本没发布。查 otbr-agent 日志发现升级后 NAT64 相关组件未能随服务拉起（前缀发布前置条件不满足，实现细节随版本，官方文档口径），证据链：系统升级（变更）→ 重启 → NAT64 组件未起 → 前缀缺席 → DNS64 失能 → 设备无法合成云端地址 → 远程全断。

**第四步：修复与验证。** 修正服务依赖后重启 otbr-agent，`ot-ctl netdata show` 中 NAT64 前缀回归 → 网内设备 `netdata show` 数秒内同步 → 段3/段4 逐段复测通过 → App 远程恢复。复盘要点：①局域正常+远程失效，第一嫌疑就是 **NAT64/DNS64 与云端路径**，而非 mesh；②Network Data 的变更会自动全网同步——**网内一行命令就能验证 BR 侧假设**，这是 Thread 排障独有的便利；③变更管理：OTBR 升级后必须跑一遍 6.4 阶梯作为回归。

### 取证链汇总（本章交付物形态）

| 步  | 动作                          | 观测（格式示意）       | 结论贡献                     |
| --- | ----------------------------- | ---------------------- | ---------------------------- |
| 1   | 网内互 ping + state           | 全通、状态稳定         | mesh 无辜，锁定边界          |
| 2   | `netdata show` 对比留档       | 缺 NAT64 前缀条目      | 通行证缺页，断点初定         |
| 3   | 段2 ping BR RLOC              | 通                     | mesh→边界可达                |
| 4   | 段3 ping 64:ff9b 合成地址     | 不通                   | NAT64 转发路径断             |
| 5   | 段4 `dns resolve example.com` | 无 AAAA                | DNS64 连坐失效，与缺前缀自洽 |
| 6   | otbr-agent 日志 + 服务状态    | NAT64 组件未随升级拉起 | 根因落地（变更引入）         |
| 7   | 修复后逐段复测                | 前缀回归、四段全通     | 闭环                         |

## 6.7 根因速查表

| 现象                   | 断在阶梯哪段    | CLI/日志特征                | 根因                           | 对策                             |
| ---------------------- | --------------- | --------------------------- | ------------------------------ | -------------------------------- |
| 外网全不通             | 段1             | netdata 无前缀              | otbr-agent 未发布前缀/RCP 断连 | 重启 otbr-agent；查 RCP 串口     |
| IPv4 云端不通          | 段1/段3         | 缺 NAT64 前缀               | NAT64 组件未起/前缀未发布      | 修服务依赖；核对 Network Data    |
| 名字解析失败           | 段4             | DNS64 无 AAAA               | 同上（前缀缺席连坐）           | 同上                             |
| 局域控制正常、发现失败 | 段4（网内名字） | `.local` 解析超时           | Discovery Proxy/mDNS 折射断    | 查 otbr-web 与 LAN 隔离（6.5）   |
| mesh 内 ping BR 失败   | 段2             | RLOC ping 不通              | 第五章问题伪装成出网故障       | 回第五章三板斧                   |
| OTBR 重启后全网失联    | 段0（网全断）   | state 异常/RCP 报错         | RCP 总线断/dataset 漂移        | 重插 RCP；核对 dataset（第四章） |
| 跨网段手机发现不了     | —               | 手机能 ping OTBR 但发现超时 | mDNS 不跨 VLAN                 | 同网段验证；mDNS 反射            |
| 升级/换路由后批量失效  | 段1             | 前缀内容与留档不符          | 上游/配置变更漂移              | 留档 netdata 基线，diff 取证     |

> [!summary] 本章收束
> 出网排障一条主线：**netdata 是通行证登记处**——前缀在不在、NAT64 前缀在不在，两眼一看便知问题属于 Thread 世界还是边界世界；四段阶梯（前缀→BR RLOC→外网地址→DNS）每段都有单条命令判据。局域与远程分治、发现路径与数据路径分治、主机标准先于 Thread 标准，三条纪律能拦下大半误诊。边界打通之后，网要「省着用」——下一章进入 SED 低功耗终端的节拍世界。
