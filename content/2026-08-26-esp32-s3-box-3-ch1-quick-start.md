---
title: "ESP32-S3-BOX-3 工程实战（一）：三十分钟跑通"
date: 2026-08-26 12:00:00
description: "从开箱五件套、出厂固件体验到刷机前的全片备份，再到 ESP-IDF v6.0.2 环境搭建与第一个自建固件 hello-s3 的完整构建链：主机侧命令全部在本机实测并附真实日志，四个排坑（SSL 误诊、大文件断点续传、子模块缺失、create-project 选项）完整复盘，外加 factory_demo 撞上 v6 版本墙的实录与 v5.1.5 双版本环境的构建成功记录。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（一）：三十分钟跑通

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 系列开篇（本章为第一章）
> **第一章：三十分钟跑通**（当前章）
> 下一章：[[2026-08-26-esp32-s3-box-3-ch2-ecosystem-map|第二章：乐鑫开源生态与资料地图]]

这一章回答三个问题：**怎么把板子跑起来**（验货、第一次上电、体验出厂固件、刷机前备份）、**怎么把环境搭起来**（克隆 esp-idf、安装工具链，以及四个真实排坑的完整复盘）、**怎么把第一个自己的固件构建出来**（create → set-target → build 全流程，附真实构建日志）。读完它，你的主机侧工具链应当完全就绪，手里有一个能烧进 BOX-3 的 `hello-s3.bin`，并且知道每一步翻车时该往哪查。

「三十分钟」是网络通畅、不踩坑时的理想节奏——1.3 与 1.4 两节的命令序列就是全部。本章近一半篇幅给了排坑实录，因为真实世界里，时间恰恰花在这些地方。

> [!note] 本章的证据口径
> 主机侧（克隆/安装/构建）的每条命令都在本机实测执行过：Fedora x86_64、ESP-IDF v6.0.2（克隆于 `~/esp/esp-idf`），文中终端输出均为真实日志摘录。真机侧步骤（体验出厂固件、备份、烧录）因硬件在途，统一标注「待真机验证」，到货后回填；QEMU 段命令可执行，输出待补录。
> 本系列与 [[2026-08-26-freertos-deep-dive-ch1-from-bare-metal-to-rtos|FreeRTOS 深度解析系列]] 共用同一套 v6 环境：那边第一章装的是 esp32 目标，本章在其基础上补装 esp32s3——两条目标的工具链大量共享，证据在第三章 3.5 节。

---

## 1.1 到货验货与第一次上电

### 1. 标准版五件套

ESP32-S3-BOX-3 标准版包装里有五件东西，先认脸：

| 部件               | 是什么                     | 关键器件                                                                                                                                                                                                                |
| ------------------ | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 主机（BOX-3 本体） | 核心板：模组 + 屏幕 + 音频 | ESP32-S3-WROOM-1 N16R8V（双核 Xtensa LX7 @240MHz，16MB Flash / 8MB Octal PSRAM）、2.4" 320×240 ILI9342C 屏幕、GT911/TT21100 电容触摸（BSP 双探测，第九章 I2C 扫描定案）、ES8311 codec（扬声器）、ES7210（双麦克风 ADC） |
| DOCK               | 底座与功能扩展             | GPIO 引出、供电                                                                                                                                                                                                         |
| SENSOR             | 传感器子板                 | 温湿度（AHT20）、红外收发（[[2026-08-26-esp32-s3-box-3-ch12-rmt-infrared                                                                                                                                                | 第十二章]]用 RMT 点亮）、雷达（AT581x） |
| BRACKET            | 支架                       | —                                                                                                                                                                                                                       |
| BREAD              | 面包板转接板               | 后面各章搭外设实验用                                                                                                                                                                                                    |

> [!note] 触摸型号的口径
> 本机 BSP（v1.1.3）源码只探测 GT911（地址 0x5D/0x14）与 TT21100（0x24）两种触摸控制器；外部资料常写的 FT6336 未获源码支持，本文一律以「GT911/TT21100」为准，最终以第九章的 I2C 总线实扫定案。

这张表不必背——每颗芯片都会在对应章节走满「应用 → 组件 → 寄存器 → 波形」四层下钻，第十四章还会从 BSP 源码把它们全部反查出来。

### 2. 第一次上电：出厂固件体验

> [!warning] 待真机验证
> 本小节为预期体验清单，硬件到货后逐条核对回填。

