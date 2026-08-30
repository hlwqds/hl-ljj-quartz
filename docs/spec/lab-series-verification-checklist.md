# 双系列实验核销工单（F429 × RPi）

- 生成：2026-08-30，30 章「先成文」批次验收后汇总自七位子 agent 的交付汇报
- 用法：实验期逐项核销；与真机不符的，按 KD 流程修正文章并在本表打勾备注。
  每章完整清单以文中「待核对」小节为准，本表为执行视图（含全部条目，措辞压缩）。
- 关联 spec：`fire-challenger-f429-teaching-series.md` / `rpi-linux-lab-series.md`
- 硬件阻塞项（先解决再做对应实验）：见文末「板卡事实缺口」

## F429 系列

### ch01 SysTick

- [ ] CALIB 实测值（mdw 0xE000E01C，读前猜不准教学项）
- [ ] LED 引脚（J73，宏占位）
- [ ] COUNTFLAG 读清语义（连读两次对比）
- [ ] 节拍累积漂移
- [ ] FreeRTOS 固件下 SHPR3 高字节 0xF0F0

### ch02 按键

- [ ] KEY1/KEY2 引脚号（候选 PA0/PC13 未核实，三处宏同步）
- [ ] 有效电平/上下拉方向（假设低有效+上拉）
- [ ] 抖动时长（假设 5–10ms）
- [ ] 20ms 消抖窗口漏计测试
- [ ] 使能链快照 5 项 mdw
- [ ] 按住时 PR 挂起位可观测性

### ch03 PWM 蜂鸣器

- [ ] PI11 有无 TIM 通道及 AF 编号（决定切硬件 PWM；倾向无）
- [ ] 蜂鸣器有源/无源（听感判据）
- [ ] 驱动电路形态与限流
- [ ] TIM 通道引脚黑排针可用性（PB6=TIM4_CH1 候选）
- [ ] 音准表实测（注意软方波口径：ARR≈硬件值一半）
- [ ] TIM4 四寄存器快照

### ch04 ADC

- [ ] J77 已盖
- [ ] PC3=ADC123_IN13 实测核销
- [ ] VREF+ 实际电压（按 3.3V 占位）
- [ ] 电位器阻值
- [ ] tSTAB
- [ ] ADCPRE 故意 /2 超频对照组
- [ ] 五项寄存器快照

### ch05 总线矩阵（理论章）

- [ ] BusMatrix 主从完整清单 vs RM0090
- [ ] 板上 FMC SDRAM 是否焊装
- [ ] CCM 执行代码实测（ch13 兑现）
- [ ] SRAM1/2/3 分端口并发收益（ch10/11 顺带）
- [ ] objdump -h 双地址核对

### ch06 UART 中断+环形缓冲

- [ ] maxw 实测值
- [ ] 丢新/丢旧 158/866 推导数 vs 实测
- [ ] ORE 中断风暴复现（openocd reg pc）
- [ ] TXE 自关/重开竞态压测
- [ ] NVIC 优先级 0x40 下 g_ms 节拍
- [ ] CH340/USB 突发吞吐上限

### ch07 SPI Flash

- [ ] **W25Q64 挂载控制器与引脚**（SPI1/SPI5/QUADSPI 三候选，头号空白；PA5 与 J78 冲突存疑）
- [ ] JEDEC ID=EF 40 17
- [ ] 50MHz 读上限与 BR 提速档
- [ ] 擦/写时长（polls 换算）
- [ ] 复位期 CS 幽灵事务

### ch08 I2C 双板

- [ ] I2C1 PB6/PB7 黑排针引出（宏占位）
- [ ] RPi 1.8k 上拉实测
- [ ] 0x2A 地址空位预扫
- [ ] 扫描期 EVT_WADDR 恰一次
- [ ] af=rd 等式
- [ ] 时钟拉伸可观测性
- [ ] CCR/TRISE 从机最小值口径

