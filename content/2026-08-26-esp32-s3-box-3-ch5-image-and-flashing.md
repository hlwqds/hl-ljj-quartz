---
title: "ESP32-S3-BOX-3 工程实战（五）：编译产物与烧录链路"
date: 2026-08-26 12:00:00
description: "逐文件解剖 build 目录（elf/bin/map/flasher_args.json），用 hello-s3 真实构建产物画出 0x0/0x8000/0x10000 三镜像 Flash 布局，追进 idf.py flash 背后的 esptool 命令组装与 ROM 下载模式，最后给出连板烧录、出厂固件全量备份的完整实操清单。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（五）：编译产物与烧录链路

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 上一章：[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章：工程解剖与组件体系]]
> **第五章：编译产物与烧录链路**（当前章）
> 下一章：[[2026-08-26-esp32-s3-box-3-ch6-boot-to-app-main|第六章：从上电到 app_main]]

第四章结束时留了一个地址没兑现：partitions.csv 编译后变成的分区表 BIN，烧在 Flash **0x8000** 处。本章把整条链走完——`idf.py build` 吐出的 build 目录里每个文件是什么、谁消费它；三镜像在 Flash 上怎么排布；`idf.py flash` 敲下去之后 esptool 实际执行了什么。所有数字与命令均来自本机真实构建产物（工程 `~/esp/hello-s3`，IDF v6.0.2，目标 esp32s3，构建成功），非凭记忆转述；涉及连板的实操段标注待真机验证。

---

## 5.1 build 目录全景：每个产物是谁、谁消费它

构建成功后，`build/` 里与"烧录"直接相关的产物（实地核对）：

| 产物                                  | 是什么                                                     | 谁消费它                                           |
| ------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------- |
| `hello-s3.elf`                        | 链接器最终输出：全部代码段 + 符号表 + 调试信息             | GDB 调试、`idf.py size`、崩溃时 `addr2line` 回溯   |
| `hello-s3.bin`                        | 由 elf 转出的**可烧镜像**（ESP 镜像格式）                  | esptool `write-flash` 烧进 app 分区                |
| `hello-s3.map`                        | 链接器写的符号地址报告（本机 3.6MB）                       | 人肉排查（5.3 节）                                 |
| `bootloader/bootloader.bin`           | bootloader **独立子工程**的镜像（还有个 `bootloader.elf`） | esptool 烧到 0x0                                   |
| `partition_table/partition-table.bin` | CSV 分区表转成的二进制表                                   | esptool 烧到 0x8000；bootloader 运行时也读它       |
| `flasher_args.json` / `flash_args`    | 烧录参数清单：offset 与文件的对账单                        | `idf.py flash`、esptool `"@flash_args"`、IDE 插件  |
| `app-flash_args` 等三个变体           | 单镜像烧录参数（只烧一个 offset）                          | `idf.py app-flash` 等命令（5.5 节）                |
| `project_description.json`            | 工程元信息（target、IDF 版本、工具链前缀）                 | `idf.py monitor` 取 `monitor_toolprefix`、增量构建 |
| `config/sdkconfig.h`                  | sdkconfig 的 C 宏面孔（`#define CONFIG_xxx`）              | 全部源文件的编译                                   |

（bootloader 为什么是独立子工程、`sdkconfig.h` 怎么从 sdkconfig 生成，分别在 [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow|FreeRTOS（三）]]与[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]]4.5 节讲过，不重复。）

### .elf 与 .bin：一次"给人"一次"给机器"

构建日志的最后几步把两者的关系演示得很清楚（日志原文，编号是 ninja 的任务号）：

```text
[1060/1062] Linking CXX executable hello-s3.elf
[1061/1062] Generating binary image from built executable
esptool v5.3.1
Creating ESP32-S3 image...
Merged 3 ELF sections.
Successfully created ESP32-S3 image.
Generated /home/huanglin/esp/hello-s3/build/hello-s3.bin
```

- **.elf 是给人（和调试器）的**：带符号表、调试段、每字节的虚拟地址。GDB 能下断点、`idf.py size` 能分组件统计体积，全靠它。但 ROM 里没有 ELF loader——芯片不认识这个格式。
- **.bin 是给机器的**：`elf2image` 步骤（由 venv 里的 esptool v5.3.1 执行）把 elf 里的可加载段抽出来，加上 ESP 镜像头（魔数 `0xE9`、段表、入口地址、flash 模式/大小/频率字段）拼成裸字节流。ROM 和 bootloader 只认这个格式。

