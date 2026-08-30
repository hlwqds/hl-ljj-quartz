---
title: "lwIP 深度解析（三）：实验环境：QEMU 网络仿真与第一包 ping 通"
date: 2026-08-26
description: "不用真机把 ESP32 联上网：拆解 QEMU 对 OpenCores 网卡与 SLIRP 用户态网络的仿真拓扑，解剖 IDF 的 openeth 驱动如何用一对 DMA 描述符环交换以太网帧，给出八步可复用的以太网 bring-up 序列（本工程即系列后续 20 章的标准联网模板），并用三个真实实验打通两个方向：esp_ping ping 通 SLIRP 网关 10.0.2.2、主机 nc 经 hostfwd 打进 guest 的 TCP echo server、以及 SLIRP DNS 行为三连测。"
tags: [lwip, network, esp32, esp-idf, qemu]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 3. **第三章：实验环境：QEMU 网络仿真与第一包 ping 通**

# lwIP 深度解析（三）：实验环境：QEMU 网络仿真与第一包 ping 通

这一章回答三个问题：**没有真机怎么让 ESP32 联网**（QEMU 把网卡和整条网络路径都搬进了用户态进程）、**这套虚拟链路上帧是怎么流动的**（openeth 驱动的 DMA 描述符环 ↔ QEMU 的 OpenCores 网卡仿真）、**host 怎么反向访问 guest**（SLIRP 的 hostfwd 端口映射）。读完它，你得到的远不止知识——还有本章实验工程里那套**八步以太网 bring-up 序列**，它是这个系列后续所有联网章节的标准模板。源码参照：ESP-IDF v6.0.2（`~/esp/esp-idf`）、其捆绑 lwIP 2.2.0-dev、QEMU `esp_develop_9.2.2_20250817`；所有运行输出均来自本章工程 `practice/lwip-ch03-qemu-network-lab/` 的真实运行日志。

---

## 3.1 没有真机的联网方案：OpenCores 网卡 + SLIRP 用户态网络

### 1. 问题：板子不在桌上，网络实验从哪做起

后续二十章要做的 UDP/TCP/DNS/HTTP/MQTT 实验，最低要求是"应用层有一个能收发 IP 包的网卡"。真机当然可以，但排错要在两台设备间来回横跳，日志抓不到包也停不下断点。而 ESP-IDF 从 v4 起就在 QEMU 里做了完整的以太网仿真：

- **QEMU 一侧**仿真了一块 **OpenCores ethmac** 网卡（`hw/net/opencores_eth.c`），这是一颗开源 FPGA 以太网 MAC，寄存器简单、描述符规整；
- **网络出口**用的是 **SLIRP**（libslirp）——纯用户态实现的 NAT 网络，不需要主机 root、不需要 tap 设备和内核模块，guest 流量直接以普通 socket 流量从 QEMU 进程出去。

IDF v6 的 `idf.py qemu` 默认就会给 QEMU 追加 `-nic user,model=open_eth`。这是整个系列的物理层。

### 2. 拓扑：一张图看清帧的来路

```text
      ┌────────────────────── QEMU 进程（纯用户态） ──────────────────────┐
      │                                                                  │
      │   guest：ESP32（Xtensa LX6 双核，-M esp32）                        │
      │   ├── 你的应用（echo server / ping 会话 …）                        │
      │   ├── lwIP 协议栈（tcpip_thread，第十三章主角）                     │
      │   ├── esp_netif                                                   │
      │   └── openeth 驱动（esp_eth_mac_openeth.c）                        │
      │              ▲  RX/TX DMA 描述符环（EMAC 寄存器空间 +0x400）         │
      │              ▼                                                    │
      │        QEMU OpenCores ethmac 仿真                                 │
      └──────────────────────────┬───────────────────────────────────────┘
                                 │  完整以太网帧（含 ETH 头）
                                 ▼
                 ┌──────  SLIRP 用户态虚拟网络 10.0.2.0/24 ──────┐
                 │  10.0.2.2   网关/NAT 出口（也是"主机本人"别名） │
                 │  10.0.2.3   DNS 代理（转发宿主机解析器）        │
                 │  10.0.2.15  DHCP 分给 guest 的第一个地址       │
                 └──────────────────────┬───────────────────────┘
                                        │  NAT 成普通 socket 流量
                                        ▼
                        宿主机协议栈 ──► 本机其它服务 / 外网
```

三个地址各司其职，全部在本章实测过（见 3.4）：

| 地址        | 身份                   | 本章实测证据                      |
| ----------- | ---------------------- | --------------------------------- |
| `10.0.2.15` | DHCP 给 guest 的地址   | `GOT_IP: 10.0.2.15/255.255.255.0` |
| `10.0.2.2`  | 网关，也是"主机"的别名 | guest ping 它 5 发 5 收           |
| `10.0.2.3`  | SLIRP 内置 DNS 代理    | `DNS server from DHCP: 10.0.2.3`  |