### ch09 piscope 波形

- [ ] piscope 在 Bookworm 的安装途径与 ssh -X 可行性
- [ ] pigpiod -s 1 稳定性
- [ ] 2.84µs/位在 1µs 采样下的解码稳定性
- [ ] BCM↔物理引脚对照
- [ ] 探头电容扰动
- [ ] SPI 模式 1/2 读值形态
- [ ] fx2lpo（¥50/24MHz）到货后全实验重跑对照

### ch10 USART DMA

- [ ] DMA 映射实跑终验（RX=S2C4/TX=S7C4）
- [ ] 空转计数率标定（≈36M/s 推导）
- [ ] DMA 版与空载「无差别」假说
- [ ] IDLE 清序（读 SR+读 DR）有效性
- [ ] > 64B 帧降级形态
- [ ] RXNEIE 残留风暴
- [ ] 寄存器快照六项（S2CR/S7CR 等带推导值）

### ch11 ADC+DMA

- [ ] SCAN/CONT/DMA/DDS 组合与 S4C0 终验
- [ ] 满速 45.73kS/s 推导核销
- [ ] ht:tc≈1:1 长跑
- [ ] 逻辑覆盖断层形态
- [ ] TIM2_TRGO=EXTSEL 0b0110 编码
- [ ] 波形两端与 ch04 raw 互证

### ch12 优先级契约

- [ ] FreeRTOSConfig 三件套 grep 终验 + mdw SHPR3=0xF0F00000
- [ ] assert 具体行号（文中留 NNN）
- [ ] TIM3=IRQ29 推导
- [ ] 唤醒延迟 tick 上界
- [ ] BASEPRI 调试器可读性
- [ ] 关 configASSERT 的静默违规（高危对照组）
- [ ] 盲区（0–4）不调内核 API 时无害性

### ch13 CCM 隔离

- [ ] 真实翻车形态（TEIF/数据不落/线上垃圾/NDTR 原地，实跑回填）
- [ ] mdw 0x10000000 经 AHB-AP 可达性（双结果设计）
- [ ] TE 后 stream 行为
- [ ] .ccm 段落位（nm/objdump）
- [ ] CCM 正面用法收益
- [ ] 顺带核销 ch05 待核对#4

### ch14 栈单位

- [ ] pad[900] 实际余量（-O0 帧肥）
- [ ] pad[1100] 翻车形态（hook/静默/水位归零三选）
- [ ] fast/slow 高水位实测
- [ ] sizeof(TCB_t)（按 110–130B 估）
- [ ] ucHeap 落址
- [ ] 第 8 个 2048 字任务触发 malloc failed hook

### ch15 完美 RR

- [ ] ABAB 严格性与周期对周期
- [ ] 对照组①出线时序（同优先级 ≤1ms vs 低优先级 ≈51ms）
- [ ] 对照组②忙旋行周期/相位
- [ ] DWT 三寄存器 mdw 读回
- [ ] A 先于 B 唤醒的旁证
- [ ] 忙旋期 tick 不丢

### ch16 栈高水位

- [ ] 爆栈层号（推导 4±1）与 hook 触发时机
- [ ] 对照组水位 ≈550–600 字
- [ ] mdw 海岸线=栈基+水位×4（双证据链合流点）
- [ ] ucHeap/hook 地址回填
- [ ] 非标准死法排查
- [ ] 每层实际帧耗

### ch17 PendSV 单步

- [ ] reg lr=0xfffffffd 采样
- [ ] 硬件帧 PC 落 vTaskDelay 链
- [ ] stmdb 后 PSP−0x24 逐步快照
- [ ] push 走 MSP 场景
- [ ] pxCurrentTCB→pcTaskName 换手序列
- [ ] bx lr 单步行为
- [ ] BASEPRI=0x50

### ch18 FPU lazy stacking

