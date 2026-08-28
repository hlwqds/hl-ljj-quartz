---
title: "lwIP 深度解析（十七）：ethernetif 移植指南：把 lwIP 搬上任意 MCU"
date: 2026-08-26
description: "回到协议栈的起点拆最小契约面：官方 ethernetif 骨架的 low_level 三件套与 netif 对接点，openeth 四百行驱动逐行走读（描述符环、ownership 位、ISR→任务→邮箱完整 RX 时序），STM32 类 MCU 移植清单（DMA 环设计/pbuf 直达 vs 拷贝/D-cache 一致性/链接脚本 DMA 段）与可直接抄的 low_level_input/output 骨架；实验用 esp_eth_update_input_path 与 linkoutput 换指针装齐驱动层全部观察点，实测 TX 环满注入下 ERR_IF 穿透成 errno=-1 裸值 vs ERR_MEM→ENOMEM 的差异，以及 RX 任务降速 30ms/帧时描述符环崩塌到精确 33fps 的洪峰实验。"
tags: [lwip, network, esp32, esp-idf, qemu, ethernetif, porting]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 17. **第十七章：ethernetif 移植指南：把 lwIP 搬上任意 MCU**

# lwIP 深度解析（十七）：ethernetif 移植指南：把 lwIP 搬上任意 MCU

这一章回答三个问题：**把 lwIP 接到一块新网卡上，契约面到底有多小**（答案是一组函数指针和三段回调，不超过一页纸）、**反过来 lwIP 已经替驱动做掉了什么**（帧格式判别、ARP 解析、pbuf 生命周期、线程安全投递）、**openeth 这三百多行的小驱动为什么是全网最好的移植教学样本**（它把真实 DMA MAC 的所有结构性难题——环、所有权位、中断→任务搬运——按最小比例复刻了一遍）。读完它，你应该有能力在一天之内为一颗从没见过的新 MAC 写出能跑的第一版 `low_level_*`。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`components/lwip/lwip/src`）+ IDF 组件 `esp_eth` / `esp_netif`；QEMU OpenCores ethmac 仿真端；实验工程 `practice/lwip-ch17-ethernetif-porting-guide/`。

---

## 17.1 契约面盘点：一块新网卡最少要交出什么

### 1. 驱动欠 lwIP 的：一张四个函数指针的注册表

第 7 章解剖过 `struct netif`。站在移植者角度，它的全部义务可以压缩成下面这张表——这正是上游骨架 `ethernetif_init()` 里逐行赋值的内容：

| netif 字段                    | 驱动要填什么                 | 谁来消费                                           |
| ----------------------------- | ---------------------------- | -------------------------------------------------- |
| `netif->name[0..1]`           | 两个字符，如 `'e','n'`       | `netif_list` 展示、调试打印                        |
| `netif->output`               | **直接抄** `etharp_output`   | IP 层发包入口（IPv4）                              |
| `netif->output_ip6`           | 直接抄 `ethip6_output`       | IPv6 发包                                          |
| `netif->linkoutput`           | **唯一必须亲手写的发送函数** | `ethernet_output()` → 把含以太网头的 pbuf 交给硬件 |
| `netif->input`                | 一般直接抄 `tcpip_input`     | 中断/任务侧收到包后的投递入口                      |
| `hwaddr/hwaddr_len/mtu/flags` | 硬件事实陈述                 | ARP、分片、路由判断                                |

注意这张表的重心：**真正属于"设备"的代码只有 `linkoutput`（TX）加上一段收包搬运逻辑（RX）**。`output` 填 `etharp_output` 是白拿的——ARP 解析、队列缓存、免费重发全部由栈完成；`input` 填 `tcpip_input` 也是白拿的——它只是"把 pbuf post 进 tcpip 邮箱"这行代码（第 13 章），本身不碰硬件。

### 2. lwIP 欠驱动的：四个现成的下半部

协议栈反向提供的配套，决定了驱动的上半身为什么能那么短：

1. **pbuf 抽象**（[[2026-08-26-lwip-deep-dive-ch4-pbuf-anatomy|第四章]]）：驱动永远只面对 pbuf 或裸 buffer，不必理解 IP 分片重组。
2. **`etharp_output()` + `ethernet_output()`**（`src/netif/ethernet.c`）：以太网头构造、未知目的地的 ARP 请求排队，都不劳烦驱动。
3. **`ethernet_input()`**：入方向第一跳，按 ethertype 分发 IPv4/ARP/IPv6，驱动不分拣协议。
4. **`tcpip_input()`**：跨线程投递。RX 任务做完 memcpy 就撒手，协议解析在线程世界里发生。

一句话总结契约：**你写一个"能把字节推出去、能被告知有字节进来了"的字节泵；协议、解析、调度全是栈的事。**

### 3. openeth 为什么是最好的教学样本

IDF 里这块 QEMU 专用驱动只有三个文件：寄存器定义 `openeth.h`、中断号映射 `esp_openeth.h`、本体 `esp_eth_mac_openeth.c`（约 440 行）。它值得精读的原因：

- **结构保真**：OpenCores ethmac 是真 RTL 项目，QEMU 忠实仿真了它的 DMA 描述符环语义——环形队列、ownership 位、wrap 位、"无空闲描述符则整帧丢弃并打 BUSY 中断"，一个不少；
- **噪声为零**：没有 PHY 自协商竞态、没有 cache 一致性、没有 DMA 地址映射，所有认知负担都集中在驱动的骨架上；
- **注释诚实**：文件头直说"本驱动按 QEMU 的脾气写"，哪些错误分支没处理、哪里不等 TX 完成，都点名了——这些被省略的点恰好就是本章 17.4 清单里要补回来的东西。

---

## 17.2 官方 skeleton 解剖：三层包装与两处巧思

### 1. 它在哪里，以及"它不能编译"