一根 USB-C **数据线**（充电线不行，这是新手第一大坑）连主机上电，屏幕亮起出厂 factory_demo 界面。它把这块板的卖点全串了起来：

- **语音唤醒**：对它说「嗨乐鑫」或「Hi ESP」——中文、英文两个唤醒词都内置，唤醒后屏幕弹出动画、扬声器给提示音。背后是 WakeNet9 模型在双麦克风阵列上的实时推理，这是第十八章的主题，也是[[2026-08-26-esp32-s3-box-3-ch20-capstone-voice-remote|第二十章]]收官项目要重新造一遍的那条链路。
- **语音对话与设备控制**：唤醒后说命令词，屏幕 UI 响应、扬声器回话。
- **触摸屏**：电容触摸可以直接戳，滑动切页。

出厂固件值得先玩熟再动手——它是后面 8~18 章逐个点亮的能力总览，也是刷机前后对照的基准。

---

## 1.2 刷机前备份出厂固件

结论先行：**第一次烧录之前，先把整片 Flash 备份下来**。`idf.py flash` 会覆盖出厂 app，`erase-flash` 更是把全片（含 NVS 里的出厂数据）清空；而 16MB 全片镜像是一份完整的后悔药——分区表、bootloader、app、NVS 全在里面。

| 备份粒度          | 范围         | 适用                             |
| ----------------- | ------------ | -------------------------------- |
| 全片 16MB（推荐） | `0x0` 起整片 | 万无一失的后悔药，本文采用       |
| 仅出厂 app        | app 分区     | 体积小，但恢复时仍需分区表等配套 |
| 仅 NVS            | 数据分区     | 只想留出厂校准类数据             |

> [!warning] 待真机验证
> 以下命令为标准 esptool 用法，待真机执行后补充实测输出与耗时。

```bash
. ~/esp/esp-idf/export.sh                 # 让 venv 里的 esptool 进入 PATH（机制第三章拆）
esptool -p /dev/ttyACM0 -b 460800 read_flash 0 0x1000000 box3-factory-16m.bin
sha256sum box3-factory-16m.bin > box3-factory-16m.bin.sha256   # 留档校验
```

`0` 是起始地址，`0x1000000` 是 16MB——对应 N16R8V 里的 N16。恢复出厂状态则是原样回写：

```bash
esptool -p /dev/ttyACM0 -b 460800 write_flash 0x0 box3-factory-16m.bin
```

两个纪律：备份文件连同 sha256 归档到工作机之外；**备份完成之前，不要执行任何 erase 类操作**。

---

## 1.3 搭环境：本机实测主线

### 1. 克隆 esp-idf：三个参数各管什么

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v6.0.2 --recursive --depth 1 --shallow-submodules \
    https://github.com/espressif/esp-idf.git
cd esp-idf
```

| 参数                   | 作用                                                      | 不带的后果                               |
| ---------------------- | --------------------------------------------------------- | ---------------------------------------- |
| `-b v6.0.2`            | 锁定版本                                                  | 版本漂移，与系列对不上号                 |
| `--recursive`          | IDF 的组件是 git 子模块（FreeRTOS 内核、mbedtls、lwip……） | 得到「看起来完整、编译缺文件」的空壳仓库 |
| `--depth 1`            | 只取该 tag 最新一个提交，不拉历史                         | 全量历史又大又慢                         |
| `--shallow-submodules` | 子模块同样浅克隆                                          | 子模块体积放大数倍                       |

浅克隆省时省流量，但有个代价要到坑三才显现：它把「网络中断」从「重试即可」变成「需要专门补齐」。

### 2. 安装与激活

```bash
./install.sh esp32s3      # 只装 esp32s3 目标需要的二进制工具，落盘到 ~/.espressif
. ./export.sh             # 注意：必须 source（前面那个点），不能执行；每个新终端一次
```

真实输出（`export.sh` 尾部，本机摘录）：

```text
Activating ESP-IDF 6.0
Setting IDF_PATH to '/home/huanglin/esp/esp-idf'.
* Checking python version ... 3.14.3
* Checking python dependencies ... OK
* Deactivating the current ESP-IDF environment (if any) ... OK
* Establishing a new ESP-IDF environment ... OK
* Identifying shell ... bash
* Detecting outdated tools in system ... OK - no outdated tools found
* Shell completion ... Autocompletion code generated

