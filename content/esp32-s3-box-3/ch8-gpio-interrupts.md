---
title: "ESP32-S3-BOX-3 工程实战（八）：GPIO 与中断"
date: 2026-08-26 12:00:00
description: "以背光 GPIO47 和触摸 INT GPIO3 为线索走满四层下钻：gpio_config 逐字段与 ISR 服务三步走（L1）、esp_driver_gpio 如何用一个 CPU 中断槽分发 45 个脚的中断（L2）、S3 的 IO MUX vs GPIO Matrix 与 strap 引脚（L3）、背光翻转波形与按键抖动（L4）；实验把触摸中断用任务通知转发给任务——本系列的标准姿势。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（八）：GPIO 与中断

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch7-system-services|第七章：系统服务层]]
> **第八章：GPIO 与中断**（当前章）
> 下一章：[[ch9-i2c-sensors|第九章：I2C 与传感器]]

GPIO 是所有外设章节的地基：第九章 I2C、第十章 SPI 的每一根信号线，最后都落在某个 GPIO 上。本章是系列方法论「四层下钻」的**第一次完整示范**——选两个 BOX-3 上真实存在的 GPIO：屏幕背光 `GPIO47`（输出）和触摸中断 `GPIO3`（输入+中断），从应用 API 一路打到物理波形。所有源码引用均为本地实地读取（esp-idf v6.0.2、esp-box 仓库 factory_demo 的 managed_components），行号以当前工作副本为准。

---

## 8.1 L1 应用 API：gpio_config 与中断服务三步走

### 1. gpio_config_t 逐字段

`driver/gpio.h` 里的定义（实地读取，v6.0.2）：

```c
typedef struct {
    uint64_t pin_bit_mask;          /*!< GPIO pin: set with bit mask, each bit maps to a GPIO */
    gpio_mode_t mode;               /*!< GPIO mode: set input/output mode                     */
    gpio_pullup_t pull_up_en;       /*!< GPIO pull-up                                         */
    gpio_pulldown_t pull_down_en;   /*!< GPIO pull-down                                       */
    gpio_int_type_t intr_type;      /*!< GPIO interrupt type                                  */
} gpio_config_t;
```

（支持迟滞过滤器的芯片还有第六个字段 `hys_ctrl_mode`；S3 没有该硬件，结构体到此为止。）