lwIP 主仓 `src/netif/`（`FILES` 文件清单可证）里**并没有** ethernetif.c——以太网驱动骨架放在 contrib 仓库，IDF 树中的路径是：

```text
~/esp/esp-idf/components/lwip/lwip/contrib/examples/ethernetif/ethernetif.c
```

整个函数体包在 `#if 0 ... #endif` 里，作者的意思写在注释里："this is only a skeleton"。所以任何声称"lwIP 自带 ethernetif 驱动"的说法都要修正为：**它是一个以源码形态存在的说明书**。

### 2. low_level 三件套 = 填空题

```c
static void      low_level_init(struct netif *netif);     /* 配 MAC 地址/MTU/flags/开中断 */
static err_t     low_level_output(struct netif *netif, struct pbuf *p);
static struct pbuf *low_level_input(struct netif *netif);  /* 取一帧 -> 组 pbuf */
```

`low_level_output` 的正文是一遍 pbuf 链遍历：

```c
for (q = p; q != NULL; q = q->next) {
    send data from(q->payload, q->len);   /* ← 你要填的全部 */
}
```

`low_level_input` 则反过来：`pbuf_alloc(PBUF_RAW, len, PBUF_POOL)` 之后再一遍链遍历填数据，并在注释里预留了高性能路线——"你也可以预分配 pbuf 给支持 DMA 的 MAC，收完截断 tot_len 即可"（这就是 17.4 要讲的 pbuf 直达）。骨架已替你照顾的细节：失败路径的 `LINK_STATS_INC(link.memerr/drop)` 与 `MIB2_STATS_NETIF_INC(netif, ifindiscards)` 计数器纪律；收发的广播/组播分类计数；`ETH_PAD_SIZE` 前导字节的摘除与归还。最后这条在 IDF 下无关紧要——`src/include/lwip/opt.h:699` 给了默认值 0 且 IDF 未改写，编译器会把相关代码整体裁掉。

### 3. 上层包装：init 注册指针，input 兜住错误

```c
err_t   ethernetif_init(struct netif *netif);   /* 传给 netif_add() 的 init 回调 */
static void ethernetif_input(struct netif *netif);  /* 通常由 RX 任务循环调用 */
```

`ethernetif_init` 干五件事：分配私有结构塞进 `netif->state`、起名、挂 `etharp_output`/`ethip6_output`、挂自己的 `low_level_output`、调 `low_level_init`。而 `ethernetif_input` 只有四行有效逻辑：`p = low_level_input(netif)`，非空则 `netif->input(p, netif)`，投递失败就 `pbuf_free(p)`——**所有权随投递转移，失败自己回收**，这句话是所有驱动 RX 路径的生死线（17.6 实验 a 的丢帧钩子会再次用到它）。

还有一个藏在注释里的资深忠告，原文大意：如果你的 MAC 有 DMA 发送队列，**在 `low_level_output` 返回 ERR_MEM 会让系统出现怪异行为**，因为栈不会替你重试这条被丢的包（TCP 定时器除外）；更稳的做法是在该函数里等队列腾出空位。这段警告我们在 17.6 实验 c 用受控注入验证了个底朝天——结论比注释更有戏剧性：ERR_IF 甚至会穿透成 errno=-1 这种非法值。

---

## 17.3 openeth 活教材：从寄存器到任务通知的每一格

### 1. 内存地形图：一段地址空间里的三种格子

ESP32 目标上 EMAC 寄存器基址 `DR_REG_EMAC_BASE = 0x3FF69000`（`soc/esp32/register/soc/reg_base.h`），openeth 复用同一地址面（`OPENETH_BASE`）：

```text
0x3FF69000 + 0x00   MODER    使能位: RXEN/TXEN/PRO(混杂) + RST
           + 0x04   INT_SOURCE  RXB(bit2)=帧到  BUSY(bit4)=因缺缓冲丢帧
           + 0x08   INT_MASK
           + 0x20   TX_BD_NUM   划界线：前 N 个槽给 TX，其余全归 RX
           + 0x400  描述符表起点：128 个 8 字节槽固定布局
                    [ TX desc × TX_CNT ][ RX desc × (128−TX_CNT) ]
每个描述符配一块 1600B 数据缓冲（DMA_BUF_SIZE），openeth 用
heap_caps_calloc(DMA_BUF_SIZE, MALLOC_CAP_DMA) 在堆上取
```

IDF v6 的 Kconfig 默认：`CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM=4`、`..._TX_BUFFER_NUM=1`（范围都是 1~64）。也就是说这台"缩小版"网卡：**RX 环深 4 帧 ≈ 6.4KB 缓冲，TX 单描述符**——记住这两个数，它们分别在实验 b 和实验 d 当主角。上电后驱动先把 `TX_BD_NUM_REG=1` 写进硬件划界（`openeth_set_tx_desc_cnt`），再用最后一槽的 `wr`(wrap) 位把两条环各自首尾相接。

### 2. ownership 位语义：两枚 1 bit 撑起的并发协议

```c
// components/esp_eth/src/openeth/openeth.h（节选）
typedef struct {                 /* 8 bytes */
    uint16_t rd: 1;   /* TX ready:   0=SW持有 1=交给HW。HW发完自动清零 */
    uint16_t wr: 1;   /* wrap-around: 本槽是否环尾（回卷点） */
    uint16_t len;     uint16_t irq...
    void* txpnt;
} openeth_tx_desc_t;

typedef struct {
    uint16_t e:  1;   /* empty:      1=HW持有（等帧进来） 0=SW持有待取走 */
    uint16_t wr: 1;   uint16_t irq: 1;
    uint16_t len;     /* HW 收完后回填实际长度 */
    void* rxpnt;
} openeth_rx_desc_t;
```

围绕这两枚比特，硬件与软件的握手规则干净得可以画成状态机：