Done! You can now compile ESP-IDF projects.
Go to the project directory and run:

  idf.py build
```

本机落盘清单（实测）：

| 落盘位置                                                     | 内容                                                           |
| ------------------------------------------------------------ | -------------------------------------------------------------- |
| `~/.espressif/tools/xtensa-esp-elf/esp-15.2.0_20251204/`     | 交叉工具链（gcc/binutils/libc）                                |
| `~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/` | Espressif QEMU fork（显式安装的 on_request 工具）              |
| `~/.espressif/python_env/idf6.0_py3.14_env/`                 | Python venv（Python 3.14.3），esptool 等纯 Python 工具住在这里 |

注意 esptool 不在 `tools/` 里——v6 的分发分界线是「二进制工具走 tools.json、纯 Python 工具走 venv pip」，第三章展开。install.sh 与 export.sh 背后的整套机制（42 行薄壳、四段接力）也在那边走读，本章只用结论。

### 3. 排坑实录一：下载连环 SSL EOF，先定位「谁掐的连接」

`install.sh` 跑到下载工具链的环节，接连报 `SSL: UNEXPECTED_EOF_WHILE_READING`，重试耗尽；而同一台机器 `git clone` GitHub 仓库一直正常。第一反应是经典的「镜像问题」——工具包从 GitHub release 资产域名下载，先入为主的诊断是网络干扰，于是切到乐鑫官方镜像 `IDF_GITHUB_ASSETS=dl.ci.espressif.com`。结果当日该镜像的 CDN 节点恰好故障，依旧 TLS 失败，一度陷入「两个源都不行」的僵局。

回头做了一组对照实验才找到真凶：

| 通道          | 目标                             | 结果                |
| ------------- | -------------------------------- | ------------------- |
| 沙箱内 python | github.com / dl.ci.espressif.com | 一律 TLS 握手失败   |
| 正常环境 curl | GitHub release 资产              | 返回 206，正常      |
| 正常环境访问  | dl.ci.espressif.com              | 当日 CDN 故障，失败 |

掐断连接的是执行安装的自动化沙箱自身的网络策略，不是任何镜像——「谁连谁都断」的病，换镜像当然治不好。

- **现象**：`install.sh` 下载工具包连续 `SSL: UNEXPECTED_EOF_WHILE_READING`，重试耗尽；同机 `git clone` 正常。
- **原因**：执行环境的网络沙箱掐断 python 直连 TLS（git 通道与 https 资产通道策略不同）；最初误诊为镜像问题。
- **解法**：安装一律回到正常网络环境执行、GitHub 直连；pip 保留国内镜像（`IDF_PIP_INDEX_URL`）。

教训一句话：换镜像之前，先用「同一文件、不同通道」做对照实验，确认是谁掐的连接。这次误诊浪费的正是来回切镜像的时间。

### 4. 排坑实录二：大文件必断，而 idf_tools 无断点续传

沙箱问题解决后，下载依然不安生：42MB 的 gdb 包一次成功；180MB 的 xtensa-esp-elf 主工具链包下到 69MB 处连接被掐（retrieval incomplete），重试又见 SSL EOF。更糟的是 `idf_tools.py` 的下载器没有断点续传——每次重试从 0 开始，断一次前功尽弃，永不收敛。

观察规律可以发现：小文件总能过、大文件必断——出口网络对大流量传输随机掐断。对策是把「下载」从 idf_tools.py 手里接过来，交给支持 Range 续传的 curl，并利用它的一个特性：**工具包下载后缓存在 `~/.espressif/dist/`，而 idf_tools.py 检测到 dist/ 里已有同名包就跳过下载，只做 sha256 校验与解压**。

```bash
# 循环续传直至完整：-C - 表示从已有文件的断点继续
while ! curl -L -C - -o ~/.espressif/dist/<包名>.tar.gz <下载地址>; do sleep 2; done
```

下载地址从 install.sh 首次失败的日志（或 `tools/tools.json`）里逐个抄出；半成品 `.tmp` 文件改名后同样能被 `-C -` 接着用。全部包预下载完成后重跑 `./install.sh esp32s3`，这次它只校验、解压、登记，几分钟收工。本机这套预下载整理成了脚本（`~/esp/shims/prefetch-tools.sh`），任何「大文件 + 无续传下载器」的场景都适用。

- **现象**：42MB 的 gdb 包一次成功；180MB 的 xtensa-esp-elf 包下到 69MB 处被掐，重试又 SSL EOF；每次重试从头下载。
- **原因**：出口网络随机掐断大流量传输（小文件可过、大文件必断）；idf_tools 下载器不支持 Range 续传。
- **解法**：`curl -C -` 循环续传，把全部工具包预下载到 `~/.espressif/dist/`，再跑 install.sh 走「只校验解压」的快路径。

### 5. 排坑实录三：浅克隆的子模块目录是空的

环境装好，构建却在 cmake 阶段报 mbedtls 的 include 目录不存在。到 esp-idf 仓库执行 `git submodule status` 一看：mbedtls 等 9 个子模块状态异常——**目录已注册、内容未落盘**。带 `--recursive` 的大仓浅克隆中途被网络中断打断，git 登记了子模块路径，检出却没有完成。

解法是循环补齐直至收敛：

```bash
cd ~/esp/esp-idf
git submodule update --init --recursive --depth 1   # 重复执行，直至无检出输出
```

本机收敛的实录就写在构建日志的开头——一次补齐把 Wi-Fi 库、tlsf、lwip、mbedtls 等逐个检出：

```text
子模组路径 'components/esp_wifi/lib'：检出 'bb69e7e609c9a9a909ddd1ed175f36df2bd13801'
子模组路径 'components/heap/tlsf'：检出 '2867f6883a12920b1969ff9624c0ab0e4185c2ce'
子模组路径 'components/lwip/lwip'：检出 'fd432e4ee2cfb7f7f1c7eb7227e0173412e7b84e'
子模组路径 'components/mbedtls/mbedtls'：检出 '6cc42afad309e861f4c07e6f106e2ab14a9cb8e5'
...
```

- **现象**：构建报 mbedtls include 目录不存在；`git submodule status` 显示 9 个子模块目录已注册、内容未落盘。
- **原因**：大仓浅克隆时，递归子模块检出被网络中断打断。
- **解法**：循环执行 `git submodule update --init --recursive --depth 1` 直至收敛，再重新构建。

三个坑一条暗线：**它们全是「网络不可靠」在不同环节的投影**（下载被掐 → 下载器无续传 → 子模块检出中断），对策的公共思路是把「一次性长事务」换成「可重入的短事务」（curl 续传、子模块补齐）。

---

## 1.4 第一个自己的固件：hello-s3 从无到有

### 1. 正确的创建姿势（先看踩坑）

先看一个「一步到位」创建指定目标工程的写法：

```bash
idf.py create-project --target esp32s3 hello-s3
```

在 v6.0.2 上实测直接报错 `No such option: --target`：参数解析层就拒绝了，工程根本没创建。v6 的 `create-project` 子命令不接收 `--target`，网上与旧文档里这类一步到位的写法在这里全部踩坑。

- **现象**：`idf.py create-project --target esp32s3 hello-s3` 报 `No such option: --target`。
- **原因**：v6 的 create-project 子命令本身没有 `--target` 选项。
- **解法**：两步走——先建骨架，再设目标。

```bash
cd ~/esp
idf.py create-project hello-s3    # 生成最小骨架：CMakeLists.txt + main/
cd hello-s3
idf.py set-target esp32s3         # 设定目标芯片，生成 sdkconfig
idf.py build
```

骨架小到可以整段看完——`main/hello-s3.c`（注意源文件名跟工程名走）的全部内容：

```c
#include <stdio.h>