一句话：**调试用 elf，烧录用 bin**。第六章逐行对账启动日志时，`Loaded app from partition at offset 0x...` 里的那个镜像，就是这里的 `hello-s3.bin`。

### 顺手验证：镜像装得进分区吗

bin 生成后，构建系统立刻跑了一次体积核对（日志原文）：

```text
[1062/1062] cd /home/huanglin/esp/hello-s3/build && .../python
  /home/huanglin/esp/esp-idf/components/partition_table/check_sizes.py
  --offset 0x8000 partition --type app
  /home/huanglin/esp/hello-s3/build/partition_table/partition-table.bin
  /home/huanglin/esp/hello-s3/build/hello-s3.bin
hello-s3.bin binary size 0x28050 bytes. Smallest app partition is 0x100000
bytes. 0xd7fb0 bytes (84%) free.
```

`0x28050`（约 160KB）的 app 镜像对着最小 app 分区 `0x100000`（1MB）核对——**84% free 的分母是分区，不是整片 Flash**，这个误读后面翻车点表还会回来。bootloader 也有一行同款检查：`Bootloader binary size 0x5240 bytes. 0x2dc0 bytes (36%) free.`，它的预算上限是 0x8000（分区表所在处）——bootloader 再胖也不能越过分区表。

---

## 5.2 三镜像与 Flash 布局：0x0 / 0x8000 / 0x10000

### 1. flasher_args.json：构建与烧录之间的合同

`idf.py flash` 从不猜地址——它读 `build/flasher_args.json`。hello-s3 的这份文件全文（实地读取）：

```json
{
  "write_flash_args": ["--flash-mode", "dio", "--flash-size", "2MB", "--flash-freq", "80m"],
  "flash_files": {
    "0x0": "bootloader/bootloader.bin",
    "0x8000": "partition_table/partition-table.bin",
    "0x10000": "hello-s3.bin"
  },
  "extra_esptool_args": {
    "after": "hard-reset",
    "before": "default-reset",
    "stub": true,
    "chip": "esp32s3"
  }
}
```

三个 offset 就是 ESP32 系列的经典三段式（S3 的 bootloader 在 **0x0**，经典 esp32 是 0x1000）。旁边还有个纯文本版 `flash_args`，内容三行，给 esptool 的 `@file` 语法用：

```text
--flash-mode dio --flash-freq 80m --flash-size 2MB
0x0 bootloader/bootloader.bin
0x8000 partition_table/partition-table.bin
0x10000 hello-s3.bin
```

### 2. Flash 布局图（hello-s3 默认配置）

把三镜像与默认分区表（下节拆解）画在一起：

```text
Flash（sdkconfig 声明 2MB = 0x200000）
0x00000 ┌────────────────────────────┐
        │ bootloader.bin (0x5240B)   │ ← ROM 复位后第一个取指的镜像
0x08000 ├────────────────────────────┤ ← 分区表固定位置（可配，默认 0x8000）
        │ partition-table.bin        │   表区 0x1000，数据上限 0xC00
0x09000 ├────────────────────────────┤
        │ nvs        (0x6000)        │ ← offset 列留空，生成器自动排布
0x0f000 │ phy_init   (0x1000)        │
0x10000 ├────────────────────────────┤ ← flasher_args.json 的 app offset
        │ factory    (0x100000 = 1M) │   hello-s3.bin (0x28050B) 烧在这
0x110000├────────────────────────────┤
        │ （默认表未分配，~0.9MB 闲置）│
0x1ffffF└────────────────────────────┘ ← 声明 2MB，此线之上固件才可见
```

nvs/phy_init 的 offset 在 CSV 里留空、由生成器按行序自动排布（0x8000+0x1000=0x9000，再加 0x6000 得 0xf000），而 factory 的落点 0x10000 与 `flasher_args.json` 里 app 的 offset 互相印证——**分区表决定 app 烧哪，flasher_args 只是如实转述**。

### 3. 分区表 BIN 怎么来的：gen_esp32part.py

第四章讲过 partitions.csv 的语义；二进制这头由 `components/partition_table/gen_esp32part.py` 完成，文件头自述："Converts partition tables to/from CSV and binary formats"（CSV 与二进制双向转换）。几个实测拿到的硬约束：