| 字段                          | 取值                                                             | 要点                                                                                                                                                                            |
| ----------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pin_bit_mask`                | `1ULL << gpio_num`（可多脚或起来）                               | **位掩码不是脚号**。`gpio_config()` 源码里就是拿它逐位循环（`gpio.c:372-443`），一次调用可配置一批脚                                                                            |
| `mode`                        | 6 个枚举值，实为 3 个 bit 的组合                                 | `INPUT=BIT0`、`OUTPUT=BIT1`、`OD=BIT2`（`gpio_types.h:102-105`）；`GPIO_MODE_INPUT_OUTPUT` 就是 `BIT0\|BIT1`。开漏（`*_OD`）用于总线型线路（I2C、多设备共享 IRQ），配合外部上拉 |
| `pull_up_en` / `pull_down_en` | `GPIO_PULLUP_ENABLE/DISABLE`                                     | 内部弱上/下拉。按键、开漏总线必配；注意 `gpio_config()` 里**非 0 即开**（`gpio.c:402`），别传枚举之外的值                                                                       |
| `intr_type`                   | `GPIO_INTR_DISABLE/POSEDGE/NEGEDGE/ANYEDGE/LOW_LEVEL/HIGH_LEVEL` | 非 0 时 `gpio_config()` 会顺手 `gpio_intr_enable()`（`gpio.c:419-423`）——**配置即挂中断**，handler 还没注册中断就可能到，初始化顺序别写反                                       |

驱动能力是独立 API：`gpio_set_drive_capability()`，四档 `GPIO_DRIVE_CAP_0~3`（weak→strongest），默认 `GPIO_DRIVE_CAP_DEFAULT = 2`（medium）。S3 **没有 input-only 引脚**（`soc_caps.h:189-190`，`SOC_GPIO_VALID_OUTPUT_GPIO_MASK == SOC_GPIO_VALID_GPIO_MASK`），经典 ESP32 上"GPIO34-39 不能输出"的老经验在 S3 上不存在。

### 2. 中断三步走：install 与 add 的分工

```c
gpio_config(&io);                                        // ① 脚：方向/上下拉/触发类型
gpio_install_isr_service(ESP_INTR_FLAG_IRAM);            // ② 服务：全芯片装一次
gpio_isr_handler_add(TOUCH_INT_GPIO, isr_handler, arg);  // ③ 脚级 handler：每脚一次
```

| API                                    | 次数           | 干什么                                                                 | 源码位置     |
| -------------------------------------- | -------------- | ---------------------------------------------------------------------- | ------------ |
| `gpio_install_isr_service(flags)`      | 全芯片**一次** | 注册 GPIO 外设中断的**总服务例程**，申请 per-pin 分发表                | `gpio.c:535` |
| `gpio_isr_handler_add(pin, fn, args)`  | 每脚一次       | 往分发表里填 `{fn, args}`，并把该脚中断绑到服务所在核                  | `gpio.c:562` |
| `gpio_isr_register(fn, ...)`（旧 API） | —              | 不用服务，一个 handler 吃掉**所有** GPIO 中断；与 isr service **互斥** | `gpio.c:618` |

这套分工在 BOX-3 的依赖树里有两个活例子（都实地核对过）：

- `espressif__button/button_gpio.c:83-92`：`gpio_set_intr_type()` → `gpio_install_isr_service(ESP_INTR_FLAG_IRAM)`（进程内 static bool 只装一次）→ `gpio_isr_handler_add()`。GPIO0/1 上的两个实体按键就是这么接进中断的。
- `espressif__esp_lcd_touch/esp_lcd_touch.c:298-327`：装服务后**容忍** `ESP_ERR_INVALID_STATE`（"ISR service can be installed from user before"）——这是第三方组件对"服务可能已被别人装过"的标准防御姿势，值得抄。

### 3. `gpio_dump_io_configuration()`：L1 层的自检武器

`gpio_dump_io_configuration(stdout, 1ULL << 47)` 能把一根脚的实时状态（上下拉、输入输出使能、FuncSel、GPIO Matrix 信号号）全打出来。官方文档给的示例输出中，`FuncSel: 1 (GPIO)`、`GPIO Matrix SigOut ID: 256 (simple GPIO output)` 这两行就是 8.3 节 IO MUX/GPIO Matrix 的直接观测点—— SigOut ID 256（`SIG_GPIO_OUT_IDX`）的含义马上讲。

---

## 8.2 L2 组件源码：esp_driver_gpio 怎么分发中断

### 1. v6 的组件分层：一个勘误

任务书说 HAL 在 `esp_hw_support`，实测 v6.0.2 已把 GPIO HAL 拆成独立组件。当前分层：

```text
components/esp_driver_gpio/   # driver/gpio.c —— 公共 API、ISR 服务、分发表
components/esp_hal_gpio/      # gpio_hal.c + esp32s3/include/hal/gpio_ll.h（v6 新拆出）
components/soc/esp32s3/       # interrupts.h、gpio_sig_map.h、io_mux_reg.h（芯片常量）
```

### 2. `gpio_install_isr_service()`：一张表 + 一个中断槽

剥掉锁与回滚逻辑（`gpio.c:535-560`），只做两件事：

```c
// ① 分发表：每个脚一项 {fn, args}；IRAM 版本放内部 RAM（cache 关掉也活着）
const uint32_t alloc_caps = (intr_alloc_flags & ESP_INTR_FLAG_IRAM)
                            ? MALLOC_CAP_INTERNAL : MALLOC_CAP_DEFAULT;