void app_main(void)
{

}
```

一个空的 `app_main` 就能构建出固件，这本身就是信息：系统组件是构建系统自动拉进来的，不靠你写一行代码。

### 2. set-target 的代价：比看上去贵得多

`set-target` 不是「改个配置变量」：它先触发 fullclean 整删 build/ 目录，再把现有 `sdkconfig` **改名为 `sdkconfig.old`**（注意是改名不是删除——menuconfig 的手工修改都还躺在 `.old` 里，可以捞回来），然后按 esp32s3 的默认值全量重新配置。代价是下一次全量重编；纪律是把工程真正依赖的配置差异写进 `sdkconfig.defaults`，而不是手改 sdkconfig。这条命令的完整源码走读见[[2026-08-26-esp32-s3-box-3-ch3-idf-toolchain|第三章]] 3.5 节。

### 3. build：真实输出与逐段解读

首次构建的真实输出（日志较长，摘关键段）：

```text
Executing action: all (aliases: build)
Running cmake in directory /home/huanglin/esp/hello-s3/build
...
-- IDF_TARGET is not set, guessed 'esp32s3' from sdkconfig '/home/huanglin/esp/hello-s3/sdkconfig'
-- Found assembler: /home/huanglin/.espressif/tools/xtensa-esp-elf/esp-15.2.0_20251204/xtensa-esp-elf/bin/xtensa-esp32s3-elf-gcc
-- Building ESP-IDF components for target esp32s3
...
esptool v5.3.1
Creating ESP32-S3 image...
Successfully created ESP32-S3 image.
Generated /home/huanglin/esp/hello-s3/build/hello-s3.bin
Bootloader binary size 0x5240 bytes. 0x2dc0 bytes (36%) free.
...
[1062/1062] ... check_sizes.py ...
hello-s3.bin binary size 0x28050 bytes. Smallest app partition is 0x100000 bytes. 0xd7fb0 bytes (84%) free.