| 常量                   | 值                 | 含义                                                         |
| ---------------------- | ------------------ | ------------------------------------------------------------ |
| `MAX_PARTITION_LENGTH` | `0xC00`            | 分区数据上限：96 项 × 32 字节，留 1KB 给表尾签名区           |
| `PARTITION_TABLE_SIZE` | `0x1000`           | 整张表占一个 4KB 块                                          |
| `MD5_PARTITION_BEGIN`  | `0xEBEB + 14×0xFF` | 表尾 MD5 校验段的魔数（`CONFIG_PARTITION_TABLE_MD5` 默认开） |

hello-s3 用的是**默认单 app 表**——`sdkconfig.h` 里 `CONFIG_PARTITION_TABLE_SINGLE_APP`、`CONFIG_PARTITION_TABLE_FILENAME "partitions_singleapp.csv"`（第 403/405 行）。这份默认表全文只有三行有效内容：

```csv
# Name,   Type, SubType, Offset,  Size, Flags
nvs,      data, nvs,     ,        0x6000,
phy_init, data, phy,     ,        0x1000,
factory,  app,  factory, ,        1M,
```

### 4. 默认表 vs factory_demo 表：一张 16MB 的图

对照 BOX-3 出厂固件用的自定义表（[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]]4.2 节已逐行拆解，此处只对比骨架）：

| 维度       | hello-s3（默认）                    | factory_demo（BOX-3 出厂）                                   |
| ---------- | ----------------------------------- | ------------------------------------------------------------ |
| 分区数     | 3（nvs/phy_init/factory）           | 8（sec_cert/nvs/otadata/phy_init/fctry/ota_0/storage/model） |
| 启用方式   | `PARTITION_TABLE_SINGLE_APP` 默认值 | `CONFIG_PARTITION_TABLE_CUSTOM=y` + partitions.csv           |
| app 分区   | factory @0x10000，1M                | ota_0，4200K                                                 |
| 资源分区   | 无                                  | storage（SPIFFS 音频资源）+ model（esp-sr 语音模型 8600K）   |
| Flash 声明 | **2MB**（`FLASHSIZE_2MB`）          | **16MB**（defaults 里 `FLASHSIZE_16MB=y`，QIO）              |

最后一行是本章最重要的教学点：**默认配置不认识你的板子**。hello-s3 没写 sdkconfig.defaults，于是拿到 `CONFIG_ESPTOOLPY_FLASHSIZE_2MB`（sdkconfig.h 第 396 行）+ DIO 模式；而 BOX-3 实机是 N16R8V 模组，**16MB** Flash、QIO。这个错位的三层后果放在 5.7 翻车点表第一条展开，这里先钉住事实本身。

---

## 5.3 map 文件初览：链接器的最终裁决书

`hello-s3.map` 有 3.6MB、三万六千多行，是链接器对"每个符号最终住在哪"的完整交代。结构上分三段：头部"哪个 .a 因为哪个符号被拖进链接"、中段按地址排布的段与符号、尾部全量交叉引用表。查法用 grep 直接示范——查 `app_main`，三处命中，各答一个问题：

```bash
$ grep -n "app_main" build/hello-s3.map | head
352:    (app_main)                                     # ① 谁把它拖进链接
29701: .text.app_main                                 # ② 住在哪、多大
29703:    0x4200c8e8    app_main
36167:app_main    esp-idf/main/libmain.a(hello-s3.c.obj)   # ③ 定义与引用
```

②处展开看（原文）：

```text
.text.app_main
                0x4200c8e8        0x5 esp-idf/main/libmain.a(hello-s3.c.obj)
                0x4200c8e8                app_main
```

一行读出四件事：函数名、地址 `0x4200c8e8`、大小 `0x5` 字节（hello world 确实只有 5 字节）、来自 `main` 组件的 `hello-s3.c.obj`。注意 `0x4200xxxx` 不是 Flash 内偏移，而是 **IROM 虚拟地址窗口**里的链接地址——虚拟地址与 Flash 物理偏移的换算由镜像段表与 MMU 映射承担，机制的归属见 [[2026-08-26-freertos-deep-dive-ch21-stack-and-memory-layout|FreeRTOS（二十一）内存布局]]。