| 方向 | 位   | SW 动作                    | HW 动作                           |
| ---- | ---- | -------------------------- | --------------------------------- |
| RX   | `e`  | 取走数据后重新置 1（还槽） | 写满缓冲后清 0 并回填 len（交槽） |
| TX   | `rd` | 填好数据后置 1（下单）     | 发送完成后清 0（交付回执）        |

驱动侧 `cur_rx_desc/cur_tx_desc` 两个游标做模运算推进，永不回头审视 HW 是否完成——RX 是中断驱动消化，TX 在 QEMU 里瞬时完成（真实硬件则需要等 `rd` 被清零或irq 标志，骨架里的"等队列有空位"劝告正是补在这里）。

### 3. ISR 只干三件事，然后就把话筒递出去

```c
// esp_eth_mac_openeth.c —— 完整的 ISR，没有更多内容
static IRAM_ATTR void emac_opencores_isr_handler(void *args)
{
    uint32_t status = REG_READ(OPENETH_INT_SOURCE_REG);
    if (status & OPENETH_INT_RXB) {              // ① 读一次状态寄存器
        vTaskNotifyGiveFromISR(emac->rx_task_hdl, &high_task_wakeup);
        if (high_task_wakeup) portYIELD_FROM_ISR();  // ② 踢一脚接收任务
    }
    if (status & OPENETH_INT_BUSY)
        ESP_EARLY_LOGW(TAG, "...RX frame dropped (0x%x)", status);
    REG_WRITE(OPENETH_INT_SOURCE_REG, status);   // ③ 写 1 清中断
}
```

这就是第十九章将展开的「ISR 极简主义」现场版：贴标签（读状态）、叫人（Task Notify，参见 [[2026-08-26-freertos-deep-dive-ch13-task-notifications|FreeRTOS ch13]]）、关门（清标志）。没有任何拷贝、没有分配、没有 pbuf——**因为 ISR 里那些事每一样都可能成为最坏情况延迟的引爆点**。值得咀嚼的是 BUSY 分支：它说明缺缓冲的责任边界在硬件，INT_BUSY 就是硬件开的"丢条数从这里开始计"的发票。

### 4. RX 全链路：接续第十六章那张时序图

第十六章画过 t0~t6 的阻塞 recv 时序，本章把它最左边那块黑盒打开：

```text
SLIRP/HW            ISR(emac_opencores)      emac_rx 任务(prio15,4096B栈)        tcpip_thread
─────────          ─────────────────       ───────────────────────────        ─────────────
帧写入 rxpnt[e]                                        ▲
清 e 位、回填 len                              ulTaskNotifyTake 等
INT_RXB ──────────▶ notify give ─────────▶ 内层 drain 循环:
                                                receive(): 读 desc[cur]
                                                           memcpy(desc.rxpnt → malloc(1522))
                                                           e=1 还槽; cur=(cur+1)%4
                                                           stack_input(mediator)
                                                             └ eth_stack_input()      // esp_eth.c
                                                                └ 用户输入路径        // glue 安装
                                                                   └ eth_input_to_netif()
                                                                      └ esp_netif_receive()
                                                                         └ ethernetif_input():
                                                                            esp_pbuf_allocate()
                                                                            netif->input(p)══▶ mbox_post ══▶ ...
```

两个一手观察（对应 17.6 实验输出的钩子上下文自证行）：`linkoutput` 只会在 `tcpip` 任务里执行，这套驱动接收路径的工作马名字就叫 `emac_rx`。另一个工程细节：自 v5.x 起 IDF 对发射侧做了单 pbuf 化承诺——`port/include/lwipopts.h:765` 把 `LWIP_NETIF_TX_SINGLE_PBUF` 硬编码为 1，配合 IDF 版 `ethernet_low_level_output()` 里那条「pbuf 成链才 fallback 到 `pbuf_copy` 平面化」的分支，意味着日常 TCP 流量几乎不会踩进慢车道（这是 IDF 对上游骨架的一处静默升级，也是 Vanilla 移植者常忽略的优化位）。

### 5. 为什么它是"真实 DMA 驱动的缩小版"

对照 STM32 HAL ETH / NXP ENET 那类几千行的巨兽，openeth 少了什么、留下了什么：

| 维度                           | openeth（QEMU）     | 真实 MAC（如 STM32 F7/H7）         |
| ------------------------------ | ------------------- | ---------------------------------- |
| 描述符环 + 游标 + ownership 位 | ✅ 完整             | ✅ 同构（细节位不同）              |
| 中断→任务两级搬运              | ✅ TaskNotify       | ✅ 同构（信号量/队列/notify 任选） |
| 环耗尽→硬丢帧+BUSY 中断        | ✅ INT_BUSY         | ✅ 同构                            |
| TX 完成等待/错误位(retry,crc…) | ❌ QEMU 瞬时完成    | ✅ 必须处理                        |
| D-cache 一致性                 | ❌ 无 cache         | ✅ 致命课题（见 17.4）             |
| DMA 可寻址 RAM 限制            | ❌ 普通 calloc 即可 | ✅ 指定 RAM 段+对齐                |

留下的部分恰恰是**架构性的**（80% 的设计决策），省略的部分是**平台性的**（80% 的调试时间）——这正是教学样本的价值：先用它学会想清楚架构，再带着清单去应付平台。

---

## 17.4 STM32 类 MCU 移植清单：把缩小版放大回去

以下六条全部对着 openeth 的映射来讲：先看缩小版怎么做，再看放大版要多做什么。

### 1. 描述符环设计

openeth 给的基线配置是 RX=4×1600B、TX=1×1600B。换算成真实吞吐需求要倒过来推：