Project build complete. To flash, run:
 idf.py flash
or
 idf.py -p PORT flash
or
 python -m esptool --chip esp32s3 -b 460800 --before default-reset --after hard-reset write-flash --flash-mode dio --flash-size 2MB --flash-freq 80m 0x0 build/bootloader/bootloader.bin 0x8000 build/partition_table/partition-table.bin 0x10000 build/hello-s3.bin
```

五段值得停下来读：

1. **动作别名**：`Executing action: all (aliases: build)`——`build` 是 `all` 的别名，idf.py 的命令面是插件式拼出来的（第三章）。
2. **cmake 从 sdkconfig 猜出目标**：`guessed 'esp32s3' from sdkconfig`——target 的持久化载体是 sdkconfig，多处来源不一致时构建直接报错（第三章 3.5）。
3. **1062 个构建目标**：空 `app_main` 的工程也要编 1062 步——FreeRTOS、libc、驱动、日志系统全在依赖树里。工程的组件体系是[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]]的主题。
4. **烧录命令是三段镜像**：bootloader 写 `0x0`、分区表写 `0x8000`、app 写 `0x10000`。这个「三镜像结构」是第五章的主题，首次烧录三段都要写。
5. **注意 `--flash-size 2MB`**：默认 sdkconfig 按 2MB Flash 生成（1MB 的 app 分区也由此而来），而 BOX-3 实际是 16MB。教学工程不改也能跑，但上真机前应把 Flash Size 改成 16MB（menuconfig 的 Serial flasher config → Flash size），否则 16MB 只用得上前 2MB——sdkconfig 与分区表的机制分别在第四、五章。

### 4. 等板子的日子：QEMU 先跑一遍（可选）

本机装了 Espressif 的 QEMU fork（与 FreeRTOS 系列共用），没有板子也能先看固件跑起来：

```bash
idf.py qemu monitor
```

（输出待补录。）代码与真机完全一致，QEMU 只是换了执行者——这条方法论在 FreeRTOS 系列第一章已验证过。

---

## 1.5 esp-box 与 factory_demo：撞上版本墙

### 1. 仓库一瞥

```bash
cd ~/esp
git clone --recursive https://github.com/espressif/esp-box.git
```

esp-box 是 BOX 系列的官方 demo 仓库，`examples/` 下是九个完整示例（本机实测清单）：factory_demo、chatgpt_demo、matter_switch、usb_headset、usb_camera_lcd_display、mp3_demo、image_display、lv_demos、watering_demo。

有个值得现在就记住的细节：factory_demo 的板级支持包 `esp-box-3` 并不在 esp-box 仓库里，而是构建时由组件管理器从**组件注册表**拉进 `managed_components/espressif__esp-box-3/`（本机实测路径）。「组件从哪来」的三种来源是第四章的大主题，这里先留个活例子。

### 2. 在 v6 上构建 factory_demo：一次预期内的失败

```bash
cd ~/esp/esp-box/examples/factory_demo
idf.py set-target esp32s3
idf.py build
```

在 IDF v6.0.2 上实测，cmake 配置阶段即失败：

```text
The component 'json' could not be found
```

- **现象**：factory_demo 在 v6.0.2 下 cmake 阶段报 `The component 'json' could not be found`。
- **原因**：IDF v6 把 `json` 等组件从仓库移除/迁出（转向组件注册表），而 esp-box master 的组件树（esp-sr 1.4.\*、rainmaker 1.1 等）面向 release/v5.1。factory_demo 的 README 写着「requires ESP-IDF release/v5.1 or later」——实测表明这个「or later」的事实上界就是 v5.x。
- **解法**：跟官方约束走，用 v5.1 环境构建（下一小节）；教学主线则留在 v6 自建工程。

### 3. 路 A：v5.1.5 双版本环境实测（构建成功）

同一台机器上双版本 IDF 并存完全可行，做法是再克隆一份独立目录：

```bash
cd ~/esp
git clone -b v5.1.5 --recursive --depth 1 --shallow-submodules \
    https://github.com/espressif/esp-idf.git esp-idf-v5.1