注意方向语义的对称性：**设备→主机**方向的流量走 NAT（guest 主动发起即可到达主机任何可达网络）；而**主机→设备**方向默认不通——SLIRP 不知道你有连接需求，需要显式配置。

### 3. hostfwd：主机反向打进 guest 的钥匙

`-nic user,...` 支持 `hostfwd` 参数做反向端口映射。语法：

```bash
-nic user,model=open_eth,hostfwd=tcp::8003-:8888
#               ↑开放核开关      ↑主机端口    ↑guest 端口
```

含义：QEMU 在主机的 **8003** 端口监听 TCP 连接；每当有连接进来，就把这份数据"注入"到 SLIRP 网络中，伪装成一次来自 `10.0.2.2` 的连接发给 guest 的 **8888** 端口。本系列端口约定：**主机侧端口 = 8000 + 章号**，本章即 8003，避免多章并行实验抢端口。

> [!tip] 为什么这套环境特别适合学网络
> 你可以在同一台机器上同时拥有"设备的串口日志"、"wireshark 可抓的用户态流量"（SLIRP 流量就是 QEMU 进程发出的普通 socket 包）和"随时可改的主机侧对端"。第 23 章调试工具箱会大量利用这一点。

---

## 3.2 openeth 驱动解剖：一套完整却只有 440 行的 DMA 网卡驱动

ESP-IDF 的 openeth 驱动在 `components/esp_eth/src/openeth/`，对外头文件是 `include/esp_eth_mac_openeth.h`。文件不多：`esp_openeth.h`（中断号与寄存器基址映射）、`openeth.h`(寄存器定义 + 描述符结构)、`esp_eth_mac_openeth.c`（驱动本体）。

### 1. 它为什么存在：寄生在真实芯片的地址空间上

`esp_openeth.h` 开头的注释交代了设计前提——OpenCores MAC 并不存在于任何 Espressif 芯片，纯粹为了配合 QEMU：

```c
// For targets which don't have an ethernet MAC and the associated interrupt source,
// we can reuse the Wifi interrupt source for ethernet, since QEMU doesn't emulate Wifi (yet).
#if SOC_WIFI_SUPPORTED && !SOC_EMAC_SUPPORTED
#define ETS_ETH_MAC_INTR_SOURCE     ETS_WIFI_MAC_INTR_SOURCE
#define DR_REG_EMAC_BASE            0x600CD000
#endif
```

而在我们仿真的 esp32 目标上（有真实内部 EMAC），它直接复用内部 EMAC 的中断号 `ETS_ETH_MAC_INTR_SOURCE` 和寄存器基址 `DR_REG_EMAC_BASE`——因为 QEMU 恰好把 OpenCores 网卡映射到了同样的位置。驱动初始化时还会做一个防呆检查（`emac_opencores_init()`）：读 MODER 寄存器发现值不对就 `abort()`，错误信息直白地告诉你"这驱动只能跑在 QEMU 里"：

```c
if (REG_READ(OPENETH_MODER_REG) != OPENETH_MODER_DEFAULT) {
    ESP_LOGE(TAG, "CONFIG_ETH_USE_OPENETH should only be used when running in QEMU.");
    abort();
}
```

顺带一个实测彩蛋：第一次运行的日志里出现了 `esp_eth.netif.netif_glue: 52:54:00:12:34:56`——这是 QEMU 默认写在网卡 MAC 地址寄存器里的地址（52:54:00 正是 QEMU/KVM 虚拟网卡的经典前缀）。驱动 `init` 时先读寄存器，非零就直接采用；全零才回退到 `esp_read_mac(mac_addr, ESP_MAC_ETH)`。所以你在 QEMU 里看到的 MAC 与真机 eFuse 推导出的完全不同。

### 2. 描述符环：8 字节一个槽位的 DMA 语义教科书

OpenCores ethmac 的 DMA 描述符就是一个紧凑的 8 字节结构体（`openeth.h`，经过 `ESP_STATIC_ASSERT(sizeof(...) == 8)` 编译期验证）：

```c
typedef struct {
    uint16_t cs: 1; ... uint16_t rtry: 4; ... /* HW 置的状态位 */
    uint16_t crc: 1;    //!< Add CRC at the end of the packet
    uint16_t pad: 1;    //!< Add padding to the end of short packets
    uint16_t wr: 1;     //!< Wrap-around. 1: last descriptor in the table
    uint16_t irq: 1;
    uint16_t rd: 1;     //!< Descriptor ready. 1: owned by HW. Cleared by HW.
    uint16_t len;       //!< Number of bytes to be transmitted
    void* txpnt;        //!< Pointer to the data to transmit
} openeth_tx_desc_t;    /* RX 版本同尺寸：状态位 + wr/irq/e + len + rxpnt */
```

套路的骨干是每个 DMA 网卡都一样的三件套：