gpio_isr_func_t *isr_func = heap_caps_calloc(GPIO_NUM_MAX, sizeof(gpio_isr_func_t), alloc_caps);
// ② 注册总服务例程（失败自动 uninstall 回滚）
gpio_isr_register(gpio_intr_service, NULL, intr_alloc_flags, &gpio_context.gpio_isr_handle);
```

`gpio_isr_register()`（`gpio.c:618-651`）里有两个关键事实：中断源**固定**为 `GPIO_LL_INTR_SOURCE0`，在 S3 上即 `ETS_GPIO_INTR_SOURCE = 16`（`soc/interrupts.h:35`，"interrupt of GPIO, level"）——**全芯片 45 个脚共用一个外设中断源**；SMP 下通过 `esp_ipc_call_blocking()` 把 `esp_intr_alloc()` 钉到**调用者所在核**执行，所以服务装在哪个核，`gpio_intr_service` 就在哪个核跑。

### 3. `gpio_intr_service()`：状态寄存器 + ffs 分发

总服务例程（`gpio.c:511-533`，`IRAM_ATTR`）读两段状态寄存器再逐位分发：

```text
GPIO.pcpu_int   (GPIO0~31 状态)  ──┐
                                   ├─→ gpio_isr_loop(status)：__builtin_ffs 找最低位
GPIO.pcpu_int1  (GPIO32~48 状态) ──┘    → 查分发表 → 调用你的 per-pin handler
```

边沿/电平的清 status 时机不同（`gpio_isr_loop`，`gpio.c:486-509`）：**边沿型在进 handler 前先清**（`isr_clr_on_entry_mask` 在 `gpio_set_intr_type()` 时登记，`gpio.c:169-173`），**电平型在 handler 返回后清**。这解释了一个经典现象：电平触发中断若 handler 里不消掉电平条件（比如不读走触摸控制器的数据），status 清了马上再置位，中断会风暴式重入。

### 4. `ESP_INTR_FLAG_*`：中断分配 flag 速查

`gpio_install_isr_service()` 的 flags 原样传给 `esp_intr_alloc()`（`esp_intr_alloc.h:33-49`）：

| flag                           | 含义                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------ |
| `ESP_INTR_FLAG_LEVEL1~3`       | 接受 1~3 级（低/中优先级，C 可写）；`LOWMED` 是三者或                                |
| `ESP_INTR_FLAG_LEVEL4~7 / NMI` | 高优先级，需要汇编入口，应用层别碰                                                   |
| `ESP_INTR_FLAG_EDGE`           | 边沿触发的 CPU 中断线                                                                |
| `ESP_INTR_FLAG_SHARED`         | 多个源共享一个中断槽（**只能配电平触发**，官方文档解释：边沿共享会在清锁存时丢中断） |
| `ESP_INTR_FLAG_IRAM`           | ISR 及其调用的一切进 IRAM——flash 擦写期间（cache 禁用）仍能触发                      |
| `ESP_INTR_FLAG_INTRDISABLED`   | 分配完先保持关                                                                       |

日常二选一：`0`（省心）或 `ESP_INTR_FLAG_IRAM`（实时性/低功耗产品必选，BOX-3 的按键组件用的就是后者）。选 IRAM 就要守纪律：**per-pin handler 必须加 `IRAM_ATTR`，且它调到的每个函数也得在 IRAM**。

### 5. ISR 到任务：FromISR 纪律与本系列标准姿势

ISR 上下文没有任务世界的东西：不能 `printf`、不能 `malloc`、不能 `ESP_LOGx`、不能拿互斥量、FreeRTOS 函数**只认 `...FromISR` 后缀**。常用清单就五个：

```c
xTaskNotifyFromISR()      // 发通知（带值与动作）
vTaskNotifyGiveFromISR()  // 发通知（计数 +1，最轻）
ulTaskNotifyTake()        // 任务侧收（不在 ISR 里用）
xQueueSendFromISR() / xSemaphoreGiveFromISR()
portYIELD_FROM_ISR()      // 退出前按需切上下文
```

`FromISR` 族多出的 `pxHigherPriorityTaskWoken` 协议、退出前 `portYIELD_FROM_ISR()` 的延迟 yield 设计，在 [[ch13-task-notifications|FreeRTOS（十三）任务通知]] 13.4 节已拆到源码级，此处不重复。结论直接拿来用：

> [!tip] 本系列标准姿势：中断 → 任务通知 → 任务里处理
> ISR 里只做"取证据 + 发通知"（读电平、计个数、`vTaskNotifyGiveFromISR()`），解析、打印、I2C 读取全部放到被唤醒的任务里。开销最小（通知直接写目标 TCB，见 ch13 的开销账单），也天然满足 ISR-safe。

另一个常被忽略的物理约束：per-pin handler 跑在**中断栈**上，深度 `CONFIG_FREERTOS_ISR_STACKSIZE` 默认仅 1536 字节（`components/freertos/Kconfig:426-431`），而且 `gpio_isr_handler_add()` 的文档注释明说这层比全局 handler 更容易爆栈——别在 ISR 里定义大数组。

---

## 8.3 L3 芯片层：IO MUX、GPIO Matrix 与 strap 引脚

### 1. S3 引脚地图（写代码前先看地形）

`docs/zh_CN/api-reference/peripherals/gpio/esp32s3.inc` + `soc_caps.h:178-200` 汇总：

| 引脚段    | 状态                                                                           |
| --------- | ------------------------------------------------------------------------------ |
| GPIO0~21  | 可自由使用；0/3 是 strap 脚；19/20 默认 USB-Serial-JTAG                        |
| GPIO22~25 | **不存在**（编号空洞）                                                         |
| GPIO26~32 | SPI0/1 专供 flash，禁碰                                                        |
| GPIO33~37 | 八线 PSRAM 的 DQ4~7/DQS——**BOX-3 是 N16R8V（Octal PSRAM），这 5 根同样不可用** |
| GPIO38~48 | 可自由使用；45/46 是 strap 脚；47 = 背光、48 = 屏 RST                          |

S3 上每一根脚都能输入也能输出（无 input-only），中断支持全覆盖。

### 2. IO MUX vs GPIO Matrix：信号进出的两条路

一根脚从寄存器视角有两条通到外设（TRM《IO MUX 和 GPIO 矩阵》章节，概念级）：

```text
路 A（IO MUX 直连）：外设 ──固定功能号──→ IO_MUX 寄存器的 MCU_SEL 字段 → 脚
    快（少一跳）、信号完整性好，但脚位基本固定