cd esp-idf-v5.1 && ./install.sh esp32s3
```

要点：工具链仍装进同一个 `~/.espressif`——工具目录自带版本号（第三章 3.2），互不冲突；Python venv 按版本分家（`idf6.0_py3.14_env` 与 `idf5.1_py3.x_env` 并存），**source 谁的 export.sh 就用谁**。

切到 v5.1.5 环境构建 factory_demo 前，还有一个小坑：上次 v6 失败残留的 build/ 目录会让 `idf.py fullclean` 的护栏直接拒绝工作（报 `doesn't seem to be a CMake build directory. Refusing to automatically delete`）——直接 `rm -rf build` 清掉即可。随后构建成功，真实结果行：

```text
Bootloader binary size 0x5680 bytes. 0x2980 bytes (32%) free.
factory_demo.bin binary size 0x3cafa0 bytes. Smallest app partition is 0x41a000 bytes. 0x4f060 bytes (8%) free.
```

对比 1.4 的 hello-s3，两行输出把「官方全家桶 demo 有多肥」讲得明明白白：

| 工程                   | app 体积              | app 分区占用    | map 文件 | 额外产物                                                    |
| ---------------------- | --------------------- | --------------- | -------- | ----------------------------------------------------------- |
| hello-s3（v6）         | 0x28050（约 164KB）   | 16%（84% free） | 3.6MB    | 无                                                          |
| factory_demo（v5.1.5） | 0x3cafa0（约 3.98MB） | 92%（8% free）  | 16MB     | ota_data_initial.bin、storage.bin（2.66MB SPIFFS 资源镜像） |

语音模型、LVGL 界面、中文字库、OTA 分区、SPIFFS 资源分区全在一个工程里——app 分区被吃到 92%，也解释了为什么它需要自定义分区表（第四、五章展开）。

> [!warning] 待真机验证
> factory_demo 的烧录与上板体验（唤醒词、屏显、设备控制）待真机回填；主机侧构建结论以上表为准。

### 4. 路 B 与本系列的选择

**路 B：教学主线继续 v6 + 自建工程。** 这是本系列的选择，理由三条：

1. **环境单一**：与 FreeRTOS 系列共用一套 v6，两条线的实验互相咬合；
2. **不替上游做移植**：在 v6 上硬修 factory_demo 等于替 esp-box 做版本移植，超出入门章的射程；
3. **主线本来就是自建工程**：本系列的教学路径是「自己搭工程、逐层下钻」，factory_demo 留作官方路径的对照组——第四章解剖它的工程结构、第二章反查它的组件清单时，都以 v5.1 路径与仓库事实为准。

这是一次如实的记录而不是事故：官方 demo 的版本墙是「组件树面向旧版 IDF」的典型样本，本系列后续章节引用 factory_demo 均按此口径。

---

## 1.6 烧录准备：USB-Serial-JTAG 与第一次 flash

> [!warning] 待真机验证
> 本节全部步骤待真机执行后回填实测输出。

### 1. 串口三件事

- **认对设备**：S3 内置 USB-Serial-JTAG，Linux 免驱，设备名是 `/dev/ttyACM0`（区别于外挂串口芯片的 `/dev/ttyUSB*`）。`ls /dev/ttyACM*` 确认。
- **权限**：`permission denied` 说明当前用户不在 dialout 组：`sudo usermod -aG dialout $USER` 后重新登录（或 `newgrp dialout`）。
- **Fedora 特有的坑：ModemManager**。它默认运行、会把新出现的 ttyACM 设备当调制解调器轮询，烧录时序被搅得时好时坏。最省心的处理是 `sudo systemctl disable --now ModemManager`；不便关闭的话，用 udev 规则对乐鑫 VID 做豁免。