- **缓冲区指针 + 长度**：一帧数据放在哪、多长；
- **所有权位**：RX 的 `e` 位与 TX 的 `rd` 位表达"这一槽现在归硬件还是软件"；硬件消费完会翻转让软件取货；
- **`wr` 回卷位**：置在最后一个描述符上，硬件发完/收到它就跳回表头，构成逻辑上的环形队列。

驱动构造时（`esp_eth_mac_new_openeth()`）分配 **RX 缓冲 `CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM` 个（默认 4）×1600B**、**TX 缓冲 `CONFIG_ETH_OPENETH_DMA_TX_BUFFER_NUM` 个（默认 1）×1600B**，全部用 `heap_caps_calloc(..., MALLOC_CAP_DMA)` 保证可被 DMA 访问，然后把描述符初始化好：RX 描述符初始 `e=1 irq=1`（交给硬件等帧，收完发中断），末尾 `wr=1` 回卷。描述符表本体不占堆——它们固定在寄存器空间的 `OPENETH_DESC_BASE`（基址 +0x400，共 128 个槽位，TX 区在前 RX 区在后，`openeth_set_tx_desc_cnt()` 用 `TX_BD_NUM_REG` 告诉硬件分界）。

> [!note] 这就是你以后见到的每一张网卡的脸
> 第 4 章的 pbuf、第 8 章的以太网收发，底层都是这样一副骨架：**环 + 所有权翻转 + 中断通知**。STM32 的 ETH、ESP32 内部 EMAC、 Virtio-net，差异只在细节繁简。openeth 用不到百行代码把这三件事讲完了。

### 3. RX 路径：ISR 叫醒任务，任务搬运帧

收帧路径把"中断上下文只做最少量工作"的原则执行得很标准（`esp_eth_mac_openeth.c`）：

```c
static IRAM_ATTR void emac_opencores_isr_handler(void *args)
{
    ...
    if (status & OPENETH_INT_RXB) {           /* 收到一帧 */
        // Notify receive task
        vTaskNotifyGiveFromISR(emac->rx_task_hdl, &high_task_wakeup);
        if (high_task_wakeup) {
            portYIELD_FROM_ISR();
        }
    }
    ...
}
```

熟悉 [[2026-08-26-freertos-deep-dive-ch13-task-notifications|FreeRTOS 深度解析（十三）·任务通知]] 的读者应该会心一笑：网卡驱动就是"任务通知替代信号量做 ISR→任务唤醒"的最佳实践现场——零内核对象，开销最小。专用接收任务 `emac_rx_task` 被叫醒后在循环里逐个消费已填充的描述符：

```c
while (true) {
    length = ETH_MAX_PACKET_SIZE;
    buffer = malloc(length);
    ...
    } else if (emac_opencores_receive(&emac->parent, buffer, &length) == ESP_OK) {
        // pass the buffer to the upper layer
        emac->eth->stack_input(emac->eth, buffer, length);   /* 交给上层 */
    }
}
```

`emac_opencores_receive()` 检查当前 RX 描述符：若 `e==1` 说明还没数据（仍归硬件），返回错误退出本轮；否则按描述符里的 `len` 把 `rxpnt` 处的数据 memcpy 到新分配的缓冲区，重新把 `e` 置 1 归还硬件，推进游标 `cur_rx_desc`。最后那句 `eth->stack_input(...)` 是关键交接：mediator 结构里的 `stack_input` 回调由上层提供，openeth 驱动因此完全不知道 lwIP 的存在——解耦得干干净净。

### 4. TX 路径：写描述符即发送

发送更简单（`emac_opencores_transmit()`）：把待发帧切成 ≤1600B 的段依次填入 TX 描述符，每段置 `rd=1` 触发发送，最后一个描述符落 `wr=1` 注明回卷。源码注释也承认了它的"作弊"之处：

```c
// In QEMU, there never is a TX operation in progress, so start with descriptor 0.
```

QEMU 收到 `rd=1` 就立刻把帧搬进 SLIRP，不存在真实网卡上的 TX 完成中断、竞争重试、延迟等待。所以这个驱动的注释开头就声明："它是为 QEMU 写的，不做 QEMU 不会报的错误处理、不等 TX 完成"。同样，`set_speed/set_duplex/enable_flow_ctrl` 全部无条件接受任意值（注释原话：QEMU doesn't emulate ...）。

### 5. 为什么说它是 lwIP 教学的完美驱动

短小（主体约 440 行）、但五脏俱全：真实的 DMA 描述符环语义、真实的中断→任务→上层的分层交付、真实的 MII 总线读写（PHY 寄存器经由 MAC 的 MIICOMMAND 寄存器间接访问）。同时它砍掉了真芯片里最容易淹没初学者的部分：几百个特权寄存器、缓存一致性修补、重传计时器。用它建立心智模型，再去啃任何一颗真 MAC，都是降维打击。

---

## 3.3 以太网 bring-up 全流程：八个 API 步骤，一步不少

本章工程 `main/lab_main.c` 就是由下面这条序列组成的（**这就是系列后续 20 章的标准联网模板**，以下签名逐一核对自 ESP-IDF v6.0.2 头文件）：