- **RX 环深度 ≥ 「搬运最长停顿」内的线速帧数**。100M 半双工 ≈ 14.8k fps；若 `tcpip_input` 投递偶发阻塞 10ms（mbox 满、优先级反转），需要 ≥148 个空槽才能零丢失扛过。实战常见 4~16，配合 PBUF_POOL 反压接受少量丢帧（TCP 自己会修复，UDP 应用自负——第 10 章账本通用）。
- **TX 环深度的意义不在容量在流水**：≥2 才能在"上一帧未毕"时继续提交下一帧，否则每次发送都串行等待。openeth 的 TX=1 恰好演示了「不等完成」策略的极限——它能工作纯属 QEMU 瞬时完成的恩惠（实验 c 注入的就是这个位置的故障）。
- 描述符本身**放普通 RAM 没问题，但建议和缓冲区一起锁死在 DMA 段**（见第 6 条），并把 `wr` 环尾位当成编译期断言的对象（最后一槽 wr=1，别靠运行期数学）。

### 2. pbuf 直达 vs 一跳拷贝：这不是二选一

```text
方案 A（拷贝派，上游骨架）：
  ISR 发现帧 → 任务里 pbuf_alloc(PBUF_POOL) → 从 DMA buf memcpy 进 pbuf → 立即还槽
方案 B（直达派，IDF openeth 路径）：
  驱动 malloc(1522)/静态池作为缓冲 → 收完 wrap 成 custom pbuf(PBUF_REF)
  → 整个缓冲的所有权让渡给栈 → 栈 free 时经 custom_free_function 归还驱动
```

| 权衡项     | A 拷贝一次             | B 零拷贝                           |
| ---------- | ---------------------- | ---------------------------------- |
| CPU 开销   | 每帧 +memcpy(≤1522B)   | 无额外拷贝                         |
| 占环时长   | 拷贝完即还槽，环压力小 | 等栈消费完才还槽，环深依赖上层速度 |
| 实现复杂度 | 低                     | 需要 pbuf_custom + free 回调对接   |

IDF 的选择值得抄：**计划内流量用 B 省那一刀，但把「还槽延迟」显式变成协议栈的消费速度问题**（这正是实验 d 能人为制造过载的原因）。注意 vanilla 的 `PBUF_REF` pbuf 不许送进 tx 路径，custom pbuf 同理只能单向 RX。

### 3. ISR 里只做三件事

读状态、通知任务、清标志（17.3 已给源码样板）。放大版的诱惑是把 `receive()` 也搬进 ISR（老式stm32 例程真这么干过）：代价是 IRQ 关窗时间不可控、从中断上下文调用可能睡眠的 API（TCP/IP 世界一律非法）。判定标准永远是那句话：**凡是带 malloc/memcpy(百字节级)/信号量的代码，都没有资格住在 ISR 里。**

### 4. PBUF_POOL 预分配尺寸估算

拷贝派的核心参数。公式按三笔账加总：`MSS/wan-MTU 场景的单连接在途窗口（TCP_WND/MSS≈5~7 个）×并发连接数 + 分片重组余量（若开 IP_REASS） + 中断到任务的抖动冗余（2~4 个）`。IDF 因为全堆化（`MEM_LIBC_MALLOC=1 && MEMP_MEM_MALLOC=1`，[[2026-08-26-lwip-deep-dive-ch5-memory-management|第五章]]）已无独立 POOL 数组，但 vanilla 移植者面对的是货真价实的静态池——`PBUF_POOL_SIZE×PBUF_POOL_BUFSIZE(通常1536~1600)` 全部要进链接脚本预算。Batch 2 实测过的教训在此重复一次：池子吃紧时的症状不是崩溃而是 `memerr` 计数爬升＋ping RTT 台阶化，容量规划时要给 ping 这类延迟敏感流量留头寸。

### 5. D-cache 一致性：缩小版替你藏起来的头号大坑

STM32 F7/H7 的 D-cache 让"CPU 写过的缓冲"和"DMA 眼里的缓冲"可能是两份数据。openeth 完全不用操心这件事，而真实移植必须建立两条铁律：

```c
/* TX：CPU 写完再交 HW —— clean（刷出去） */
SCB_CleanDCache_by_Addr((uint32_t *)buf, len);
/* RX：HW 写完给 CPU 看 —— invalidate（作废我的旧视图） */
SCB_InvalidateDCache_by_Addr((uint32_t *)buf, ROUND_UP(len, 32));
```

外加一条空间纪律：**每个 DMA 缓冲独立占一片按 32 字节对齐、32 倍数的区间**——invalidate 是整条 cache line 生效的，两个缓冲挤在同一条 line 里会互相误伤（甲的 invalidate 弹掉乙刚写的脏数据，故障表现为"随机坏帧"，极难定位）。MPU 把这段 RAM 设为 non-cacheable 也是合法解法，代价是访问性能打折。

### 6. 链接脚本里的 DMA 段

上面所有要求的物理载体是一个专用内存域。GNU ld 语法示例（概念展示，具体段名随厂家 SDK 而异）：

```ld
/* .ld 片段： carved-out 出一块永不分配普通堆对象的 DMA arena */
MEMORY { DMARAM (xrw) : ORIGIN = 0x24080000, LENGTH = 64K }
.dmabuffers (NOLOAD) :
{
    . = ALIGN(32);
    __dma_start = .;
    KEEP(*(.dma_desc))          /* 描述符表 */
    KEEP(*(.dma_buf))           /* 帧缓冲 */
    . = ALIGN(32);
    __dma_end = .;
} > DMARAM
```

代码侧 `__attribute__((section(".dma_desc"), aligned(32))) static eth_dma_desc_t s_desc[N];`。校验手法：map 文件确认 `__dma_start/end` 区间、运行期 `(uint32_t)&s_desc % 32 == 0` 断言。idf 这个世界等价物是开头那句 `heap_caps_calloc(..., MALLOC_CAP_DMA)`——同一诉求的两套方言。

### 7. 可以直接抄的骨架（标注硬件依赖点）

