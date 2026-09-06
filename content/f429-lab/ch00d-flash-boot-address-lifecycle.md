---
title: 从 make flash 到第一个 tick：烧录、启动与地址的一生（含实测）
date: 2026-08-30 08:00:00
description: 烧录的本质是幽灵程序操作 Flash 控制器；地址的一生在链接时定死（bl 绝对地址实测）；代码永远在 flash 就地执行（XIP），RAM 里只有栈堆变量；微型 loader 就住在 Reset_Handler 里；OTA 双分区=单片机版蓝绿部署
tags: [f429-lab, STM32, Flash, Boot]
---

# 从 make flash 到第一个 tick：烧录、启动与地址的一生（含实测）

> **状态声明**：本文整理自 2026-08-30 的追问实录（ch00a/b/c 之后继续下钻烧录与
> 地址体系）。标注「实测」的输出（bl 绝对地址、nm 两世界、objdump -h 双地址、
> LoopCopyDataInit 符号、reset halt 的 pc/msp 抓拍）全部来自本机真跑。

## 本章装备清单

| 分类 | 装备              | 价格/状态 | 用途                         |
| ---- | ----------------- | --------- | ---------------------------- |
| 已有 | 挑战者 F429-V2 板 | ✅        | 实验主体                     |
| 已有 | 野火 DAP + 排线   | ✅        | 烧录与验证通道               |
| 已有 | 笔记本 + 工具链   | ✅        | make/nm/objdump 全套考古工具 |

## 本章会遇到的词

| 词          | 一句话版                                       | 详见    |
| ----------- | ---------------------------------------------- | ------- |
| 幽灵程序    | openocd 经调试口操作 Flash 控制器的无形之手    | 第 1 节 |
| 座位表      | 链接脚本给每段代码排的地址（VMA/LMA）          | 第 2 节 |
| XIP         | 就地执行：指令一辈子住在 flash，不搬 RAM       | 第 4 节 |
| 微型 loader | Reset_Handler 里的搬运循环（LoopCopyDataInit） | 第 5 节 |
| 重定位      | 地址签发——发生在链接期，不在运行期             | 第 6 节 |
| 双分区      | OTA 的 A/B 布局=单片机版蓝绿部署               | 第 9 节 |

## 1. 烧录的本质：幽灵程序操作 Flash 控制器

烧录不需要 CPU 跑任何代码——只需要能**操作 Flash 控制器**这个外设，而调试口恰好
能读写总线上的一切。Flash 是个"寄存器收命令"的外设（KEYR 解锁 / CR 命令 / SR
状态；本体在 0x08000000 起），openocd 通过 SWD/JTAG 的 MEM-AP 直接写这些寄存器，
扮演一个**不存在于芯片里的幽灵程序**：

| 步骤 | 幽灵在总线上干的事        | 等价于软件执行   |
| ---- | ------------------------- | ---------------- |
| 1    | 先 halt 住 CPU            | （按住唯一用户） |
| 2    | KEYR 喂两把钥匙解锁       | 开工手续         |
| 3    | CR 写"擦第 N 扇区，开始"  | 扇区擦除         |
| 4    | 看 SR 的 BSY 位等忙完     | 轮询             |
| 5    | 置 PG，往 0x0800xxxx 写数 | 编程落盘         |
| 6    | 置 LOCK 上锁              | 收工             |

日志里的 `Programming Started/Finished` 就是这套幽灵操作；`Verified OK` = 幽灵
再读回来逐字节比对。系统侧类比：**IPMI 带外命令远端 RAID 卡重建阵列——不经过
"主机"（CPU），直接对"控制器"发指令**。这也是调试链路失效夜"CPU 死了烧录照样成功"的
原理：只需要芯片上电、调试口和 Flash 控制器活着。

**并发三道闸**（"万一别人在用"）：CPU 在取指→openocd 先 halt（`make flash` 里
program 前那步复位停机就是它）；DMA 在搬→擦写期间控制器把读访问**冻结排队**
（stall，不是读到垃圾——ST 内建的安全设计，忘 halt 也不至于跑飞）；另一个
调试器→USB 层互斥根本进不来（故障表里的"DAP 被占用"）。

## 2. 烧到哪：地址三棒接力

```text
第 1 棒：ST 定的内存地图     Flash 永远从 0x08000000 起（复位硬件要求向量表住这）
第 2 棒：链接脚本排座位      .text/.rodata 从 0x08000000 排起（STM32F429IG.ld）
第 3 棒：ELF 带地址表        objdump -h 的 VMA/LMA 列；openocd 照单搬运
```