```c
/* ① 初始化 esp_netif 层并创建默认事件循环 —— 必须最先做：
 *    esp_netif_init() 会创建 lwIP 的 tcpip_thread 并初始化其邮箱；
 *    此后才能有任何 socket/netif 操作。 */
ESP_ERROR_CHECK(esp_netif_init());                       /* esp_netif.h */
ESP_ERROR_CHECK(esp_event_loop_create_default());        /* esp_event.h */

/* ② 创建默认配置的以太网 esp_netif 实例 */
esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();  /* esp_netif_defaults.h */
esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

/* ③ 组装 MAC 对象（openeth）与 PHY 对象 */
eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
/*  rx_task_stack_size=4096, rx_task_prio=15, flags=0            esp_eth_mac.h */
eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
/*  phy_addr=ESP_ETH_PHY_ADDR_AUTO(-1 自动探测), autonego_timeout_ms=4000,
 *  reset_gpio_num=5 —— 仿真里无复位引脚，改 -1                  esp_eth_phy.h */
phy_cfg.reset_gpio_num = -1;

esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);  /* 仅 CONFIG_ETH_USE_OPENETH=y 时可用 */
esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);

/* ④ 安装驱动：把 MAC/PHY 缝进统一的 handle */
esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy); /* check_link_period_ms=2000 */
esp_eth_handle_t eth_handle = NULL;
ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));  /* esp_eth_driver.h */

/* ⑤ 注册事件处理器（在 start 之前！否则错过事件） */
ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                           &eth_event_handler, NULL));
ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                           &ip_event_handler, NULL));

/* ⑥ glue 层：把驱动句柄翻译成 netif 能理解的"IO 驱动"，再挂上去 */
esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));      /* esp_netif.h */

/* ⑦ 启动：PHY 复位/自动协商 → 链路 up → glue 把 netif 拉起并启动 DHCP 客户端 */
ESP_ERROR_CHECK(esp_eth_start(eth_handle));

/* ⑧ 等 IP_EVENT_ETH_GOT_IP 事件，从中取出 ip_info（我拿信号量同步） */
ip_event_got_ip_t *evt = event_data;   /* evt->ip_info.ip / .netmask / .gw */
```

几个容易含糊的点，以源码为准澄清：

- **PHY 选谁？** QEMU 在 OpenCores 网卡里附带仿真的是 **DP83848C** PHY（驱动源文件 `components/esp_eth/src/openeth/esp_eth_mac_openeth.c` 头部注释原文："The QEMU driver also emulates the DP83848C PHY"）。不过 IDF v6 主仓库已经不再内置具体 PHY 芯片驱动（v5 的 `esp_eth_phy_new_dp83848()` 已迁往 Component Registry），只剩标准 802.3 通用 PHY `esp_eth_phy_new_generic()`（实现在 `components/esp_eth/src/phy/esp_eth_phy_generic.c`）。DP83848C 是标准 802.3 MII 寄存器集，generic 驱动即可驱动：初始化时 `phy_addr = ESP_ETH_PHY_ADDR_AUTO` 会触发 `esp_eth_phy_802_3_detect_phy_addr()` 扫描 32 个地址找 ID 寄存器（`src/phy/esp_eth_phy_802_3.c`），随后普通自协商流程在 QEMU 里瞬时完成。我们的日志证实了这一点：`esp_eth_start` 后仅 100ms 就出现 `ETH_EVENT: CONNECTED (link up)`。
- **事件负载长什么样？** `IP_EVENT_ETH_GOT_IP` 的 payload 是 `ip_event_got_ip_t`（`esp_netif_types.h`）：`{ esp_netif_t *esp_netif; esp_netif_ip_info_t ip_info; bool ip_changed; }`，其中 `ip_info` 含 `ip/netmask/gw` 三组 `esp_ip4_addr_t`。
- **DHCP 不用你手动启。** glue 收到链路 up 事件后会自动替你启动 DHCP 客户端——调用链实测为 `esp_eth_netif_glue.c`（ETH 事件处理）→ `esp_netif_action_connected()` → `esp_netif_dhcpc_start()`（`components/esp_netif/esp_netif_handlers.c`）。这也是"attach 必须发生在 start 之前"的原因之一：先建立事件通道，`esp_eth_start()` 引发的连锁反应才有完整的接收方。
- **每一步都是幂等的样板**：后续章节只需要原样复制这段（或直接复用 `practice/lwip-ch03-qemu-network-lab/main/lab_main.c`），改动只在⑧之后——换成你要做的实验。