```c
/* ---------- low_level_output：直接照搬即可的形状 ---------- */
static err_t stm32_low_level_output(struct netif *netif, struct pbuf *p)
{
    HAL_ETH_TxCpltCallback 之流不要在这里等——【纯软件约定】
    for (struct pbuf *q = p; q; q = q->next) {
        /* 分段写入当前空闲 TX 描述符的缓冲：
         * 【硬件依赖】缓冲取自 DMA 段、写前 clean cache（D-cache 场景）
         *             单描述符容纳不下时分段挂链 */
        dma_tx_write(q->payload, q->len);
    }
    set_desc_ready(cur_tx, p->tot_len);      /* 【硬件依赖】置 ownership/ready 位 */
    kick_tx_dma();                            /* 【硬件依赖】告知 DMA 启动 */
    LINK_STATS_INC(link.xmit);
    return ERR_OK;   /* “满”时绝不返回 ERR_MEM：见 17.6 实验 c 的 errno 灾难 */
}

/* ---------- low_level_input：拷贝派模板 ---------- */
static struct pbuf *stm32_low_level_input(struct netif *netif)
{
    eth_desc_t *d = &rx_desc[cur_rx];
    if (!desc_owned_by_sw(d)) return NULL;               /* 【硬件依赖】e/own 位 */
    u16_t len = desc_len(d);                             /* 【硬件依赖】HW 回填长度 */

    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_POOL);
    if (p != NULL) {
        for (struct pbuf *q = p; q; q = q->next) {
            /* 【硬件依赖】源=DMA 缓冲，取前 invalidate cache */
            SCB_InvalidateDCache_by_Addr(d->buf, ALIGN32(len));
            memcpy(q->payload, d->buf /*分段*/, q->len);
        }
        LINK_STATS_INC(link.recv);
    } else {
        LINK_STATS_INC(link.memerr); LINK_STATS_INC(link.drop);
    }
    release_desc_to_hw(d);                               /* 【硬件依赖】还槽+升游标 */
    return p;
}
```

---

## 17.5 Vanilla 与 ESP-IDF 对照：手工 netif_add vs 全自动封装

### 1. 裸机派的一天：手工装机全过程

Vanilla lwIP 移植者的 bring-up 是完全显式的（伪代码，即"国外教程千篇一律的那二十行"）：

```c
tcpip_init(NULL, NULL);                     /* 起 tcpip_thread（可传回调函数指针在栈就绪时通知你）*/
ip4_addr_t ip, nm, gw;
IP4_ADDR(&ip, 192,168,1,10); ...            /* 静态地址；或 netif_add 后 dhcp_start */
static struct netif g_netif;
netif_add(&g_netif, &ip, &nm, &gw,
          NULL /*state*/,                   /* init 回调自己 new state */
          ethernetif_init,                  /* 本章主角：组装字段+low_level_init */
          ethernet_input);
/* ↑ 最后一参是二选一的决策点：RAW 自托管线程模型填 ethernet_input；
 *   一旦用 netconn/socket（内核单线程模型），必须填 tcpip_input，
 *   让 ISR/RX 任务只负责投递、解析在 tcpip_thread 内完成。 */
netif_set_default(&g_netif);
netif_set_up(&g_netif);   netif_set_link_up(&g_netif);
dhcp_start(&g_netif);                       /* 若走 DHCP */
while (!g_got_ip) sys_check_timeouts();     /* 裸机主循环亲自喂定时器 */
```

这条路的学费花在三处：init/input 两根指针的正确组合（`ethernet_input` 直填 vs `tcpip_input` 邮箱化的抉择把无数新手绊倒在「收不到包却不知道该怨谁」）、`sys_check_timeouts()` 的喂养责任归属、flags 名称迁移（`NETIF_FLAG_ETHARP` 已是遗产命名，现代写法看 IDF 版骨架的 `NETIF_FLAG_ETHERNET` 组合）。

### 2. ESP-IDF 派的十分钟：谁在替你干活

ch3 模板里那七步 `esp_netif_init → esp_netif_new → mac/phy → install → attach → start → wait event`，翻译成本章语言就是把上节每个显式步骤塞给了特定组件层：

| 你的显式步骤(Vanilla)     | IDF 代办者                    | 具体落点                                                                                  |
| ------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------- |
| 写 ethernetif_init        | esp_netif 默认 netstack 配置  | `esp_netif_lwip_defaults.c`: `.init_fn=ethernetif_init, .input_fn=ethernetif_input`       |
| 选 tcpip_input 邮箱化     | esp_netif 固定代选            | `esp_netif_lwip.c`: `netif_add(..., lwip_init_fn, tcpip_input)`                           |
| 手工 malloc(帧)+wrap pbuf | esp_netif 的 ethernetif_input | `esp_pbuf_allocate()` 包 `pbuf_custom(PBUF_REF)`                                          |
| RX 线程收包→投递          | esp_eth 组件自带 emac_rx 任务 | openeth 驱动 `xTaskCreatePinnedToCore(...4096,prio15...)`                                 |
| free 约定/驱动接口表      | glue 层装配                   | `esp_eth_netif_glue.c`: transmit/free_rx_buffer/set_mac_filter + `update_input_path_info` |
| link-down/DHCP/事件同步   | esp_event 总线                | `ETHERNET_EVENT_*` / `IP_EVENT_ETH_GOT_IP`                                                |

学习价值的两边叙事：**裸机派被迫理解每一个环节**（所以启蒙推荐裸板做一遍），**IDF 派拿到的是一个已经把这些环节焊死的成品**（所以生产推荐直接用，且知道焊点在哪才有得救——例如本章实验 a 就动了两处别人不敢碰的焊点）。

### 3. IDF 在 openeth 上叠的三件行李