### 2. 一条命令：烧录 + 监视

```bash
idf.py -p /dev/ttyACM0 flash monitor
```

它做的事正是 1.4 节构建尾部打印的那条三镜像 `write-flash` 命令，外加起串口监视器（退出 `Ctrl-]`）。USB-Serial-JTAG 由 esptool 自动复位进下载模式，不需要按 BOOT 键。esptool 与芯片 ROM 下载模式的握手过程，第五章拆。

### 3. 恢复出厂固件（呼应 1.2）

玩坏了自己的固件想回出厂状态，用 1.2 的备份原样回写：`esptool -p /dev/ttyACM0 -b 460800 write_flash 0x0 box3-factory-16m.bin`。注意：若按 1.4 的建议把 Flash Size 改成了 16MB，恢复出厂镜像前先把工程配置改回与镜像一致，避免分区表口径混乱。

---

## 1.7 翻车点大表与小结

| 症状                                                      | 原因                                                         | 解法                                                                 |
| --------------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------- |
| install.sh 下载连续 `SSL: UNEXPECTED_EOF_WHILE_READING`   | 传输通道被掐（先分辨是谁掐的：网络策略、镜像故障还是防火墙） | 正常网络环境执行；pip 走镜像 `IDF_PIP_INDEX_URL`                     |
| 大工具包下到一半必断，重试从头来                          | 出口网络掐大流量；idf_tools 无断点续传                       | `curl -C -` 预下载到 `~/.espressif/dist/`（1.3 坑二）                |
| 构建报 mbedtls include 目录不存在                         | 浅克隆子模块检出被中断，目录空                               | 循环 `git submodule update --init --recursive --depth 1`（1.3 坑三） |
| `create-project --target` 报 `No such option: --target`   | v6 的 create-project 无此选项                                | `create-project` 后 `set-target` 两步走（1.4 坑四）                  |
| `idf.py fullclean` 报 `Refusing to automatically delete`  | 残留 build/ 目录不是有效 CMake 目录（上次失败留下）          | 直接 `rm -rf build`（1.5 路A）                                       |
| set-target 后 menuconfig 修改全没了                       | sdkconfig 改名 `.old` + fullclean 清 build/                  | 从 `.old` 抢救，配置差异写 `sdkconfig.defaults`（第三章 3.5）        |
| factory_demo 报 `The component 'json' could not be found` | esp-box 组件树面向 release/v5.1，v6 迁出了 json 组件         | 官方路径用 v5.1.5 环境构建；教学主线 v6 自建工程（1.5）              |
| `/dev/ttyACM0` permission denied                          | 不在 dialout 组                                              | `usermod -aG dialout` 后重登                                         |
| 烧录时串口时好时坏 / 突然复位                             | ModemManager 抢占 ttyACM 设备                                | `systemctl disable --now ModemManager` 或 udev 豁免                  |
| 新终端 `idf.py` command not found                         | 没 source export.sh                                          | 每个终端 `. ~/esp/esp-idf/export.sh`                                 |
| 上电没反应                                                | USB 线是充电线（无数据）                                     | 换数据线                                                             |

**小结**：

- 三问已答：**板子**——五件套认脸、出厂固件体验与 16MB 全片备份（待真机回填）；**环境**——v6.0.2 浅克隆 + `install.sh esp32s3` + `export.sh`，四个坑的复盘沉淀成可复用的手法（对照实验定位掐断者、curl 断点续传、子模块循环补齐、两步建工程）；**固件**——`hello-s3.bin`（0x28050 字节）全链路构建成功，烧录命令已就绪。
- 版本墙如实记录：factory_demo 在 v6 上失败（`json` 组件缺失），在 v5.1.5 双版本环境下构建成功（app 分区占用 92%）——官方 demo 走 v5.1.5，教学主线走 v6 自建工程，后续章节按此口径引用。
- 一条主线认知：网络不可靠会在每个环节留下残局，把长事务换成可重入的短事务是通用对策。

下一章铺开地图：esp-idf / esp-box / esp-bsp / esp-sr / esp-dl 这些仓库各管什么、文档体系怎么按四层下钻取用、factory_demo 的组件清单如何反查出 BOX-3 的全部硬件——见[[2026-08-26-esp32-s3-box-3-ch2-ecosystem-map|第二章：乐鑫开源生态与资料地图]]。