> [!warning] 一个真实的次序事故
> 初版代码我把 echo server 任务创建在了 `esp_netif_init()` 之前，任务里第一个 `socket()` 直接触发：
>
> ```text
> assert failed: tcpip_send_msg_wait_sem /IDF/components/lwip/lwip/src/api/tcpip.c:454 (Invalid mbox)
> ```
>
> `socket()` 的实现要向 tcpip_thread 的邮箱投递消息，而这个 mbox 正是 ① 里才创建的。这也是本系列暗线 A 的第一个实物标本：**Vanilla lwIP 的一切外部交互都要穿过 tcpip_thread 这个单线程信箱**（第十三、十四章主题），初始化顺序错误的报文值得专门记一笔。

---

## 3.4 实战实验：两个方向各打一枪，外加 DNS 加餐

实验工程：`practice/lwip-ch03-qemu-network-lab/`（从 hello_world 模板裁剪，`sdkconfig.defaults` 只有一行 `CONFIG_ETH_USE_OPENETH=y`——这是 openeth 驱动编译进固件的开关，Kconfig 位于 `components/esp_eth/Kconfig`，菜单名"Support OpenCores Ethernet MAC (for use with QEMU)"，默认关）。构建与运行遵循系列公约第 3 节：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch03-qemu-network-lab
idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true     # 生成 QEMU flash/efuse 镜像（monitor 无 TTY 会失败，忽略）

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 40 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot > run.log 2>&1
echo $?    # 124 = timeout 正常截停
```

### 0. 开跑之前：板上到底有几个玩家

实验开始前值得先点名。本章这一小段程序背后实际有六个执行流在协作，提前认清它们的脸，后面看日志时间戳就不会晕：

| 执行流                  | 由谁创建                                                                                      | 在干什么                                     |
| ----------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `main` 任务（app_main） | IDF 启动代码                                                                                  | 串起 3.3 节八步序列，然后阻塞等 IP 信号量    |
| `emac_rx` 任务          | openeth 驱动 `esp_eth_mac_new_openeth()`（栈 4096B 优先级 15，来自 `ETH_MAC_DEFAULT_CONFIG`） | 挂起等中断的 `ulTaskNotifyTake`，醒来搬帧    |
| `tcpip` 任务            | `esp_netif_init()`（lwIP 的 tcpip_thread）                                                    | 协议栈的心脏，所有 socket 消息的信箱收发室   |
| 默认事件循环任务        | `esp_event_loop_create_default()`                                                             | 分发 `ETH_EVENT`/`IP_EVENT` 到我们的 handler |
| `echo_srv` 任务         | 本章 app 自己                                                                                 | accept/recv/send 三板斧                      |
| ping 内部任务           | `esp_ping_new_session()`（优先级 2，见 `ESP_PING_DEFAULT_CONFIG`）                            | 定时发 ICMP、计时收应答                      |

日志里的毫秒数全部出自 FreeRTOS tick 计时；对比各条日志的时间戳差，就能反推每个环节的耗时（例如 DHCP 一秒 vs 自协商 100ms）。

### 1. 实验 A（设备→主机方向）：DHCP 之后 ping 网关 10.0.2.2

实验目的：验证整条仿真链路的第一包。用 IDF 的 ping 应用组件发起 ICMP Echo——注意版本事实：**IDF v6 已没有独立的 `esp_ping` 组件**，ping 的 API 直接由 lwIP 组件自带（`components/lwip/include/apps/ping/ping_sock.h`，实现 `apps/ping/ping_sock.c`），用法是注册回调 + 开会话，`PRIV_REQUIRES` 带 `lwip` 即可：

```c
esp_ping_callbacks_t cbs = {
    .cb_args         = (void *)"10.0.2.2 (slirp gateway)",
    .on_ping_success = on_ping_success,
    .on_ping_timeout = on_ping_timeout,
    .on_ping_end     = on_ping_end,
};
esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();  /* count=5 interval=1000ms timeout=1000ms */
cfg.target_addr = target;                           /* ip_addr_t，装网关 10.0.2.2 */
cfg.interval_ms = 200;                              /* 加速实验节奏 */
esp_ping_handle_t hdl = NULL;
ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
esp_ping_start(hdl);
```

完整开机至 ping 统计的真实输出摘录（run.log，未删改）：

```text
I (1569) ch3lab: == ch3 lab: openeth bring-up / ping gw / tcp echo / dns ==
I (1569) ch3lab: echo server listening on 0.0.0.0:8888
I (1599) esp_eth.netif.netif_glue: 52:54:00:12:34:56
I (1599) esp_eth.netif.netif_glue: ethernet attached to netif
I (1699) ch3lab: ETH_EVENT: START
E (1699) esp_eth.netif.netif_glue: eth_set_mac_filter(56): failed to add mac filter
I (1699) ch3lab: ETH_EVENT: CONNECTED (link up)
I (1699) ch3lab: waiting for DHCP lease ...
I (2699) ch3lab: GOT_IP: 10.0.2.15/255.255.255.0 gw 10.0.2.2
I (2699) esp_netif_handlers: eth ip: 10.0.2.15, mask: 255.255.255.0, gw: 10.0.2.2
I (2699) ch3lab: DNS server from DHCP: 10.0.2.3
I (2699) ch3lab: --- experiment A: ping gateway 10.0.2.2 ---
I (2699) ch3lab: 64 bytes from 10.0.2.2 icmp_seq=1 ttl=255 time=1 ms
I (2899) ch3lab: 64 bytes from 10.0.2.2 icmp_seq=2 ttl=255 time=1 ms
I (3099) ch3lab: 64 bytes from 10.0.2.2 icmp_seq=3 ttl=255 time=0 ms
I (3299) ch3lab: 64 bytes from 10.0.2.2 icmp_seq=4 ttl=255 time=0 ms
I (3499) ch3lab: 64 bytes from 10.0.2.2 icmp_seq=5 ttl=255 time=0 ms
I (3699) ch3lab: --- 10.0.2.2 (slirp gateway) ping statistics ---
I (3699) ch3lab: 5 packets transmitted, 5 received, 0% packet loss, time 2ms
```

结果解读：

1. **时间线浓缩了 3.3 节的全部环节**：start 后 100ms 链路 up（自协商即时完成），整整 1 秒后拿到 IP——那一秒就是 DHCP 的 DISCOVER/OFFER/REQUEST/ACK 四步在 SLIRP 上往返。从此 guest 有了身份。
2. **`ttl=255` 是网关亲自回话的指纹**：SLIRP 作为协议栈终点应答而不是转发者，TTL 保持默认满值；延迟 0~1ms 也印证"对端不是在电缆尽头，而是在同一个进程里"。
3. 日志里那行 `eth_set_mac_filter` 错误见 3.5 的坑清单，属预期噪音，不影响功能。

### 2. 实验 B（主机→设备方向）：hostfwd 把 nc 的输入送进 guest

实验目的：验证反向通路与 guest 上的 socket 服务端。app 里早已起好了一个极小的 TCP echo 任务（标准 BSD socket 序列 `socket/bind/listen/accept/recv/send`，绑定 `INADDR_ANY:8888`），这次带 hostfwd 重启 QEMU：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 60 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8003-:8888 \
  -nographic -no-reboot > echo_run.log 2>&1 &
sleep 12                                   # 等 DHCP 完成
printf 'hello from host\nlwip ch3 echo test\n' | nc localhost 8003
```