对照上游"套壳假说"，IDF 真正叠加的东西恰好三层：其一是 **glue 输入路径**（`eth_input_to_netif → esp_netif_receive`，把驱动字节流翻译成 esp_netif 语言）；其二是 **MAC 组件的 emac_rx 任务与 MALLOC_CAP_DMA 缓冲管理**（驱动层自理，不经应用）；其三是**事件化生命周期**（link/ip 状态全部事件总线广播）。而没有叠的东西同样重要：默认构建不开 `MIB2_STATS`（Kconfig 未暴露，第 9 章用过编译期注入法），驱动的每帧统计在 IDF 里并不免费存在——想要计数就得像下一节那样自己动手装观察点。

---

## 17.6 实验：驱动层观察点的全集表演

实验工程 `practice/lwip-ch17-ethernetif-porting-guide/` 基于 ch3 联网模板。hostfwd 双通道：TCP echo 用章号端口 `tcp::8020-:8888`，UDP 洪峰接收口 `udp::8020-:8020`（公约占用表中 8020 空闲，已 `ss -ltn` 核验）。标准构建流程见公约第 3 节；主机洪峰用项目内 `tools/udp_flood.py 22 800`（22 秒 × 800 datagram/s × 1200B）。

```bash
. ~/esp/esp-idf/export.sh && cd practice/lwip-ch17-ethernetif-porting-guide
idf.py build && idf.py qemu monitor < /dev/null || true   # 生成 qemu_flash.bin/efuse
TMO=85 ./tools/run_qemu.sh > /dev/null 2>&1 &              # 打开 run.log 盯 PHASE-D 标记
python3 tools/udp_flood.py 22 800                          # 见到标记立刻执行（另一终端）
```

固件开机自报家底（`BUILD-FACT` 行），Kconfig 数字与编译期断言对账：`dma_buf=1600 tx_cnt=1 rx_cnt=4 eth_max_frame=1522`（1522 = `ETH_MAX_PACKET_SIZE`，`esp_eth_spec.h` 定义）。

### 实验 a：两个观察点，两种安装法，以及身份自证

安装代码只有各十几行，却是全章的手眼所在：

- **TX 观察点** = `esp_netif_get_netif_impl()` 拿 lwip netif 后换 `n->linkoutput`（ch12 验证过的既有手法）；
- **RX 观察点** = 新武器 `esp_eth_update_input_path(eth_hdl, my_stack_input, NULL)`——glue 在 `esp_netif_attach` 时会装上 `eth_input_to_netif`，我们在 attach 之后、start 之前覆写之。新函数第一件事声明缓冲所有权规则：转发调用原语义 `esp_netif_receive(s_netif, buffer, length, NULL)`；如果某天要做 RX 丢弃注入，丢弃者必须自行 `free(buffer)`——这与 `esp_eth.c` 里"未安装输入路径"兜底分支的行为完全一致（该分支源码旁还挂着 IDF-11444 的 issue 号，可见这里咬过人）。

运行后计数差与身份自证输出（run.log 原文）：

```text
===== PHASE A: driver observability t_ms=5574 =====
[PING-REPLY] seq=1 size=64 t_ms=5824 rx_counter=18
[PING-REPLY] seq=2 size=64 t_ms=6016 rx_counter=19
[PING-REPLY] seq=3 size=64 t_ms=6216 rx_counter=20
[PING-REPLY] seq=4 size=64 t_ms=6416 rx_counter=21
[A] after traffic t_ms=10613 rx=21 tx=22
[A] delta tx_frames=16 tx_bytes=4000 rx_frames=16 rx_bytes=4400
[A] tx_hist<=4,12,0,0,0,0,0,0,0,> rx_hist<=4,12,0,0,0,0,0,0,0,>
[A] hook contexts: TX-linkoutput in 'tcpip', RX-stack_input in 'emac_rx'
```

解读四条：**入站响应逐帧编号连续递增**（rx_counter 18→21 即 4 个 ICMP reply 被观察点实时捕获）证明 RX 观察点真的站在搬运必经之路；**tx/rx 帧数严格对称 16/16**，且指数分桶完美对应载荷构成——12 个 256B UDP probe（约 298B 帧，桶 1）加 4 个 ~110B 的 ping 组合（桶 0），两侧桶位分布完全一致；**两个钩子的执行上下文分别是 tcpip 线程与 emac_rx 任务**，把 17.3 的链路分析变成了运行期证据。

一个如实报告的插曲：单独两次中间调试跑里，"第二开的 ping 会话"（温启动会话正常答完之后立刻新开会话的那种用法）全部超时且无迟到回复，`PING-TIMEOUT rx_counter=5` 冻结字样连续六行；换成 UDP 探针先行暖场后恢复稳定。SLIRP 对网关 ICMP 会话边界的这类毛刺不影响本章任何结论，但提醒我们：**QEMU 网络实验里，「确定性」要靠自己造（UDP 探针 100% 立刻回弹），“看起来应该稳定的 ICMP”反而是环境噪声大户**。顺带这份噪声反而送出一个 treasure：对 discard 端口的 UDP 发送会立刻招致 SLIRP 回弹的 ICMP unreachable 大帧，固件里的 `[RXBIG]` 嗅探器把它解剖了出来：

```text
[RXBIG] len=594 proto=17 sport=67 dport=68 t_us=179034      ← 开机 DHCP OFFER/ACK（UDP 67→68）
[RXBIG] len=594 proto=1 sport=768 dport=2587 t_us=10616521  ← ICMP type=3 code=0 host-unreachable
[RXBIG] len=594 proto=1 sport=771 dport=2584 t_us=10624144  ← ICMP type=3 code=3 port-unreachable
```

（sport/dport 两个打印位在 ICMP 帧里实际是 type/code 与 id 字段——嗅探器不知道帧型，读者拿到 type/code 反而赚了。）

### 实验 b：描述符环可视化——只见得到终态，但你确实见到了