③处的交叉引用表更妙，一行原文：

```text
app_main        esp-idf/main/libmain.a(hello-s3.c.obj)
                esp-idf/freertos/libfreertos.a(app_startup.c.obj)
```

`app_main` 由 main 组件**定义**、被 freertos 组件的 `app_startup.c.obj` **引用**——这正是第六章 `main_task()` 里那句 `app_main();` 调用的静态证据。链接发生时就注定了你的入口函数会被内核组件喊走。

三个日常用途：链接期 `undefined reference` 排查（查符号是否被链入、拼错了没有）、体积排查（配合 `idf.py size` 定位吃 Flash 的组件）、运行期崩溃回溯（monitor 打出的地址到 map 里反查函数）。后两个在第六、二十四章会反复用到。

---

## 5.4 esptool 与 ROM 下载模式：`idf.py flash` 背后

### 1. 命令是拼出来的

第三章说过 flash 动作住在 `tools/idf_py_actions/serial_ext.py`；现在看它拼命令的现场（源码 L61-84，节选）：

```python
def _get_esptool_args(args) -> list:
    result = [PYTHON, '-m', 'esptool', '-p', args.port, '-b', str(args.baud)]
    with open(os.path.join(args.build_dir, 'flasher_args.json'), encoding='utf-8') as f:
        flasher_args = json.load(f)                    # ← 读合同
    extra = flasher_args['extra_esptool_args']
    result += ['--before', extra['before'].replace('_', '-'),
               '--after',  extra['after'].replace('_', '-'),
               '--chip',   extra['chip']]
```

而构建系统那头，`flasher_args.json` 由 `components/esptool_py/project_include.cmake` 生成——`__esptool_py_setup_esptool_py_args()` 的源码注释原话："These argument lists are then stored ... for consistent use across the build system"，注释点名它同时服务 `elf2image` 与 flasher_args.json。于是构建与烧录共享同一份配置，永远不会"烧的参数和编的不一致"。

### 2. 等价命令原文

构建日志结尾直接把这条拼好的命令打印了出来（hello-s3 实测，原文）：

```text
python -m esptool --chip esp32s3 -b 460800 --before default-reset
  --after hard-reset write-flash --flash-mode dio --flash-size 2MB
  --flash-freq 80m
  0x0 build/bootloader/bootloader.bin
  0x8000 build/partition_table/partition-table.bin
  0x10000 build/hello-s3.bin
```

逐参数读：

| 参数                     | 值与来源                                 | 含义                                            |
| ------------------------ | ---------------------------------------- | ----------------------------------------------- |
| `-b 460800`              | serial_ext.py L33 `BAUD_RATE['default']` | 下载波特率（可用环境变量 `ESPBAUD` 覆盖）       |
| `--before default-reset` | flasher_args.json                        | 烧前自动复位进下载模式（DTR/RTS 电路）          |
| `--after hard-reset`     | 同上                                     | 烧完硬复位，直接启动新固件                      |
| `write-flash`            | —                                        | esptool v5 的连字符写法；后跟 `地址 文件` 对    |
| `--flash-mode/size/freq` | sdkconfig（dio/2MB/80m）                 | 写进**镜像头**，bootloader 启动时按它配置 Flash |

波特率补一句：BOX-3 走 USB-Serial-JTAG 时数据实际走 USB 通道，`-b` 的数值形同虚设（这说的是下载通道；monitor 的 115200 来自 `project_description.json` 的 `monitor_baud`）。

### 3. 进下载模式的两条路

esptool 能写 Flash 的前提是芯片处于**下载模式**——ROM 里的固化 loader 被激活，等主机指令。两条进门路径：

1. **BOOT 键（strap 路径）**：按住 BOOT（接 GPIO0）再点按 EN 复位，strap 采样判定进 Joint Download Boot。这是全系列 ESP 通用的手动路径；esptool 的 `default-reset` 用 DTR/RTS 两根线自动完成同样的动作，所以平时不用碰按键。strap 采样的位级细节（`boot:0xNN` 怎么解码）是第六章 6.2 节的内容。
2. **USB-Serial-JTAG 直达（S3 特色）**：S3 内建 USJ 外设，插线即枚举为 `/dev/ttyACM0`（内核 `cdc_acm`，免驱）。主机经 USB 控制请求就能让芯片复位进下载模式，不依赖 DTR/RTS——传统 USB-UART 桥（CP210x 等）才是 `/dev/ttyUSB*` 且要装驱动的老路。