主机端的输出——原样回显回来了：

```text
hello from host
lwip ch3 echo test
```

同一时刻 guest 侧串口日志（echo_run.log）：

```text
I (45405) ch3lab: echo: client 10.0.2.2:49160 connected
I (45405) ch3lab: echo: recv 35 bytes: hello from host
lwip ch3 echo test

I (45405) ch3lab: echo: client disconnected
qemu-system-xtensa: terminating on signal 15 from pid 3176747 (timeout)
```

结果解读：

1. **对 guest 来说，客户端是 `10.0.2.2:49160`**——hostfwd 注入的连接被 SLIRP 包装成"网关本人"的一次主动访问。你在服务端日志里永远看不到"真正的主机地址"，这是调试时重要的心智修正。
2. 两行文本合成了一次 `recv 35 bytes`：TCP 是字节流，两次 `printf` 输出进入同一个段被一并送达（第十一章起我们会反复强调"TCP 没有'条数'"这个概念，这就是活教材）。
3. 回显后立刻 disconnect，是因为 `printf | nc` 的组合里 printf 结束后管道关闭、nc 关闭了发送半边，guest 的下一次 `recv` 返回 0 顺势关闭连接——FIN 甚至赶在同一个毫秒里。回显数据则先一步完整送达。
4. 最后那行 `terminating on signal 15` 只是外层 timeout 如约收割 QEMU，不是异常。

### 3. 实验 C（加分项）：SLIRP 的 DNS 到底怎么答

实验目的：搞清楚 guest 解析域名时谁在回答。回顾 3.4.1 日志：DHCP 下发的 DNS 是 `10.0.2.3`——SLIRP 内置的 DNS 代理。我们在 app 里用 `getaddrinfo()`（lwIP 实现，`src/api/netdb.c` 的 `lwip_getaddrinfo`）连续问三个名字，同时在**宿主机** `/etc/hosts` 里预先注入一条记录制造证据：

```bash
echo "192.0.2.123 lwip3slirp.test" | sudo tee -a /etc/hosts
```

然后重启 QEMU 跑到实验 C（代码已包含三条探针），真实输出：

```text
I (8699) ch3lab: --- experiment C: slirp DNS probes ---
I (8709) ch3lab: DNS probe "baidu.com" -> 198.18.1.95
I (8709) ch3lab: DNS probe "lwip3slirp.test" -> 192.0.2.123
W (8719) ch3lab: DNS probe "no-such-host-ch3.invalid": FAILED rc=202
```

结果解读：