多个 flash 怎么路由（内置/OTP/QSPI）？**地址落在谁家就路由到谁**——像 IP 按网段
路由。`.bin` 和 `.elf` 的区别也在这：bin 是剥掉地址表的裸数据（烧时人肉指定起
点），elf 自带座位表——所以 `make flash` 用 elf。

## 3. 生命周期四步与复位后硬件的两件事

```text
make flash = ① 停机(reset halt) → ② 搬运(解锁/擦/写) → ③ 验收(verify) → ④ 发令枪(reset)
```

发令枪响后的**硬件自动动作**（无任何软件参与）：

```text
从 0x08000000 读一个词 → 装 SP（栈指针）   实测抓拍：msp = 0x20030000（_estack）
从 0x08000004 读一个词 → 装 PC              实测抓拍：pc  = 0x08001b2c（Reset_Handler）
→ Reset_Handler 干三件搬家活：拷 .data 到 RAM、清零 .bss、跳 SystemInit → main
```

时钟配置故障复盘 `reset halt` 输出的那行 `pc/msp`，就是**发令枪刚响、运动员没迈步**的
现场自拍——当时看它是故障恢复证据，现在看它是启动机制的纪录片。

## 4. XIP：指令永远住在 flash，RAM 里只有草稿纸

默认情况下代码**从不搬进 RAM**——CPU 取指地址 0x0800xxxx 直接命中 flash，这个
模式叫 **XIP（eXecute In Place，就地执行）**。与 PC 的根本差异：

|          | PC                 | MCU              |
| -------- | ------------------ | ---------------- |
| 代码存放 | 硬盘               | flash            |
| 执行前   | OS 把 exe 装进 RAM | 不装，直接执行   |
| 类比     | 书复印到桌上再读   | 站在书架前直接读 |

**实测两世界**（nm 一目了然）：

```text
指令（全在 flash）：                数据（全在 RAM）：
fast_task = 0x080019cc              SystemCoreClock = 0x20000004（.data 带初值）
main      = 0x08001b08              ucHeap          = 0x2000010c（heap_4 的 64KB）
vTaskDelay= 0x080004bc              xTickCount      = 0x200000e4（.bss 清零区）
```

RAM 的三类居民：**栈**（函数现场，从 0x20030000 向下长）、**堆**、**全局变量**。
根子在存储器身份：硬盘是块设备（要驱动+OS 才能取内容），flash 是总线上的存储器
（按地址直读，只慢 5 个等待周期）——"装载"这个概念在 MCU 上不存在。

进阶：什么时候真的把代码搬 RAM？①提速（flash 有 5WS，RAM 零等待，烫函数标
`.ramfunc`）；②自升级（bootloader 边擦 flash 边跑，得先搬进 RAM）；③这两类
RAM 函数的理想住址=**CCM 那 64KB**（ch05 埋的伏笔）。

## 5. 微型 loader 一直都在：Reset_Handler 的搬运循环

"load 到内存"这件事，板上**从第一天就在发生**——只是搬的是数据不是指令：

```text
实测：nm 里有 08001b88 t LoopCopyDataInit / 08001b9a t LoopFillZerobss
实测：objdump -h 里 .data  VMA=20000000  LMA=08001df8   ← 两个地址！
```

`.data` 天生双地址：初值存 flash（LMA）、变量的家在 RAM（VMA）。开机时
Reset_Handler 的 LoopCopyDataInit 把它从 LMA 搬到 VMA、LoopFillZerobss 给 .bss
清零——**这就是一个微型 loader**（ARM 术语 scatter-loading）。想给 ramfunc 用，
只是给链接脚本多加一个"双地址段"，同一个搬运循环顺手就装了。

## 6. 地址的一生：链接时定死，运行时零修正

"load 后函数地址怎么变？"——**不变，从链接那一刻起就是终局**：

```text
实测：objdump -d 的调用点
 8001b0e:  bl 8001a24 <clock_init>     ← 绝对地址直接嵌在指令里，链接器写死
```

重定位（地址签发）存在，但发生在**编译机的链接期**，不在目标机的运行期。PC 需要
运行时 loader 修地址（PLT/GOT/ASLR），因为多程序共享 RAM、地址冲突、安全随机化；
MCU 整个世界只有一个程序、flash 独占——**冲突在链接时被城市规划（链接脚本）提前
消化了**。等价于一个"所有程序都 `-static -no-pie` 链到固定地址"的世界。