路 B（GPIO Matrix 任意路由）：外设信号 ID ←→ 256 个可编程交换节点 ←→ 任意脚
    慢一跳，但"任意外设信号到任意引脚"——S3 的招牌能力
```

源码锚点：`PIN_FUNC_GPIO = 1`（`io_mux_reg.h:140`）——`gpio_config()` 末尾把 `MCU_SEL` 设成 1 就是宣布"这脚归 GPIO 外设管"；信号号全表在 `soc/gpio_sig_map.h`（`SOC` 生成，四百多个 `*_IDX` 宏）；`SIG_GPIO_OUT_IDX = 256`（`gpio_sig_map.h:449`）是哨兵值，表示输出侧**没接任何外设信号**——`gpio_dump_io_configuration()` 里那句 `(simple GPIO output)` 就是它。

对照 BOX-3 实况：BSP 用 LEDC 给背光调光时（`esp-box-3.c:293-317`，LEDC timer1 / 10-bit / **5 kHz** / LOW_SPEED），GPIO47 走的是路 B——LEDC PWM 信号经 GPIO Matrix 路由到 47 脚；你若直接 `gpio_config()` 配 47 为普通输出，则把 MCU_SEL 拉回路 A 的 GPIO 功能，PWM 随即失效。这正是官方文档"双重用途 IO"一节警告的场景：`gpio_config()` 会**覆盖全部当前配置**，混合使用时先 `gpio_config()` 再调外设驱动（或只 `gpio_input_enable()` 这类单点 API）。

### 3. strap 引脚：启动那一刻被采样的脚

`esp32s3.inc` 明确：**GPIO0、GPIO3、GPIO45、GPIO46** 是 strapping 管脚，复位瞬间电平被芯片采样，决定 boot 模式、JTAG 源、VDD_SPI 电压、ROM 日志输出等。BOX-3 的硬件设计恰好把三样东西压在 strap 脚上（BSP 源码反查，见 8.5）：

| strap 脚 | BOX-3 上的角色                 | BSP 宏                 | 风险                                                                                |
| -------- | ------------------------------ | ---------------------- | ----------------------------------------------------------------------------------- |
| GPIO0    | BOOT/Config 实体按键，按下接地 | `BSP_BUTTON_CONFIG_IO` | 复位瞬间按住 → 进 download 模式（这也是烧录原理，第五章）                           |
| GPIO3    | **触摸控制器 INT 线**          | `BSP_LCD_TOUCH_INT`    | 复位瞬间若触摸芯片恰好拉低 GPIO3，会改变 JTAG 源选择——正常上电时 INT 空闲电平应为高 |
| GPIO46   | 功放使能                       | `BSP_POWER_AMP_IO`     | GPIO46 参与 VDD_SPI 电压判定，外接电路不许强行拉它                                  |

结论：strap 脚可以正常当中断/IO 用（触摸 INT 就是），但**别外接会把它拉离默认电平的电路**，否则现象是"程序没问题、板子起不来"——最迷惑人的一类翻车。

### 4. 中断汇聚链路与一个流传甚广的误解

```text
per-pin: GPIO.pin[n].int_ena (bit0=CPU中断使能, bit1=NMI)
   ↓ 45 个脚按触发条件置位