1. **`lwip3slirp.test -> 192.0.2.123`：分毫不差的命中**。这个名字在公网根本不存在，唯一来源是我们刚写进宿主机 `/etc/hosts` 的行。结论实测成立：**SLIRP 的 DNS 代理会查阅宿主机 `/etc/hosts`**，之后才是递归转发。想给实验伪造稳定域名（比如让 guest 连"mqtt.example"实际打到主机的 mosquitto），一行 hosts 就够。
2. **`baidu.com -> 198.18.1.95` 诚实透传了宿主机的解析行为**。198.18.0.0/15 是 RFC 2544 基准测试保留段，典型于本机代理工具的 fake-ip 模式输出。教训很好：guest 看到的 DNS 答案 = 宿主机解析环境的原样镜像，排查"guest 解析异常"时要意识到锅可能在宿主机网络上。
3. **`no-such-host-ch3.invalid` 拿到 rc=202**，对照 `components/lwip/lwip/src/include/lwip/netdb.h` 的定义正是 `EAI_FAIL`——上游解析失败如实折返成 socket API 错误码。这就是为什么故障注入章可以直接从"篡改解析结果"入手。
4. 附带的边界说明：socket API 这一层没有顺手可用的 PTR 反向解析（需自己组 DNS 报文），留作后续 UDP 动手章的练习题素材。

---

## 3.5 常见坑清单：每一个都在本章踩实过

| #   | 坑                                     | 现象                                                                                    | 解法/原因                                                                                                                                                                                                                                               |
| --- | -------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `idf.py qemu monitor` 需要 TTY         | monitor 报 `failed with exit code 1`                                                    | 公约第 3 节的直接运行模式绕开它；`idf.py qemu` 的主要产物（flash/efuse 镜像）在任何情况下都已生成                                                                                                                                                       |
| 2   | 在 `esp_netif_init()` 前调 socket 函数 | `assert failed: tcpip_send_msg_wait_sem ... (Invalid mbox)` 且复位                      | tcpip 线程与邮箱尚未创建；先 `esp_netif_init()` 再动任何 socket/netif API                                                                                                                                                                               |
| 3   | 退出码误判                             | `timeout ... ; echo $?` 得 124 而应用明明活着                                           | 124 = timeout 正常截停 QEMU；应用主动崩溃复位后因 `-no-reboot` 则以 0/-1 干净退出；如果像本章首次那样接了管道（`tee \| grep`）                                                                                                                          |
| 4   | 忘配 hostfwd 还想从主机连 guest        | 主机侧瞬间 `connection refused`                                                         | 没人监听那个主机端口——SLIRP 默认不暴露 guest；加 `hostfwd=tcp::8003-:8888` 重启                                                                                                                                                                         |
| 5   | DHCP 十秒没拿到 IP                     | 卡在 `waiting for DHCP lease ...`                                                       | 按序查：(a) QEMU 命令有没有 `-nic user,model=open_eth`；(b) 日志里有无 `ETH_EVENT: CONNECTED`——没有则 PHY 自协商没成（查 phy 配置）；(c) `esp_netif_attach` 是否在 `esp_eth_start` 之前完成；(d) 是否意外把固件烧到了真机而 openeth 防呆 `abort()` 触发 |
| 6   | 日志刷 `failed to add mac filter` 三连 | `esp_eth_ioctl(533): add mac address to filter not supported` + glue/netif 两条跟随错误 | openeth 未实现 `ETH_CMD_ADD_MAC_FILTER` ioctl，glue 挂钩 netif 时尝试加组播过滤即报错。预期噪音，组播照收（QEMU 网卡没有过滤概念），可用 grep 心理过滤                                                                                                  |
| 7   | 沿用 `ETH_PHY_DEFAULT_CONFIG()` 原样   | 无害但别扭                                                                              | 默认 `reset_gpio_num=5` 在 QEMU 没意义；显式设 -1 表达意图                                                                                                                                                                                              |

---

## 3.6 Vanilla lwIP 与 ESP-IDF lwIP：同一个以太网入口的两副装修

把"裸 lwIP 移植如何接入一块网卡"与"IDF 里我们刚做过的事"并排放，能看得非常清楚。

裸移植（vanilla `ethernetif.c` 模式）下，你必须亲手完成的工作清单：

1. 实现 `low_level_init()`：复位 MAC、建 DMA 描述符环、挂中断、起收包线程；
2. 实现 `low_level_output()`：申请 pbuf、填 TX 描述符、踢硬件；
3. 实现收包路径：中断/轮询拿帧 → `pbuf_alloc(PBUF_RAW, ...)` → 从描述符拷进 pbuf 链 → `netif->input(p, netif)`（以太网用 `ethernet_input`）塞进 tcpip_thread；
4. 自己管理"链接状态变化"→ 手动调用 `netif_set_link_up/down`、自己拉起 `dhcp_start()`。

而 IDF 把 1~4 整体封装成了三层可组合的对象，本章的八步序列其实就是把它们拼起来：