- [ ] FPCCR=0xC0000000 及复位值
- [ ] 两种 EXC_RETURN 实测
- [ ] LSPACT 前 1 后 0（补搬触发规则，最关键实测点）
- [ ] 欠账区补搬前后两帧快照
- [ ] 51 字总深度
- [ ] 「省 ~17 周期」ARM 口径
- [ ] 清 LSPEN 对照实验

### ch19 heap_4 碎片

- [ ] sizeof(TCB_t) 实测（112B 占位）
- [ ] ucHeap 落址与对齐损失（当前构建 0x2000010c/损 4B）
- [ ] S0 基线 / S2 分叉 4112B 且 blocks=3
- [ ] 跨洞 malloc 失败/清场成功
- [ ] min-ever 不回升
- [ ] smallest block=2056
- [ ] 块头 MSB 字段级验证

### ch20 EMAC/PHY

- [ ] **PHY 型号与 ID**（LAN8720 预期 0x0007C0F0 / LAN8742 以手册为准）
- [ ] PHY 地址（候选 0/1，扫描 0–31 兜底）
- [ ] REF_CLK 方案（PHY 出 50MHz vs 外部时钟）
- [ ] RMII 九脚实际走线（TX 侧 PG11/13/14 vs PB 备选）
- [ ] MDC 分频 Div102 实测（180MHz 超出 CMSIS 注释区间，LA 抓 PC1）
- [ ] TX 描述符位序与对齐要求终核
- [ ] PHY nRST 独立复位脚

### ch21 裸机 lwIP

- [ ] ARP/ping tcpdump 真实输出核销
- [ ] REF_CLK（抓不到包第一嫌疑）
- [ ] pbuf 池深+自旋等待极限
- [ ] TDES0 位序实测
- [ ] DHCP 全流程（RPi dnsmasq）
- [ ] tcpip_thread 栈深
- [ ] lwip 2.2.0 与 IDF 2.2.0-dev 差异

### ch22 全家对照

- [ ] 全部对比数值（吞吐/RTT/内存/LOC）
- [ ] IDF iperf 与 iperf3 协议兼容性
- [ ] F429 瓶颈层归因
- [ ] ESP32 可用堆实测
- [ ] PHY 型号传导
- [ ] DMASR.RBU 丢帧发票率
- [ ] lwIP 两版本差异传导

## RPi 系列

### ch01 Bookworm 手术

- [ ] uname -r 精确字符串
- [ ] Imager 定制入口（向导 vs Ctrl+Shift+X）
- [ ] Bookworm ssh 是否 ssh.socket 激活
- [ ] Imager 建户默认 NOPASSWD sudo
- [ ] 笔记本 firewalld 对 shared 网段策略
- [ ] GPIO17=物理引脚 11 板图复核

### ch02 devmem

- [ ] GPFSEL1 默认值（GPIO14/15 alt0）
- [ ] 本机 STRICT_DEVMEM/IO_STRICT 实配
- [ ] busybox devmem WIDTH 语义
- [ ] pinctrl/raspi-gpio 包名与输出
- [ ] /sys/class/gpio 的 gpiochip base
- [ ] 寄存器偏移对手册逐项复核

### ch03 libgpiod

- [ ] 实机 libgpiod 版本（预期 1.6.3）
- [ ] /dev/gpiochip0 权限与 pi 的 gpio 组
- [ ] /dev/gpiomem 存在性
- [ ] v2 选项拼写（-e rising）
- [ ] gpiomon v1 选项拼写
- [ ] 三档速率量级（10²/10⁵–10⁶/10⁶–10⁷ Hz）实测
- [ ] gpiodetect 标签与行数

### ch04 内核模块

- [ ] headers 版本咬合与 vermagic 报错文案
- [ ] misc sysfs 路径确切形态
- [ ] /proc/iomem 持有者行
- [ ] udev trigger 写法行为
- [ ] pi 默认组
- [ ] mygpio_read 的 cat 两轮语义 strace 验证