GPIO 外设状态寄存器 pcpu_int / pcpu_int1（两核共享，gpio_struct.h:112）
   ↓ 汇成单一外设中断源
ETS_GPIO_INTR_SOURCE (=16) → 中断矩阵 → 某个 CPU 的某级中断线 → gpio_intr_service
   ↓ 软件分发表
你的 per-pin handler
```

S3 与经典 ESP32 的一处差异藏在 `gpio_ll.h:29-31`：注释写明 "On ESP32S3, pro cpu and app cpu **shares the same interrupt enable bit**"（`GPIO_LL_INTR_ENA = BIT(0)`），而经典 ESP32 是每核一个使能位——所以 S3 上不存在"同一脚中断同时投递两核"的玩法，投递目标由中断分配器决定。

顺手辟一个谣：**"GPIO 中断有 40 多个引脚的上限"并不存在**。45 个脚可以**同时**开中断——因为它们共享一个中断源、靠状态位图软件分发，全程只占一个 CPU 中断槽（对比：每装一个独立外设驱动才多占一个槽，S3 每核也就 32 条线）。真正的约束是分发**串行**：任何一个脚的 handler 执行太久，所有其他脚的中断都得排队——这比"上限"更值得敬畏。

---

## 8.4 L4 物理信号：背光波形与抖动

> [!warning] 待真机验证
> 本节全部为**预期行为的定性描述**。逻辑分析仪（系列装备约定里的 8 通道 24MHz 廉价款 + PulseView）到手后补实测截图与数值，届时与本节逐条对账。

- **裸 GPIO 翻转**：8.5 实验 1 里 1 Hz 闪烁（`vTaskDelay(500ms)` 翻转一次），分析仪上应是周期约 1 s、占空比 50% 的方波；两次边沿的间距抖动来自 tick 调度（毫秒级），边沿本身由寄存器写产生，过渡沿极陡。
- **LEDC 调光对照**：恢复 BSP 的 PWM 配置后，47 脚上是 5 kHz、10-bit 分辨率的 PWM：亮度 100% 时近似常高，50% 时是 5 kHz 方波，肉眼不可见闪烁（背光 PWM 频率远高于人眼融合频率，这正是选 5 kHz 的原因）。
- **机械按键抖动（GPIO0 BOOT 键）**：按下/释放瞬间预计产生数个相隔毫秒级的窄脉冲；`espressif/button` 组件靠时间窗去抖（软件法），S3 还有一个每脚独立的硬件**管脚毛刺过滤器**（`gpio_new_pin_glitch_filter()`，剔除窄于 2 个采样时钟的脉冲，宽度不可配；S3 **没有** flex 毛刺过滤器，那是 C 系/P4 的配置）。
- **触摸 INT**：触摸控制器输出的数字脉冲，无机械抖动，但一次按下/滑动可能连发多个 INT 脉冲（数据就绪通知），边沿干净。极性以真机为准（BSP 按低有效配置，见 8.5 步骤 3 的说明）。

接线备注：GPIO3/47 焊在主板上，DOCK 排针是否引出这两根以丝印为准（待核对）；若未引出，可把实验 1 的翻转脚换到某根 PMOD 空闲脚（如 `BSP_PMOD1_IO5` = GPIO21）做波形观测，代码零改动。

---

## 8.5 实验：从 BSP 反查背光引脚 → 点灯 → 触摸中断计数

### 1. 步骤零：引脚事实从哪来——BSP 源码反查

板卡引脚不查手册查源码（第十四章会展开 BSP 分层）。BOX-3 的引脚定义在 factory_demo 的托管组件里（第四章讲过 `managed_components/` 的来历）：

```bash
cd ~/esp/esp-box/examples/factory_demo
grep -n "BSP_LCD_BACKLIGHT\|BSP_LCD_TOUCH_INT\|BSP_I2C_S" \
     managed_components/espressif__esp-box-3/include/bsp/esp-box-3.h