| 维度           | Vanilla 移植           | ESP-IDF 封装（v6）                                                                                             |
| -------------- | ---------------------- | -------------------------------------------------------------------------------------------------------------- |
| 驱动抽象       | 无，各移植自便         | `esp_eth_mac_t` / `esp_eth_phy_t` 两组虚函数表 + `esp_eth_mediator_t` 中介者（`stack_input` 就是其中的上行口） |
| 你的手写量     | ethernetif.c 全部      | 选工厂函数：`esp_eth_mac_new_openeth()` + `esp_eth_phy_new_generic()`                                          |
| 收包交付       | 自己 `netif->input(p)` | 驱动调 `eth->stack_input(...)`，层层回调最终由 esp_netif 送进 lwIP                                             |
| link/dhcp 管理 | 手工编排               | `esp_eth_netif_glue` 监听 `ETH_EVENT`，自动 `netif up` + `dhcp_start`，再回报 `IP_EVENT_ETH_GOT_IP`            |
| 事件模型       | 无事件总线             | `esp_event`：`ETH_EVENT`（`ETHERNET_EVENT_*`）与 `IP_EVENT` 统一分发，注册制                                   |
| 裁剪方式       | 改 `lwipopts.h`        | menuconfig Kconfig（如本章 `CONFIG_ETH_USE_OPENETH=y`），外加 IDF 特有开关                                     |
| 可插拔点       | 手术级自由             | 官方 Hook：`esp_eth_config_t.stack_input` 允许截胡收到的每一帧——第 23 章做抓包/注入就用它                      |

但值得点破的是：**IDF 没有替换 lwIP 的一根毛细血管**。tcpip*thread、netif、pbuf、socket 这些仍是上游原味；IDF 注入的是"网卡驱动之上的统一生命周期管理"与"RTOS 世界的装配线"（esp_event 事件总线、FreeRTOS 任务、esp_netif 的 config 对象模型）。理解了这个分层，你就知道遇到问题时该去哪一层抓凶手：收发包行为异常找 `esp_eth*\*/openeth` 层，IP 以上的诡异多半在 lwIP 或你的应用——而协议栈内部的行进路线，从下一章开始逐步展开。

---

## 3.7 小结

- **没有真机也有整条互联网**：QEMU 仿真 OpenCores ethmac 网卡 + SLIRP 用户态 NAT 网络。guest 经 DHCP 拿 `10.0.2.15`，网关/主机别名 `10.0.2.2`，DNS 代理 `10.0.2.3`（三者均本章实测）；hostfwd 让主机反向打入 guest，端口约定 8000+章号。
- **openeth 驱动是微型教学杰作**：8 字节 DMA 描述符构成的环 + 所有权位（RX `e` / TX `rd`）+ `wr` 回卷位，ISR 用任务通知唤醒 rx task，task 拷帧后经 `stack_input` 上交，TX 写描述符即发送。它寄生在 ESP32 内部 EMAC 的寄存器地址与中断号上，仅限 QEMU 使用。
- **八步 bring-up 模板**：`esp_netif_init` → `esp_event_loop_create_default` → `esp_netif_new(ESP_NETIF_DEFAULT_ETH())` → `esp_eth_mac_new_openeth` + `esp_eth_phy_new_generic`（DP83848C 由 generic 驱动兼容，IDF v6 无独立芯片 PHY 组件）→ `esp_eth_driver_install(ETH_DEFAULT_CONFIG())` → 注册 `ETH_EVENT`/`IP_EVENT_ETH_GOT_IP` → `esp_eth_new_netif_glue` + `esp_netif_attach` → `esp_eth_start` 等事件。顺序不可乱：tcpip 线程未起前碰 socket 直接 assert；glue 必须 attach 于 start 之前。
- **双向通路均已实证**：设备→主机，`esp_ping` 五发五收 ping 通网关（ttl=255、丢包 0%）；主机→设备，`nc localhost 8003` 的两行文本在 guest TCP echo 完整往返。SLIRP DNS 三连测：代答会查宿主机 `/etc/hosts`（192.0.2.123 精确命中）、公网请求透传宿主机解析器、失败路径返回 `EAI_FAIL(202)`。
- **本工程 `practice/lwip-ch03-qemu-network-lab/main/` 即系列后续 20 章的标准联网模板**——每章联网实验从这里复制起步，只需替换"拿到 IP 之后做什么"。
- Vanilla 对照记住了三件事：IDF 用 MAC/PHY/glue 三层对象取代手写 ethernetif.c；link 状态与 DHCP 的编排进了 glue 层自动化；`stack_input` 等官方钩子保留了手术刀级的插桩能力。

第一包通了，但通得有点"囫囵"：我们一直没有回答**一帧数据在 lwIP 内部到底长什么样**——`recv` 返回的那 35 字节、ping 应答里那 64 字节，都是被一种叫 pbuf 的结构装载、切片、链起来的。下一章解剖这个 lwIP 最核心的数据结构，看看零拷贝的故事如何从一个缓冲区描述符讲起：[[2026-08-26-lwip-deep-dive-ch4-pbuf-anatomy|第四章《pbuf 解剖》]]。