实现方式前面预告过：复制 `openeth.h` 的描述符结构与寄存器地址（保留 Apache-2.0 出处注记）进实验代码，绕过一切封装直接读内存。采样三拍：突发前后 + 突发中滚动快照，顺带回读 `TX_BD_NUM_REG` 验证划界：

```text
[RING][a-post-ping] t_ms=10614 hw_tx_bd_num=1
[RING][a-post-ping] TX[0/1] rd=0 wr=1 len=106 buf=0x3ffe1ff4
[RING][a-post-ping] RX e-bit: 1111  len: 110 110 110 110
[RING][b-tx-active] t_ms=10616 hw_tx_bd_num=1
[RING][b-tx-active] TX[0/1] rd=0 wr=1 len=1066 buf=0x3ffe1ff4
[RING][b-tx-active] RX e-bit: 1111  len: 110 594 110 110
W (12106) opencores.emac: ...RX frame dropped (0x14)
[RING][b-tx-active] t_ms=10653 hw_tx_bd_num=1
[RING][b-tx-active] RX e-bit: 1111  len: 594 594 594 594
[RING][b-idle-after] t_ms=11403 hw_tx_bd_num=1
[RING][b-idle-after] RX e-bit: 1111  len: 594 594 594 594
```

逐个兑现的教学点：`wr=1` 印证唯一槽即环尾；`rd=0` 说明 QEMU 瞬时交付从不留残影（对比真实 MAC 大概率拍到 rd=1 在途态）；`TX len=106→1066` 的瞬间切换是同一个 1600B 缓冲被复用的直接证据（上一帧长度残留在 len 字段，说明 SW 写自己的数据段、HW 不管残留）；RX `e` 位串恒 1111——kLOC 级别的仿真快得让“正在搬运”这个态在快照下必然坍缩为空槽，**这不是测量失败，而是对"SW↔HW 握手窗口 ~微秒级"的一次定量目击**；相邻两拍 RX len 从 `110,594,...` 变成满屏 `594`，就是 SLIRP 对 B 阶段 UDP 突发的 12 连弹跟上了节奏。彩蛋是中间那条 `W (12106) ... dropped (0x14)`：即便不做任何人为过载，几十毫秒内 12 连发 ＋ 协议栈回应的组合就足以让 4 槽小环偶发溢出一次——`0x14=RXB|BUSY`，硬件丢帧的"发票"开出来了。

### 实验 c：TX 环满注入——ERR_IF 是穿透性重伤，ERR_MEM 至少阵亡得体面

包装层的注入开关提供两种"环满"返回值流派，各打一轮，另设一轮配额递减观察恢复边界：

```text
--- C0 baseline ---
[PROBE-C0] total=30 ok=30 fail=0 last_fail(rc=0 errno=0)
--- C1 ERR_IF injected on every call (quota=huge) ---
[INJ-TX] reject t_us=11085754 len=1066 quota_left=4294967294
[PROBE-C1] #0 FAIL rc=-1 errno=-1 ()
[PROBE-C1] total=20 ok=0 fail=20 last_fail(rc=-1 errno=-1)
[PROBE-C1] seq=FFFFFFFFFFFFFFFFFFFF
--- C2 recovery: ERR_IF quota=15 inside 40-call burst ---
[PROBE-C2] total=40 ok=25 fail=15 last_fail(rc=-1 errno=-1)
[PROBE-C2] seq=FFFFFFFFFFFFFFFSSSSSSSSSSSSSSSSSSSSSSSSS
--- C3 ERR_MEM injected on every call (quota=huge) ---
[PROBE-C3] #0 FAIL rc=-1 errno=12 (Not enough space)
[PROBE-C3] total=20 ok=0 fail=20 last_fail(rc=-1 errno=12)
[C] injection fired 55 times total
```

四个硬结论：

1. **errno=-1 是真实存在的荒诞物**：`ERR_IF(-12)` 经 `err_to_errno` 映射出的正是第十六章那张表里写着 `-1（裸值！）`的那一格——`sendto()` 返回 -1 且 `errno==-1`，`strerror(-1)` 只能给出一对空括号。分层错误码穿到 socket ABI 这层时会失足掉坑，移植者在驱动里"报个底层错"之前要先想到它在二十几层楼下的落地姿势。
2. **ERR_MEM(-1)→ENOMEM(12)** 表现正常，至少调用方能分辨"资源暂时不足"。
3. **恢复是确定性的、即刻的**：C2 的 S/F 位图 `FFFFFFFFFF.....FSSSS...S` 显示第 16 次尝试起全部成功（配额 15 用尽后 wrapper 放行），无需人工干预——这印证了上游骨架注释的反面：显式报错流派的真实风险不是"恢复不了"，而是**调用方怎么理解这个错误码**（对照 TCP 场景：ch12 的注入选择了第三种流派——返回 ERR_OK 静默吞包，让 RTO 机制背锅。三流派对比：静默吞/阻塞等/显式报错，代价分别转嫁给协议定时器、调用延迟上限与 errno 契约）。
4. 注入总量事后对账 `fired 55 = C1(20)+C2(15)+C3(20)`，wrapper 无漏触发也无虚触发——仪器自身也要被计量。

### 实验 d：RX 超载——管道上限公式的现场验证

方法学呼应"ISR 三件事"：ISR 永远不堵，堵的是它叫醒的那个搬运工。固件在 RX 观察点里加入可开关的 `vTaskDelay(30ms)`（模拟真实系统中"搬运任务被高优先级业务饿死"的场景），主机侧以 800 datagram/s × 1200B 连灌 22 秒横跨三个窗口。`[RING][d-stress-on]` 快照显示过载瞬间四槽均被 1246B 洪峰帧占满（`e:1111`、1200 载荷+46 帧开销），随后进入数字最有说服力的部分：