```

真实定义（`include/bsp/esp-box-3.h` 实地摘录，行号为该文件行号）：

```c
#define BSP_I2C_SCL           (GPIO_NUM_18)   // :47
#define BSP_I2C_SDA           (GPIO_NUM_8)    // :48
#define BSP_LCD_BACKLIGHT     (GPIO_NUM_47)   // :66
#define BSP_LCD_TOUCH_INT     (GPIO_NUM_3)    // :67
#define BSP_BUTTON_CONFIG_IO  (GPIO_NUM_0)    // :74
#define BSP_POWER_AMP_IO      (GPIO_NUM_46)   // :56
#define BSP_I2C_NUM           CONFIG_BSP_I2C_NUM  // :228；Kconfig 默认 1，范围 0~1
```

同目录 `esp-box-3.c:293-317` 给出背光的官方用法：LEDC timer1、10-bit、5 kHz、LOW_SPEED 通道（编号 `CONFIG_BSP_DISPLAY_BRIGHTNESS_LEDC_CH` 默认 1），`bsp_display_brightness_set()` 把百分比换算成 duty（100% = 1023）。LEDC 细节留给 [[ch13-timers-watchdogs|第十三章]]。

> [!note] 触摸型号待核对
> 系列索引记载触摸为 FT6336（I2C+INT）；但本仓库 BSP（`espressif/esp-box-3` v1.1.3）的 `bsp_touch_new()` 只探测 GT911（0x5D/0x14）与 TT21100（0x24）两种地址，未含 FT6336（0x38）。孰准孰误，第九章 I2C 总线扫描一锤定音（待核对）。这不影响本章：INT 脚 `GPIO3` 的宏与配置路径是确定的。顺带一课：该头文件 334 行注释还写着"ST7789"，与屏幕实况（ILI9342C）不符——**注释会撒谎，宏定义和探测代码不会**。

另有一处值得看的源码：BSP 的雷达底板代码（`components/bsp/src/boards/esp32_bsp_sensor.c:86-91`）给 GPIO21 配了 `GPIO_INTR_POSEDGE` 却从未 `gpio_install_isr_service()`，实际靠任务里 1 Hz 轮询 `gpio_get_level()` 干活——`intr_type` 设了但中断链路没接通，该字段形同虚设。读 BSP 源码时别把"配了触发类型"当成"用了中断"。

### 2. 实验 1：背光裸 GPIO 点灯（1 Hz 闪烁）

```c
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "bsp/esp-box-3.h"          // 或自行 #define BL_GPIO GPIO_NUM_47

