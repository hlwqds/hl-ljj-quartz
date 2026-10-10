---
title: "P2P 网络深度解析（八）：BitTorrent——分片、激励与去中心化"
date: 2026-10-10 12:00:00
description: "装配前七章的全部零件：bencode 与 .torrent 文件解剖（infohash 怎么来）、tracker HTTP 协议、peer wire protocol 的握手与九条消息（含保留字节的 DHT/扩展协议能力位）、piece 与 block 的两级分片、稀缺优先与 endgame 的分片策略、tit-for-tat + 乐观反掐 choke 算法如何治免费搭车；再加 BEP10 扩展（ut_pex/ut_metadata）、magnet 与 Mainline DHT——把最后的 tracker 也做掉。"
tags: [p2p, network, bittorrent, dht, protocol, series]
---

> [!info] P2P 网络深度解析系列 0. [[p2p-deep-dive|系列索引]] 1. [[ch01-p2p-overview|第一章]] 2. [[ch02-first-peer-direct-connect|第二章]] 3. [[ch03-nat-fundamentals|第三章]] 4. [[ch04-nat-traversal|第四章]] 5. [[ch05-unstructured-p2p-search|第五章]] 6. [[ch06-dht-chord|第六章]] 7. [[ch07-kademlia|第七章]] 8. **第八章：BitTorrent——分片、激励与去中心化**

# P2P 网络深度解析（八）：BitTorrent——分片、激励与去中心化

前七章的零件在 BitTorrent（Bram Cohen，2001）里全部到齐：分块传输（ch02）、TCP 直连（ch02）、DHT（ch06/ch07）、"控制面中心化 + 数据面对等化"（ch05 超级节点的教训）、以及免费搭车这道压轴题（ch05 的测量）。BitTorrent 的回答是一套**经济激励协议**：你上传，我才给你下载。这一章拆完整链路：种子文件与 bencode（8.1）、tracker 协议（8.2）、peer 间线缆协议（8.3）、分片选择策略（8.4）、choke 算法（8.5）、去中心化终局——扩展协议、magnet 与 DHT（8.6）。

---

## 8.1 种子文件：bencode 编码的分布式清单

### 1. bencode：四种类型打天下

.torrent 文件是 bencode（Bencode，BEP 3）编码的字典。全部语法一屏装完：

```text
整数    i42e          （i 开头 e 结尾，支持负数 i-3e）
字节串  4:spam        （长度前缀 + 冒号 + 原始字节）
列表    l4:spami42ee  （l ... e）           → ["spam", 42]
字典    d3:bar4:spam3:fooi42ee  （d ... e） → {"bar":"spam","foo":42}
```

规则朴素到可以用 20 行解析器实现——这是刻意的设计：**种子要被任意设备上的任意语言轻松读写**。另有一条隐藏纪律：字典键必须按字典序排列（bencode 的规范形式），否则 infohash 对不上（见下）。UTF-8 键（如 `name.utf-8`）为兼容旧客户端与中文文件名并存。

### 2. metainfo 结构：文件被切成什么样

```text
.torrent (bencode dict)
├─ announce:      "https://tracker.example.com/announce"     ← tracker 地址
├─ announce-list: [[...], [...]]                              ← 多 tracker 备份（BEP 12）
├─ creation date, comment, created by ...
└─ info:                                                      ← 核心，哈希就是它的
   ├─ name:         "ubuntu-24.04-desktop-amd64.iso"
   ├─ piece length: 2097152                                   ← 每片 2 MiB
   ├─ pieces:       <20 × N 字节的 SHA-1 拼接>                 ← 每片一个哈希
   └─ (单文件) length: 6143258624
      (多文件) files: [{length, path:[...]}, ...]              ← 二选一
```

**infohash = SHA-1(bencode(info 字典))**——整个 BitTorrent 世界的身份系统：tracker 用它登记种子（8.2），peer 握手用它互认（8.3），DHT 用它做键（8.6），magnet 链接里 `urn:btih:` 后面就是它。改一个字节的长度或文件名，infohash 就变——**身份与内容绑定，而非与位置绑定**（IPFS 把这个思想推到极致）。

分片尺寸是工程折中：片大了，哈希列表短（省元数据），但**下载粒度粗**——坏一片重传 2 MiB，且最后一片难以边下边传；片小则反之。现代客户端常配 256 KiB–4 MiB，按总大小自动选择。BEP 52（v2 种子，2020）把每片再按 16 KiB 叶子做 Merkle 哈希树（SHA-256），验证粒度更细并支持单文件内范围下载，与 v1 并存兼容。

---

## 8.2 tracker：HTTP 上的点名册