```text
[D-WIN ctl] +1318 frames ... +2795 frames ... +4281 frames      （0→6s，delay=0）
[D] >>> stress window ON: rx_task now sleeps 30ms/frame <<<
[D-WIN stress] +51 frames ... +117 ... +184 ... +251            （6→14s，delay=30ms）
[D] >>> recover window: delay cleared <<<
[D-WIN recover] +1123 frames ... +2624 ... +4125                （14→20s）
[D] lifetime rx_frames=9130 rx_bytes=11315266
```

- **控制窗 ≈ 洪峰满速**：每 2 秒窗口增量约 1400~1500 帧 ≈ 720~750 fps，跟得上 800pps 的灌入（扣量来自采样间隔与 SLIRP 节拍），此时丢帧告警为零；
- **过载窗精确坍缩到 33fps**：四个 2s 窗增量 66/33/33/34 平均恰为 `1帧/30ms=33.3fps`——搬运任务的节流速度原样成为整机接收上限，理论管道模型零偏差；
- **不可投递的部分去了哪**：硬件 ring 满→INT_BUSY，日志中共 269 条 `RX frame dropped (0x14)`，其中 267 条落在过载窗内（其余两条是实验 b/c 突发期偶然捕获的那两条同款告警）；
- **恢复窗立即回血**到控制窗水平，体现该机制的弹性本质：瓶颈是瞬态的调度状态而非累积的资源泄漏。

把这组数代入公式总结论：**深度 4×1600B 的环只相当于 6.4KB 的蓄水池，按线速帧率算仅能撑亚毫秒级的下游停顿**；Hostfwd+SLIRP 环境（突发尾巴 ~0.8% 仿真丢包底噪，第 10 章实测）之上叠加的任务级饥饿会把送达率压到 4%。真实 MCU 上数字更极端——DMA 抖动、cache 维护指令都发生在"搬运工"这一格里。这也是第十九章 ISR/优先级设计的第一个前置论据：**你的网络栈吞吐上限=ISR 提交速度与任务消化速度的最小值，而不是 DMA 参数**。

---

## 17.7 小结

- 契约面一页纸：驱动只需 `low_level_output`（真手写）+ RX 搬运逻辑，其余 `output=etharp_output`、`input=tcpip_input` 都是白拿；lwIP 回赠 pbuf、帧分发、ARP、跨线程投递四大件。上式不含平台杂务（cache/DMA 段/PHY），它们不属于 lwIP 契约却决定成败。
- 官方 ethernetif 骨架以 `#if 0` 的形式活在 contrib（`contrib/examples/ethernetif/ethernetif.c`）；三层包装中 `ethernetif_input` 的所有权条款——**投递成功即让渡、失败自回收**——是所有 RX 路径的铁律。上游注释早有预言：环满时返回 ERR_MEM 会导致怪异行为，实验 c 将其量化为 errno=-1 的 ABI 穿透事故。
- openeth = 真实 DMA MAC 的架构全息缩略版：`0x3FF69000+0x400` 起 128 槽描述符表、TX/RX 按 `TX_BD_NUM` 划界、e/rd 两枚 ownership 位完成 SW↔HW 互斥、ISR 三件事、环满硬丢帧开 BUSY 发票。少掉的（TX 等待、错误位、cache、DMA 段）正是 17.4 清单逐条放大回真机的部分。
- RX 链路全图：`ISR(贴标签/叫人/清标志) → emac_rx(15,4096B) → receive()+malloc(1522) → stack_input(用户可插!) → esp_netif_receive → esp_pbuf_allocate(custom pbuf=PBUF_REF 直达) → netif->input=tcpip_input`；TX 则靠 `LWIP_NETIF_TX_SINGLE_PBUF=1`（`port/include/lwipopts.h:765`）保证单 pbuf 快车道。
- 移植清单六大件：环深按"搬运最长停顿×线速帧数"反推；pbuf 直达（省拷贝）与一跳拷贝（减压环）按消费能力选；ISR 永远三件事；PBUF_POOL=`在途窗口×连接数+余量`；F7/H7 上 Clean/Invalidate 按写向分治且缓冲独占 32B 对齐区；DMA 域进链接脚本并用 map 文件核验。
- ESP-IDF 把 Vanila 手工活分散焊接进 esp_netif(默认 netstack init_fn/input_fn)、esp_eth(emac_rx 任务+输入路径)、glue(transmit/free/event) 三层，Default 构建不带 MIB2——可观测性要自己长出来（update_input_path/linkoutput 两处官方留门正好用来装仪表）。
- 本机实验的五组可复现实测：双观察点上下文自证(tcpip/emac_rx)；环快照证实握手窗口微秒级(rd 恒 0、e 恒 1111)、TSO 帧 len 残留揭示缓冲复用；ERR_IF→errno=-1 vs ERR_MEM→ENOMEM 的故障谱系；配额用尽即刻恢复(F..FS..S 位图)；30ms/帧降速使接收上限精确等于 33fps 并产生 267 条 INT_BUSY 硬件丢帧发票。

Part V 移植篇的第二站转向无线：[[2026-08-26-lwip-deep-dive-ch18-esp32-wifi-lwip-integration|第十八章《ESP32 WiFi 与 lwIP 集成》]]将离开 OpenCores 这台仪表完美的仿真器，去看 esp_wifi 接入 lwIP 的另一半地图——WiFi 的 netif 不走 `ethernetif_init/ethernetif_input` 而换用 `wlanif_init/wlanif_input` 一族（`esp_netif_lwip_defaults.c` 里 sta/ap 两副面孔各持一份）、MAC 层从我们手里的寄存器描述符换成 esp_wifi 的不透明白盒、以及本环境无法仿真其固件时源码走读与真机实验如何分工。今天装上的两个观察点（input path / linkoutput）在 WiFi 上仍然原位可用——那将是下一章验证它们"接口无关性"的地方。