void app_main(void)
{
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << BSP_LCD_BACKLIGHT,   // 位掩码，别写成脚号
        .mode = GPIO_MODE_OUTPUT,                    // 输出推挽
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io));

    while (1) {
        gpio_set_level(BSP_LCD_BACKLIGHT, 1);        // 亮（BSP 电路高电平点亮，待真机验证）
        vTaskDelay(pdMS_TO_TICKS(500));
        gpio_set_level(BSP_LCD_BACKLIGHT, 0);        // 灭
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}
```

现象预期：屏幕背光以 1 Hz 闪烁（LCD 本身未初始化，面板无内容，只有背光明灭——屏幕点亮是 [[ch10-spi-display|第十章]] 的事）。跑完可在循环外加一句 `gpio_dump_io_configuration(stdout, 1ULL << BSP_LCD_BACKLIGHT);` 对照：应看到 `FuncSel: 1 (GPIO)`、`SigOut ID: 256 (simple GPIO output)`。CMake 依赖加 `PRIV_REQUIRES esp_driver_gpio`（新工程模板默认可用）。

### 3. 实验 2：触摸 INT 中断 → 计数 → 任务通知转发

标准姿势的完整骨架（待真机验证）：

```c
#include <stdatomic.h>
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#define TOUCH_INT_GPIO   3      // = BSP_LCD_TOUCH_INT，strap 脚（8.3 节第 3 小节）
/* 极性说明：BSP 按低有效配置（levels.interrupt=0 → 驱动映射为 NEGEDGE）。
 * 本实验先按上升沿配（题目要求），跑起来若计数与触摸相反，改本宏为
 * GPIO_INTR_NEGEDGE 再验——最终以逻辑分析仪波形为准。 */
#define TOUCH_INTR_TYPE  GPIO_INTR_POSEDGE

static TaskHandle_t s_touch_task;
static _Atomic uint32_t s_intr_count;   // 单写者（ISR），原子读改写

static void IRAM_ATTR touch_isr_handler(void *arg)
{
    atomic_fetch_add(&s_intr_count, 1);            // 取证据：计数
    BaseType_t woken = pdFALSE;
    vTaskNotifyGiveFromISR(s_touch_task, &woken);  // 发通知：叫醒任务
    portYIELD_FROM_ISR(woken);                     // 高优先级任务醒了立刻切
}

static void touch_worker_task(void *arg)
{
    uint32_t last = 0;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);   // 等通知（pdTRUE = 收到即清零）
        uint32_t now = atomic_load(&s_intr_count);
        ESP_LOGI("touch", "INT count: %lu (+%lu)",   // 打印只在任务里做
                 (unsigned long)now, (unsigned long)(now - last));
        last = now;
        /* 进阶：这里发起 I2C 读坐标——第九章的内容 */
    }
}