### 4. write-flash 序列（概念级）

一次 `write-flash` 在时间轴上是五步：

```text
同步握手 → 上传 flasher stub → 按需擦除 → 逐段写入 → hard-reset
```

握手确认 ROM loader 在线；`stub: true` 表示随后把一段功能更全的**flasher stub** 程序换进 RAM 接管协议（快且支持更多命令）；擦除只擦将要写入的扇区范围（整片擦除是 `erase-flash` 的事）；写入即把三个 bin 按各自 offset 落盘；最后 `hard-reset` 让新固件启动。USB-Serial-JTAG 口上整套流程对用户就是"一条命令几秒钟"。

---

## 5.5 烧录实操：连板（待真机验证）

> [!warning] 待真机验证
> 以下全部为连板步骤。本章写作时 BOX-3 在途，命令与预期行为成稿，**输出留空待真机补录**；到货后逐条执行并核销。

### 1. 连板与权限

```bash
ls /dev/ttyACM*          # 预期：/dev/ttyACM0（板载 USB-Serial-JTAG）
groups | grep dialout    # 没有 dialout 组则无权开串口
sudo usermod -aG dialout $USER   # 加入后需注销重登生效
```

两个 Fedora 常见坑：**ModemManager** 会对新出现的 ttyACM 设备做拨号探测，表现为 esptool 连接超时或 monitor 乱码——`systemctl stop ModemManager`（调试期）或 `systemctl disable ModemManager` 更彻底；另一个 monitor 进程没退干净占着口，`fuser /dev/ttyACM0` 查占用户。

### 2. 烧录 + 监视

```bash
cd ~/esp/hello-s3 && . ~/esp/esp-idf/export.sh
idf.py -p /dev/ttyACM0 flash monitor
```

预期（待真机验证）：esptool 打印芯片与 MAC、stub 上传、三个镜像各一段 `Hash of data verified`，最后 `Hard resetting via RTS pin...`，monitor 接管串口打出启动日志（第六章 6.5 节那张逐行对账表就是为这一刻准备的）。退出 monitor 是 `Ctrl-]`。

### 3. flash 与 app-flash：三件套还是一件

build 目录里那三个单镜像参数文件对应三个细粒度命令（`app-flash_args` 全文就两行：`--flash-mode dio ... 0x10000 hello-s3.bin`）：

| 命令                 | 烧什么                           | 适用                                               |
| -------------------- | -------------------------------- | -------------------------------------------------- |
| `idf.py flash`       | 三镜像齐烧（0x0/0x8000/0x10000） | 默认选择；改过分区表/bootloader 配置后**必须**用它 |
| `idf.py app-flash`   | 只烧 app（0x10000）              | 迭代业务代码，省几秒                               |
| `idf.py erase-flash` | **整片擦除**                     | 见下                                               |

`erase-flash` 的后果要心里有数：nvs（WiFi 凭据、用户数据）、phy_init（RF 校准）全部归零。对 BOX-3 更致命——出厂固件的 model（语音模型）、fctry、sec_cert 分区也会一并抹掉，**这等于销毁出厂数据**。想擦除前先做 5.6 节的备份。

---

## 5.6 备份与恢复：动 Flash 之前的仪式

> [!warning] 待真机验证
> 备份/恢复同样是连板操作，与 5.5 同批核销。

第一次 `idf.py flash` 之前，把 BOX-3 的出厂状态整片读回来——16MB 全量（`0x1000000`），一步到位：

```bash
python -m esptool -p /dev/ttyACM0 read-flash 0 0x1000000 box3-factory-backup.bin
```

（esptool v5 子命令用连字符写法 `read-flash`，与 v5.3.1 一致，已在 venv 安装里核对。）恢复即原样写回：

```bash
python -m esptool -p /dev/ttyACM0 write-flash 0x0 box3-factory-backup.bin
```

验证备份完整性的两个廉价手段：文件大小应恰为 `0x1000000`（16MB，`read-flash` 中断会得到截断文件，必须重读）；开头的字节里应能在 0x8000 附近看到分区表（魔数 `0x50AA` 开头的条目，第六章 6.3 节的校验规则反着用）。