客户端向 tracker 发一个普通的 HTTP GET（BEP 3），把"我是谁、我有什么、我下了多少"一次交代：

```text
GET /announce?info_hash=%40%9C%F7...   ← 20 字节 infohash，URL 编码（它不是可打印文本）
             &peer_id=-TR4050-xxxxxxxxxxxxxxx     ← 客户端自造的 20 字节身份
             &port=51413                            ← 可被连入的端口（NAT 后见 ch03 苦笑）
             &uploaded=1048576&downloaded=0&left=0  ← 三本账：上传/下载/剩余
             &compact=1&numwant=50                  ← 要紧凑格式、要 50 个 peer
             &event=started                         ← started / stopped / completed

响应（bencode dict）：
d8:intervali1800e         ← 30 分钟内再来问（别刷屏）
 8:completei42e           ← 做种者（seeder，有全文件）数量
 10:incompletei1337e      ← 下载者（leecher）数量
 5:peers<300 字节>        ← 50 × 6 字节：4 字节 IP + 2 字节端口，紧凑二进制拼排e
```

拿到 50 个 `ip:port`，进入下一阶段：跟每一个握手。tracker 全程只做点名，一个字节的电影也不搬运——ch05 超级节点哲学的纯控制面版本。UDP tracker 协议（BEP 15）把这套问答搬到 UDP 上省开销（一次 announce 从 HTTP 的数个 RTT 压到一个），大型 tracker 几乎全是 UDP。