void app_main(void)
{
    xTaskCreate(touch_worker_task, "touch", 4096, NULL, 5, &s_touch_task);

    gpio_config_t io = {
        .pin_bit_mask = 1ULL << TOUCH_INT_GPIO,
        .mode = GPIO_MODE_INPUT,          // 中断脚只需输入
        .pull_up_en = GPIO_PULLUP_ENABLE, // INT 空闲高：上拉锁定默认电平
        .intr_type = TOUCH_INTR_TYPE,
    };
    ESP_ERROR_CHECK(gpio_config(&io));
    ESP_ERROR_CHECK(gpio_install_isr_service(ESP_INTR_FLAG_IRAM));  // 全芯片一次
    ESP_ERROR_CHECK(gpio_isr_handler_add(TOUCH_INT_GPIO, touch_isr_handler, NULL));
}
```

预期现象（待真机验证）：每次触摸屏幕，日志打出一行计数递增；一次长按可能连打多行（控制器连发数据就绪脉冲，见 8.4）。同屏跑 factory_demo 时注意 BSP 已占用 I2C 总线（I2C1，SCL=18/SDA=8，第九章），但本章实验不碰 I2C、不与触摸驱动抢 INT 脚的 handler——若两者同烧，后注册者生效（分发表单槽），留作思考题。

---

## 8.6 翻车点表与小结

| 症状                                        | 根因                                                                        | 处理                                                                                     |
| ------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| ISR 里 `printf`/`ESP_LOGx`，偶发死机/乱码   | 中断上下文无任务运行时；日志走 UART+锁                                      | 只用 FromISR + 通知转发（8.2 节第 5 小节）；ISR 内调试用翻转一根 GPIO 配逻辑分析仪       |
| `gpio_isr_handler_add` 返回 invalid state   | 没先 `gpio_install_isr_service()`（`gpio.c:564` 明确检查）                  | 按三步走补第一步；写库时学 `esp_lcd_touch.c` 容忍 `ESP_ERR_INVALID_STATE`                |
| flash 擦写（NVS 写/WiFi 校准）时崩溃在 ISR  | 服务以 `ESP_INTR_FLAG_IRAM` 安装，但 handler 或其调用没进 IRAM              | handler 加 `IRAM_ATTR`，调到的函数全部 IRAM 化；或干脆不装 IRAM 版服务（接受擦写期延迟） |
| "程序没问题，板子起不来/进错启动模式"       | strap 脚（GPIO0/3/45/46）被外设或外部电路在复位瞬间拉偏（8.3 节）           | 核对外设 idle 电平；GPIO3 依赖触摸 INT 空闲为高                                          |
| 电平触发中断风暴/看似卡死                   | level 型 status 在 handler 返回后才清，条件未消除即重入（8.2 节第 3 小节）  | handler 内消除电平条件（读走数据/关该脚中断），或改边沿触发                              |
| 中断时灵时不灵、与任务所在核有关            | 服务装在哪个核就全在哪个核跑（`esp_ipc_call_blocking` + `gpio.c:572` 绑核） | 想跑核 1 就在钉在核 1 的任务里装服务                                                     |
| 配了 LEDC 背光又被 `gpio_config()` 打回原形 | `gpio_config()` 覆盖全部当前配置（官方文档"双重用途 IO"警告）               | 先 `gpio_config()` 再调外设驱动；或只 `gpio_input_enable()` 单点修改                     |
| 担心"GPIO 中断 40+ 脚上限"                  | 谣言——单一中断源 + 软件分发，45 脚全开也只占一个 CPU 中断槽                 | 真正的约束是 handler 串行执行，单个 ISR 必须短                                           |
| ISR 里定义大数组后栈溢出                    | 中断栈 `CONFIG_FREERTOS_ISR_STACKSIZE` 默认仅 1536 字节                     | ISR 零大局部变量；重活全部搬任务                                                         |

本章小结：

- **L1**：`gpio_config_t` 五字段一次配齐（掩码、方向位组合、上下拉、触发类型；驱动能力走独立 API）；中断三步走——`gpio_config` → `gpio_install_isr_service`（一次）→ `gpio_isr_handler_add`（每脚），与旧 `gpio_isr_register` 互斥；`gpio_dump_io_configuration()` 是引脚问题的第一诊断命令。
- **L2**：全芯片 45 脚共享一个外设中断源（`ETS_GPIO_INTR_SOURCE`=16），总服务读 `pcpu_int/pcpu_int1` 两位图、ffs 逐位查分发表调用你的 handler；边沿先清 status 电平后清；服务与安装它的任务同核。v6 里 GPIO HAL 已从 esp_hw_support 拆到 `esp_hal_gpio` 组件。
- **L3**：S3 无 input-only 脚、GPIO22~25 不存在、33~37 被 Octal PSRAM 占死（N16R8V）；外设信号走 IO MUX 直连或 GPIO Matrix 任意路由（`PIN_FUNC_GPIO=1`、`SIG_GPIO_OUT_IDX=256`）；strap 脚 GPIO0/3/45/46 上 BOX-3 恰好压着 BOOT 键、触摸 INT 与功放使能。
- **L4**：裸翻转是干净方波，LEDC 是 5 kHz PWM，机械按键有毫秒级抖动（软件时间窗/S3 硬件管脚毛刺过滤器），触摸 INT 是控制器数字脉冲——全部待真机验证。
- **实验**：背光 GPIO47 点灯 + 触摸 INT(GPIO3) 中断计数经 `vTaskNotifyGiveFromISR()` 转发任务处理——「中断 → 任务通知 → 任务」自此成为本系列固定套路，后续 RMT、I2S 章节反复复用。

下一章顺着触摸 INT 背后的那根 I2C 总线走下去：协议波形 → new 驱动 API → SCL=18/SDA=8 总线上的 FT6336（或 GT911？）与 AHT20，并把本章留下的触摸型号疑问用总线扫描了结。