想只看分区不动数据，用 `parttool.py`（住在 `components/partition_table/`，export 已把它注入 PATH——[[2026-08-26-esp32-s3-box-3-ch3-idf-toolchain|第三章]]3.3 节核实过）：

```bash
parttool.py -p /dev/ttyACM0 get_partition_info --part_list   # 列出板上分区
```

它按 0x8000 读出实机分区表逐项打印——与第四章 4.2 节那张 partitions.csv 对账，是"板上跑的到底是不是出厂固件"的一手证据。

---

## 5.7 翻车点表与小结

| 症状/误区                                                                                 | 根因                                                                                                                                              | 处理                                                                                               |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| "84% free，Flash 很空" 的误读                                                             | 分母是**最小 app 分区**（1M），不是 2MB 声明，更不是 16MB 实机                                                                                    | 评估容量时用 `idf.py size` + 分区表，别拿 free 百分比当 Flash 余量                                 |
| 默认配置烧上 BOX-3"能用但只有 2MB"                                                        | `CONFIG_ESPTOOLPY_FLASHSIZE_2MB` 是 hello-s3 默认；镜像头声明写死 2MB，bootloader 按 16MB 实况（`g_rom_flashchip.chip_size`）之外的分区校验会失败 | 板级事实写进 `sdkconfig.defaults`（`FLASHSIZE_16MB=y`，factory_demo 正是范本，第四章 4.5）         |
| factory_demo 分区表 + 2MB 声明 → 启动报 `partition N invalid ... exceeds flash chip size` | 分区表按 16MB 排布，越出声明的 2MB 容量（第六章 6.3 的校验逻辑）                                                                                  | set-target 后确认 sdkconfig 的 flash-size 与分区表一致再 flash                                     |
| `/dev/ttyACM0` 打不开/被占                                                                | 无 dialout 权限、ModemManager 探测、残留 monitor 进程                                                                                             | 见 5.5 节 1 的三连排查                                                                             |
| 手敲 offset 烧错位置 → 复位循环 `invalid header: 0xffffffff`                              | 镜像错位，ROM/bootloader 找不到合法镜像头                                                                                                         | 用 `write-flash "@flash_args"` 让文件说话；整片重来先 `erase-flash` 再 flash（第六章翻车表有同款） |
| `read-flash` 中途拔线                                                                     | 备份文件截断，且无任何标记                                                                                                                        | 校验文件大小恰为 0x1000000，不齐就重读                                                             |
| 想省事直接 `erase-flash`                                                                  | BOX-3 的 model/fctry/sec_cert 出厂分区被抹，语音模型与 claiming 数据丢失                                                                          | 先 5.6 全量备份；erase 后可用备份写回                                                              |

本章小结：

- build 目录的**核心契约**是 `flasher_args.json`：构建系统（`esptool_py/project_include.cmake`）生成它，烧录工具链（`serial_ext.py` → esptool）消费它——offset 与 flash 参数在编译期定死，烧录期只是执行。
- **三镜像三段式**：bootloader @0x0（S3 从 0x0 取，经典 esp32 是 0x1000）、分区表 @0x8000（CSV 由 `gen_esp32part.py` 转二进制，上限 96 项、表区 0x1000、带 MD5）、app @分区表指定（默认单 app 表为 0x10000）。分区表决定 app 烧哪，flasher_args 如实转述。
- **elf 给人、bin 给机器**：`elf2image` 把带符号的 elf 转成带 0xE9 镜像头的裸字节流；map 文件是链接器的裁决书，`grep` 三连（谁拖进链接/住哪多大/谁引用）覆盖日常排查。
- 烧录链路的执行者是 venv 里的 **esptool v5.3.1**：进下载模式有 BOOT strap 与 USB-Serial-JTAG 直达两条路，BOX-3 的 `/dev/ttyACM0` 走后者、免驱；write-flash 是"握手→stub→按需擦→写→复位"的序列。
- 最大的一条工程教训藏在 2MB 与 16MB 之间：**默认配置不认识你的板子**——flash 尺寸、模式这类板级事实必须落到 sdkconfig.defaults，这正是第四章"defaults 是板子身份证"结论在烧录链路上的回响。

下一章按住复位键：三镜像躺进 Flash 之后，ROM 如何从 0x0 一路接力把 CPU 交给 `app_main`——启动日志逐行对账，从那里开始。