三条边界规则：①搬运≠重定位（loader 只搬字节，地址早定）；②**外设寄存器地址不
参与重定位**（0x40023800 的 RCC 是硬件门牌，代码搬到哪它都在原处）；③改基址=
改链接脚本**回炉重新链接**，重签所有产权证（bootloader 自搬 RAM 跑就是这么干的）。

## 7. PC 的一生与 RTOS 的"换 PC"

PC（程序计数器）的全部运动方式只有四种：①顺序执行自动 +2/+4；②跳转指令改写
（if/for 的底层）；③调用与返回靠栈存取（BL 存 LR；`POP {PC}` 从栈弹回）；④
异常进/出靠硬件栈帧。后两种的共同点——**PC 可以存进栈再恢复**——正是 RTOS 换
任务的钥匙：每个任务的栈里躺着它被捕时的 PC，PendSV 把旧的压好、把新的弹回，
**没有谁显式"设置"PC，它是现场恢复的一部分**（ch17 单步课的预告）。

顺带：RTOS 为什么没有 PC 式的 loader？**任务不是独立程序，是同一镜像里的 C 函数**
——`xTaskCreate(fast_task,…)` 传的是函数指针（0x080019cc 早躺在 flash 里等着
被指）。没有文件系统就没有运行时装载这回事；`vTaskDelay` 是普通函数调用不是
syscall；FreeRTOS 是被链接进来的库，不是先启动再装别人的内核。

## 8. 附：openocd.cfg 逐行考古

配置=一张写给 openocd 的便条（本质是 Tcl 脚本，`source [find …]` 从
/usr/share/openocd/scripts/ 调库文件）：

| 行                                   | 人话                                                                                                                         | 效果（对应日志）                            |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| `source interface/cmsis-dap.cfg`     | "翻译器是 CMSIS-DAP"                                                                                                         | `Interface Initialised`                     |
| `transport select jtag`              | "用 JTAG 敲门"（可省，默认即是）                                                                                             | 模式行                                      |
| `source target/stm32f4x.cfg`         | "客户是 ST F4"——**信息量最大**：声明两个 TAP 及期望 ID（probe 认亲的户口本）、创建 cortex_m 目标对象、注册 stm32f2x 烧录后端 | `tap/device found` 两行                     |
| `adapter speed 2000`                 | 敲门节拍 2MHz                                                                                                                | （target 文件里默认已是 2000，此行=保险带） |
| `reset_config … connect_assert_srst` | "连接先按住复位"——故障恢复姿势                                                                                               | `Connecting under reset`                    |

配置层与协议层的分工：JTAG 状态机/IDCODE 是精密标准（科学），speed 取值/复位
策略是社区调试化石（考古）——**一行配置=一次被冻结的排障经历**。自己调配置的
纪律：一次只动一个变量。

## 9. 彩蛋：OTA 双分区=单片机版蓝绿部署

A/B 双分区的本质=**蓝绿部署**：蓝组（A 分区）跑业务，绿组（B 分区）部署新版，
验证后切指针（otadata），出问题秒回蓝组——Android 无缝更新、树莓派 A/B rootfs
同款。代价是 **app 空间翻倍**（"要不要 OTA"直接决定 flash 选型）。空间不够的
省法谱系：差分升级（B 只存差异包）、压缩镜像、**外挂 flash（我们板上 8MB
W25Q64 正好干这个，ch07 伏笔回收）**、单分区+救援 bootloader。F429 的 2MB 对
7KB 固件宽裕到奢侈——实验期可加一节"手写最小 A/B bootloader"（读 otadata 决定
跳 A 还是 B），素材现成。

## 待核对清单

- [ ] `.ramfunc` 最小实验：一个烫函数搬 CCM 跑，对比执行耗时（呼应 ch05/ch13）
- [ ] LoopCopyDataInit 断点单步：亲眼看 .data 搬家八次拷贝（elf 才 8 字节 .data）
- [ ] 手写最小 A/B bootloader（实验期选修，依赖 ch01+ 基础）
- [ ] OTA 差分包的最小可行实验（远期，可先在 F429 上模拟双分区跳转）

## 相关阅读

- [[ch00c-debug-stack-panorama|ch00c：调试体系全景]]——本文的姊妹篇：幽灵通道的完整架构
- [[ch05-bus-matrix-ccm|ch05：总线矩阵]]——座位表（链接脚本）与 CCM 的详解
- [[2026-08-30-stm32f429-clock-misconfig-postmortem|故障复盘]]——`pc/msp` 抓拍的原始现场
- [[f429-lab|F429 裸机实验室索引]]