### ch05 request_irq

- [ ] BCM2711 上电默认上拉覆盖 GPIO0–8（pinctrl get 4 交叉验）
- [ ] gpiod_to_irq 返回的 IRQ 号形态
- [ ] 底半线程名/优先级
- [ ] 跨板彩蛋的 STM32 空闲输出引脚选脚

### ch06 设备树

- [ ] /proc/device-tree 下 spi/gpio 节点路径与 compatible 实值
- [ ] 自制 overlay target=spidev0 合并是否通过
- [ ] dtoverlay -l / vclog --msg 可用性
- [ ] dtoverlay=spi0-2cs 整体替换 dtparam=spi=on 的假设

### ch07 全栈跟踪

- [ ] available*filter_functions 里 bcm2835_spi*\* 集合
- [ ] 4 字节@1MHz 走 poll/irq/dma 哪条（中断悖论验证）
- [ ] set_graph_function 通配符
- [ ] spidev read() 回环读出值（预期 0x00）

### ch08 仪器手册

- [ ] pigpiod/piscope 包名与 Fedora 远程构建
- [ ] Bookworm 出厂 I2C 默认态
- [ ] hostapd 是否出厂 masked
- [ ] usbmon built-in/模块
- [ ] BOX-3 VID/PID（板在途）

## 板卡事实缺口（硬件级阻塞，优先核销）

| #   | 缺口                       | 影响章节    | 核销方式               |
| --- | -------------------------- | ----------- | ---------------------- |
| 1   | W25Q64 挂载控制器/引脚     | ch07/09/22  | 野火教程/原理图/万用表 |
| 2   | KEY1/KEY2、LED 引脚号      | ch01/02/03  | 原理图/丝印            |
| 3   | PHY 型号/地址/REF_CLK 方案 | ch20-22     | 丝印+MDIO 扫描         |
| 4   | PI11 复用与蜂鸣器驱动电路  | ch03        | 原理图                 |
| 5   | I2C1 PB6/PB7 是否引出      | ch08        | 排针丝印               |
| 6   | fx2lpo 逻辑分析仪到货      | ch09 对照   | 采购 ~¥50              |
| 7   | 杜邦线/LED/电阻小包        | RPi ch02-04 | 采购 ~¥10              |
| 8   | LAN8742 PHY ID2 值         | ch20        | Microchip 手册         |

## 小白化修订期发现的原文疑点（2026-08-30 补记）

修订 agent 实读源码/手册时发现，均按「只增不删」原则在文中加了复核提示、未改原文，实跑时逐项裁决：

| #   | 位置         | 疑点                                                                             | 裁决方式                                   |
| --- | ------------ | -------------------------------------------------------------------------------- | ------------------------------------------ |
| 1   | F429 ch04    | ADCPRE 编码表与 RM0090 口径不符（原文 10=/8、11=/6；手册 00=/2…11=/8）           | 实测任一编码下实验结论不变；改表以手册为准 |
| 2   | F429 ch03    | 音阶表「ARR=1911→523.29Hz」疑似少 +1（1e6/ARR 而非 1e6/(ARR+1)）                 | 实测音准或重算                             |
| 3   | F429 ch12    | `0xE000E474（NVIC_IPR[29]）`地址疑误：按字节打包应为 0xE000E41D（字 0xE000E41C） | mdw 双地址读回                             |
| 4   | F429 ch15    | 对照组②「每行约 12 字符」与预期输出「≈13 字符」口径差 1                          | 统一口径                                   |
| 5   | F429 ch22    | 「94.1Mbps 理论天花板」疑为千兆 941M 等比缩放；1500B 帧口径约 95–97Mbps          | 实测后按帧长口径重算                       |
| 6   | F429 ch16/17 | openocd `bp` 对 Thumb 位（函数地址最低位 1）是否自动取偶，依版本而异             | 实测断点能否命中                           |