> [!tip] 可观测性：亲手拆一个种子
>
> ```bash
> $ transmission-show ubuntu-24.04-desktop-amd64.iso.torrent
> NAME: ubuntu-24.04-desktop-amd64.iso
> Hash: 409cf7d8...          ← 这就是 infohash
> Piece Size: 2 MiB / Pieces: 2930
> ```
>
> 装个 transmission-cli（或 aria2）即可复现；抓包看 tracker 交互用 Wireshark 过滤 `http.request contains "announce"` 或 UDP tracker 的 `bt-utp`/端口。torrent 文件本身也可以 `python -c` 一行 bencode 解码直接打印 info 字典——它是明文的。
>
> > [!tip] 🧪 配套实验：p2p-labs/ch08-mini-bt
> > 本章协议链路的四进程最小闭环：maketorrent（bencode + 逐片 SHA-1 + infohash）、tracker（HTTP announce 点名）、bt（68 字节握手 → bitfield → interested/unchoke → request/piece，16KiB 块 × 8 深度流水线，逐片 SHA-1 验收）。实测 300000B 随机文件 10 片全验收、下载件与源文件 SHA-1 一致；run.log 里还留着三次翻车实录（最后一次正是 piece 级哈希当场拦下 off-by-one）。源码直达：[bt.c（代码浏览）](/static/code/#/p2p-labs/ch08-mini-bt/bt.c)、[bencode.c](/static/code/#/p2p-labs/ch08-mini-bt/bencode.c)、[完整工程](/static/code/#/p2p-labs/ch08-mini-bt/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/p2p-labs/ch08-mini-bt)。

---

## 8.3 peer wire protocol：TCP 上的九条消息

### 1. 握手：reserved 字节是能力协商总线

与某个 peer 建立 TCP 连接后第一件事：

```text
0                19                              27    35    55
┌────────────────┬──────────────────────────────┬─────┬─────┐
│ 0x13 (=19)     │ "BitTorrent protocol"        │保留8│infoh│ peer_id (20B)
└────────────────┴──────────────────────────────┴─────┴─────┘
 reserved 的 8 字节按位协商能力（0 为不支持）：
   reserved[7] & 0x01 → 支持 DHT（BEP 5，8.6 节的入口）
   reserved[7] & 0x04 → 支持快速扩展（BEP 6：HAVE_ALL/SUGGEST/REJECT_…）
   reserved[5] & 0x10 → 支持扩展协议（BEP 10：ut_pex/ut_metadata 的承载层）
info_hash 不同 → 立即断开（连错人了）
```

### 2. 消息帧：长度前缀 + 单字节 ID

握手之后所有消息统一成帧：`4 字节长度（不含自身）+ 1 字节消息 ID + 载荷`。长度为 0 是 keepalive（保活，两分钟一次静默心跳）。九条核心消息（ID 0–9）：

| ID  | 消息           | 载荷                 | 语义                                 |
| --- | -------------- | -------------------- | ------------------------------------ |
| 0   | choke          | —                    | 我不再响应你的请求（掐断）           |
| 1   | unchoke        | —                    | 解除掐断，你可以请求了               |
| 2   | interested     | —                    | 我对你手里的片感兴趣                 |
| 3   | not interested | —                    | 你没有我缺的片                       |
| 4   | have           | piece 索引           | 我刚拿到这一片（增量广播位图）       |
| 5   | bitfield       | 位图                 | 握手后第一包：我有哪些片（全量声明） |
| 6   | request        | index, begin, length | 请求某片从 begin 开始的 16 KiB 块    |
| 7   | piece          | index, begin, data   | 数据本体                             |
| 8   | cancel         | index, begin, length | 撤回请求（endgame 去重用）           |
| 9   | port           | DHT 端口             | "我的 DHT 监听在这个口"（BEP 5）     |

### 3. 两级分片：piece 与 block

注意 request 请求的**不是整片**而是片内的 **16 KiB 块（block）**——2 MiB 的 piece 切成 128 个 block 流水线请求（典型在途 5–10 块防单流饿死）。两级结构各司其职：**piece 是校验单位**（SHA-1 以片为粒度，凑齐一片才能验、验过才算资产），**block 是传输单位**（小到可以流水线、可以跨 peer 拆单）。凑不齐整片的散块不是资产——这直接塑造了 8.4 的选择策略。

---

## 8.4 分片选择：稀缺优先与收官模式

下载器手里有一张需求位图（缺哪些片），网络里每个 peer 有供给位图（有哪些片）。先要哪片？策略不对会死在两个坑里：下了没人要的片（无法边下边传）或留一堆半成品片到最后干等。BitTorrent 的三段式：

1. **随机开片**：冷启动时随机挑一片下完——手里尽快有第一张"完整资产"，进入可上传状态（激励机制要求你有东西可换）。
2. **稀缺优先（rarest first）**：统计每片在网络中的持有数，优先下最稀缺的。两个目的：**健康度**（最稀缺的片丢了就永久缺块，趁还有人有时抢下来，swarm 集体容错）与**交换价值**（稀缺片人人想要，攥住它才有谈判筹码——激励与策略在此咬合）。
3. **严格优先 + endgame**：开了的片优先下完（半成品不是资产）；只剩最后几片时进入 endgame 模式——**对缺的块同时向所有 peer 发请求**，谁先到用谁的，其余用 cancel 撤销。平时不这样做是浪费（重复传输），收官时这样做是买保险（不赌任何单 peer 的尾部延迟）。

```text
下载进度（片为单位，■ 已验 ✚ 半成 □ 缺失）：
■■■■■✚✚□□□□□□□□□□□  ← 常态：rarest first 挑缺片，已开的优先补完
■■■■■■■■■■■■■■✚✚✚✚  ← endgame：最后几片全网广播请求+cancel 去重
```

---

## 8.5 choke 算法：tit-for-tat 的经济学

### 1. 问题：把上传带宽发给谁

ch05 的测量说过：没有激励，70% 的人只下不上。BitTorrent 的解药是把"能否下载"与"是否上传"挂钩——**你给我供血，我才给你供血**：

- 每个 peer 对每个连接维护两个方向的状态：choke/unchoke（我是否给他传数据）、interested/not interested（他是否想要我的数据）。
- **只有被 unchoke 且 interested 的连接才发生传输**。choke 不是断线，是"暂停配给"——状态随时可逆，博弈每一轮重开。

### 2. 算法本体

每 10 秒（一个 unchoke 周期）重算一次：把**有限的上传槽位**（默认 4 个）分给"过去一段时间给我上传最多的那 4 个 peer"——纯粹按贡献排队，这就是 tit-for-tat（一报还一报）。再加三个补丁：

- **乐观反掐（optimistic unchoke）**：每 3 个周期（30 秒）随机挑一个被掐的 peer 无条件 unchoke。没有它，新人（还没来得及证明自己）永远入不了局，且"只对强者互吹"的裙带网络会锁死。**给陌生人一次机会**是重复囚徒困境里合作涌现的经典条件。
- **snub（冷落）**：某 peer 60 秒没给我任何块 → 判定它掐了我 → 我单方面也不再把它当供血方排序，防止被白嫖占槽。
- **做种者（有全文件者）的算法换轨**：没有下载需求就没有 tit-for-tat 依据，改为优先服务**下载进度最低**的 peer（雪中送炭）或对等回馈曾给自己供过血的（投桃报李，anti-leech 扩展对只下不传的连极端限速）。

### 3. 这个机制的聪明与局限

聪明在于**去信用化**：不需要账号、不需要历史、不需要全局记账，合作均衡只由"过去 10 秒你给了我什么"这个本地可观测变量维持——ch10 的一切攻击（女巫、伪造 peer_id）打不进这个局部博弈，但**免费下载依然可能**：多开连接摊薄上传、纯 leech 客户端依赖乐观反掐苟活、私有 tracker 用账号 Ratio 制补课。BitTorrent 没有消灭搭车，只是把搭车成本提高到"网络仍然健康"的水位之下——对一个无准入协议而言，这是及格线以上的好成绩。

---

## 8.6 去中心化终局：扩展协议、magnet 与 DHT

### 1. BEP 10 扩展协议：握手之上的协商层

两个 peer 若都置了 `reserved[5] & 0x10`，握完手各发一条 `extended handshake`（ID 20）：一个 bencode 字典，`m` 字典声明"我支持哪些扩展、各用什么扩展 ID"。两个明星扩展：

- **ut_pex（PEX，peer exchange）**：peer 间定期互喂"我最近连过的活跃 peer 列表"——tracker 从此只需被访问一次，后续的 peer 发现在 swarm 内部自增殖（ch02 广播发现的对等网络版）。
- **ut_metadata**：向 peer 逐块讨要 .torrent 的 info 字典本身——**没有种子文件也能开下**，这就是 magnet 的底层支撑。

### 2. magnet 链接：一个 infohash 打天下

```text
magnet:?xt=urn:btih:409CF7D8...      ← 唯一必需：infohash（身份）
       &dn=ubuntu-24.04-desktop      ← 显示名（装饰）
       &tr=https://tracker.../announce ← tracker 提示（可选，DHT 之外的路）
```

启动流程：拿 infohash 问 DHT "谁有这个 hash"（get_peers，找到存有该键的 k 近节点）→ 拿到 peer 列表 → 握手 + ut_metadata 凑齐 info 字典 → 校验其 SHA-1 恰等于 infohash → 转入正常下载。**信息的最小种子就是一个 20 字节的哈希**——分发可以贴在任何能贴文本的地方（网页、邮件、推特）。

### 3. Mainline DHT：Kademlia 的 BitTorrent 方言

BEP 5 把 ch07 的骨架直接落地：节点 ID 160 位、k=8、Kademlia 四动词改名为 `ping / find_node / get_peers / announce_peer`，键就是 infohash。announce 带一次性 token 防第三方伪造登记（get_peers 时目标节点发 token，announce 时验证）。tracker 就此从"单点依赖"降级为"加速提示"——2010 年代各大国 tracker 关停浪潮后，BT 生态靠 DHT+PEX+magnet 活到今天，这是 ch01"每一代杀死上一代单点"叙事的最新一环。

> [!note] PCDN：BitTorrent 的工业变装
> 国内直播与网盘厂商的 PCDN（P2P 分发）本质上是"受控 swarm"：中心调度器当 tracker、播放器当 peer、分片与稀缺优先照抄 BT，只是激励从 tit-for-tat 换成积分/会员。协议考古可以直接变现，这是 P2P 工程史的有趣脚注。

## 8.7 小结

- 种子文件是 bencode 字典；**infohash = SHA-1(bencode(info))** 是贯穿 tracker、握手、DHT、magnet 的统一身份；身份绑定内容而非位置。
- tracker 是纯控制面（HTTP/UDP 点名册），compact peers 是 6 字节二进制拼排；UDP tracker（BEP 15）是大型站标配。
- 线缆协议：19 字节握手（reserved 字节按位协商 DHT/快速/扩展协议）→ 长度前缀成帧的九条消息；**piece 是校验单位、block（16 KiB）是传输单位**的两级分片是全部传输策略的地基。
- 分片选择三段式：随机开片（尽快获得可上传资产）→ 稀缺优先（集体容错 + 交换筹码）→ 严格优先与 endgame（收官去重）。
- choke 算法用 10 秒周期的 tit-for-tat 把合作建立在**本地可观测变量**上（无需信用系统），乐观反掐给新人入场券，snub 防白嫖，做种者换轨雪中送炭——它没消灭搭车，只是把成本抬过健康线。
- 去中心化三件套：BEP10 扩展（ut_pex 自增殖 peer、ut_metadata 讨元数据）、magnet（最小种子=一个哈希）、Mainline DHT（Kademlia 方言，token 防 announce 伪造）——tracker 从依赖降级为提示。

数据层与激励层都齐了，下一章换战场：把 P2P 塞进浏览器的沙箱里——信令怎么走、SDP 里藏了什么、ICE（ch04）如何被产品化、DTLS 为什么强制、DataChannel 又为什么是 SCTP。[[ch09-webrtc|第九章：WebRTC——浏览器里的 P2P 复兴]]。
