# 决策日志（KD）

按 spec-driven-feature 约定：踩坑必须转化为编号决策，修 bug 不写 KD 不算完成。
被取代的决策标记 `SUPERSEDED by KD-<m>`，不删除。

## KD-1: esp-box 官方 demo 对 IDF 版本敏感 — RESOLVED 2026-08-26

Phenomenon: factory_demo 在 IDF v6.0.2 下 cmake 阶段即失败：
component 'json' could not be found。
Root cause: IDF v6 移除/迁出了 `json` 等组件（进组件注册表），esp-box
master 组件树（esp-sr 1.4.\*、rainmaker 1.1 等）面向 release/v5.1；
README 的版本约束是真实的。
Decision: 双轨制——教学主线（ch1/ch5 的构建烧录）用 IDF v6 + 自建最小工程
（hello-s3，已实测成功）；factory_demo 用独立 v5.1.5 环境构建（已实测成功：
factory_demo.bin 0x3cafa0、app 分区占用 92%、含 storage.bin SPIFFS 资源镜像；
双 IDF 并存于同一 ~/.espressif，venv 按版本隔离）。附带发现：v6 失败残留的
build 目录会让 fullclean 护栏拒绝工作，需 rm -rf build。
Impact: ch1 排坑主素材（两轨都是真实输出）；ch5 镜像产物来自 hello-s3；
Non-goals 维持（不做双版本教程化，仅记录事实与可行路径）。

## KD-6: 触摸控制器型号——外部资料与 BSP 源码矛盾 — OPEN 2026-08-26

Phenomenon: 网络评测（CircuitDigest 等）称 BOX-3 触摸为 FT6336；但 BSP
v1.1.3 源码（espressif\_\_esp-box-3，v5.1.5 构建下载的 managed_components）
只探测 GT911（0x5D/0x14）与 TT21100（0x24），无 FT6336 字样。
Root cause: 早期事实清单来自二手网络资料，未经源码核实即写入索引与
多个写作任务书（ch1/ch2/ch9/ch10/ch14/ch15 受影响）。
Decision: 以 BSP 源码为准——索引芯片表改为「GT911/TT21100 双探测，
待第九章 I2C 扫描定案」；FT6336 说法保留为「未获源码支持」的历史注记；
已在跑 agent 逐一推送更正。
Impact: 系列索引芯片表；ch2 复核（成稿时用了 FT6336）；真机到货后
I2C 扫描 + 触摸读点实验定案后关闭本条。

## KD-7: PSRAM 官方文档矛盾 + PMOD 描述符疑点 — OPEN 2026-08-26

Phenomenon: ① esp-box 仓库硬件文档（Zephyr 板文档/BSP README）称 BOX-3
为 16MB Octal PSRAM，与模组命名 N16R8V（R8=8MB）矛盾；② 本地 bsp 层
esp32_bsp_board.c 的 PMOD 描述符疑似宏名互换（.PMOD1 填 PMOD2_IO\* 宏，
L22-31 vs L62-63）。
Root cause: ① 官方文档抄写错误（存疑，esp.com 产品页口径待查）；
② 或为上游 bug，或 DOCK 丝印编号与宏名相反（未对照原理图）。
Decision: 系列以 N16R8V=8MB 为准，ch2 已将矛盾本身写成教学点；PMOD
疑点保留在 ch14 待核对段。真机定案路径：boot log 的 PSRAM 行 + DOCK
原理图（hardware/SCH_ESP32-S3-BOX-3_V1.0/）。
补充（ch15 取证）：屏幕控制器同样存在批次双探测——BSP 面板初始化双路径
（esp-box-3.c:404-409），TT21100 触摸分支对应 ST7789+mirror（:487-535），
即 ILI9342C/ST7789 与 GT911/TT21100 可能按模组批次配对出现。真机定案时
一并记录屏幕控制器型号。
Impact: ch2/ch14 待核对段；ch15 注脚；真机验证清单新增两项（含屏幕型号）。

## KD-2: GitHub 直连下载工具链失败 — SUPERSEDED by KD-3 2026-08-26

Phenomenon: install.sh 下载 xtensa-esp-elf-gdb 等 tar 包时连续
`SSL: UNEXPECTED_EOF_WHILE_READING`，重试耗尽；同机 git clone github 却正常。
Root cause: 国内网络对 github release 资产域名（objects.githubusercontent.com）
的 TLS 连接被干扰；git 通道与 release 资产通道劫持策略不同。
Decision: 用乐鑫官方镜像 `IDF_GITHUB_ASSETS=dl.ci.espressif.com` +
清华 pip 镜像 `IDF_PIP_INDEX_URL` 写入安装 shim。不引入第三方代理。
Impact: ch1/ch3 的环境章节记录该排坑；shim 位于 ~/esp/shims/setup-toolchain.sh。

## KD-3: 下载失败真凶是沙箱网络策略，非 GFW — RESOLVED 2026-08-26

Phenomenon: 沙箱内 python urllib 对 github.com 与 dl.ci.espressif.com 均报
`SSL: UNEXPECTED_EOF_WHILE_READING`；非沙箱 curl 对 github release 资产返回
206 正常；dl.ci.espressif.com 非沙箱也 TLS 失败（其 CDN 节点故障）。
Root cause: Bash 默认沙箱掐断 python 直连 TLS；KD-2 误诊为 GFW。
Decision: 安装/构建一律通过 shim 脚本 + 非沙箱执行，github 直连；
pip 保留清华镜像。KD-2 的 IDF_GITHUB_ASSETS 方案作废。
Impact: ch1 排坑记录按此为准；后续 idf.py 构建（含 managed_components
下载 components.espressif.com）同样需要非沙箱网络。

## KD-4: 大文件下载中途掐断 + idf_tools 无断点续传 — RESOLVED 2026-08-26

Phenomenon: 非沙箱下 gdb 包（42MB）一次成功，xtensa-esp-elf 主工具链
（180MB）下到 69MB 处连接被掐（retrieval incomplete），重试又 SSL EOF；
idf_tools.py 每次重试从头下载，永不收敛。
Root cause: 出口网络对 github 资产的大流量传输随机掐断（小文件可过、
大文件必断），且 idf_tools 下载器无 Range 续传。
Decision: 用 curl `-C -` 循环续传把全部工具包预下载到 ~/.espressif/dist/
（idf_tools 检测到同名包即跳过下载，仅做 sha256 校验与解压）。半成品
.tmp 文件改名后续传利用。shim: ~/esp/shims/prefetch-tools.sh。
Impact: ch1 环境章节的核心排坑素材；同样适用于任何大文件拉取场景。

## KD-5: create-project 无 --target 选项 + 子模块缺失 — OPEN 2026-08-26

Phenomenon: ① `idf.py create-project --target esp32s3 hello-s3` 报
`No such option: --target`（click 层拒绝，工程未创建）；
② 修正为 create + set-target 后，cmake 报 mbedtls include 目录不存在——
浅克隆的 esp-idf 有子模块目录为空（mbedtls 等 9 个状态 `+`）。
Root cause: ① v6 的 create-project 子命令本身不接收 --target（FreeRTOS
系列 ch1/8/10/11/12/18/19/21/22/23 共 10 处同款写法全部踩中）；
② 大仓浅克隆时子模块递归检出被网络中断打断，目录已注册但内容未落盘。
Decision: ① 正确姿势 = `idf.py create-project N && cd N && idf.py set-target esp32s3`
（写入 ch1/ch3）；FreeRTOS 系列 10 处待批量修正（记入本 KD，未完成前不算闭环）。
② 构建前 `git submodule update --init --recursive` 补齐（shim:
~/esp/shims/fix-submodules-and-build.sh）。
Impact: ch1/ch3 命令表；freertos 系列批量勘误（待办）。

## KD-8: espressif pcap 参考组件的位置与字节序陷阱 — RESOLVED 2026-08-27

Phenomenon: ① 注册表指认 espressif/pcap 属 esp-protocols，但 esp-protocols
全历史（2149 commit）无 components/pcap；② 参考实现的 little_endian
标志是字节序 bug——LE 常量 0xD4C3B2A1 以 native 写出反而产出 BE 文件。
Root cause: ① 组件真身在 espressif/idf-extra-components monorepo
（registry 元数据与仓库实况脱节）；② 其标志按「魔数字面值」而非
「文件字节序」设计，IDF 官方 simple_sniffer 示例走默认路径才正确。
Decision: pcapx 显式逐字节小端序列化（magic 0xa1b2c3d4，文件字节
d4 c3 b2 a1，与官方正确路径等价），不引入 little_endian 类标志；
参考实现截断支持缺失（恒 caplen==origlen）由本模块补齐。
Impact: practice/pcapx/src/pcapx_core.c 文件头注释；S4 文章素材。

## KD-9: QEMU xtensa semihosting 是 SIMCALL+ISS 号表，与 IDF/OpenOCD 通路互斥 — RESOLVED 2026-08-27

Phenomenon: pcapx 半托管 sink 在带 `-semihosting` 的 QEMU 里 attach 必失败：
`esp_semihost: OpenOCD is not connected!` → `esp_vfs_semihost_register()` 返回
ESP_ERR_NOT_SUPPORTED。手试 IDF 的 `break 1,14`+ARM 号（`xtensa/semihosting.h`
`semihosting_call_noerrno`）直接 Guru Meditation "BREAK instr"。
Root cause: IDF `esp_vfs_semihost` 硬依赖 `esp_cpu_dbgr_is_attached()`（读 DSRSET
bit0，OpenOCD attach 才置位），QEMU 不模拟 OCD attach；QEMU 实际拦截 **SIMCALL
指令 + Xtensa ISS 调用号**（exit=1/read=3/write=4/open=5/close=6/lseek=19，
a3..a6 传参、a2 返回、a3 errno），实读 espressif/qemu `target/xtensa/xtensa-semi.c`
确认。IDF `openocd_semihosting.h` 注释早已写明两约定 "not compatible"。
另有两个二级坑：① QEMU 把 open 的 flags **原样透传宿主** `open()`，guest newlib
`O_CREAT=0x200/O_TRUNC=0x400` 与宿主 Linux x86_64（0x40/0x200）位定义互换错位，
必须用显式常数 0x241；② 十六进制手算 `1|0x100|0x200=0x301` 漏 O_CREAT（正确
0x241），ENOENT 排障绕了一轮。
Decision: pcapx_sink_semihost 在 register 返回 NOT_SUPPORTED 时退化为 raw
SIMCALL 直连（Kconfig `PCAPX_SEMIHOST_SIMCALL_FALLBACK` 默认 y；真机无 OpenOCD
时 SIMCALL 是 illegal instruction，RISC-V 构建自动剔除 fallback，help 文本明示）。
Impact: practice/pcapx/src/pcapx_sink_semihost.c（QEMU 直连模式整节注释）；
lwip 系列 ch23/调试工具章素材；S4 文章「半托管」一节。

## KD-10: pcapx tap 直写环漏加 prefix 偏移——垃圾 caplen 连环踩堆 — RESOLVED 2026-08-27

Phenomenon: S3 集成首跑必崩，症状随机三联征：TLSF `block_locate_free` assert
（RX 任务 malloc）、Core1 InstrFetchProhibited（A0=0 跳 NULL）、Double
exception（异常入口二次异常）。换 RAM sink 排除 semihost 因素、加 RX 任务栈到
8192 无效后，用 tap/writer 双侧指纹日志分层二分（L1 计数/L2 +timer/L3a 写环
不唤醒/L4a 出环不写 sink）定位：writer 首帧读出的「元数据」是
`ffffffffffff 525400123456`——以太网帧头（广播目的 MAC+QEMU 源 MAC）。
Root cause: `pcapx_core.c` tap 写环时帧数据起点 `off = pos % ring_size` 漏加
12B prefix，帧头覆盖时间戳/长度元数据且整体错位；writer 解析出垃圾 caplen
（≤65535）→ `s_tail = pos+12+caplen` 越过 `s_head` → `used = head-tail` 无符号
下溢成巨值 → 容量判断恒过 → 后续帧按最长 64KB 越界写环，踩相邻堆块。
Decision: 修复一行 `off = (pos + PCAPX_RING_PREFIX) % s_ring_size`（回卷双段
写不变）。诊断方法论沉淀：多任务随机崩溃先做「双侧指纹日志 + 执行段分层闸」
二分，比栈/backtrace 猜测快（本例 5 轮构建收敛）。
Impact: practice/pcapx/src/pcapx_core.c（含修复注释）；S1 切片的教训——
「环不变式」类代码必须有跨生产者/消费者的端到端集成测试，单侧单测测不出
错位；S4 文章排障素材。

## KD-11: QEMU 下 vTaskDelay 做不出 writer 背压，DROP 实验用 busy-wait — RESOLVED 2026-08-27

Phenomenon: 丢包账目实验按直觉用「sink write 里 vTaskDelay(2ms)」压慢 writer，
500 背靠背帧竟然 0 drop（ring_high_wm 仅 684/2048），且时间线显示 2003 次
「2ms delay」在 ~1.1s 内完成——delay 没有形成有效背压。
Root cause: QEMU 的时间与调度语义偏软（vTaskDelay 让出 CPU 后 tap 侧高优先
任务填环 + 唤醒 notify 的交互在仿真下不构成稳定积压），与真机时序不可比
（Batch4 已证 QEMU 吞吐受宿主负载 ±50%）。
Decision: 实验性 sink 改 busy-wait（esp_timer_get_time 自旋 2ms）：writer
（prio 17）稳定占住自己的时间片，tcpip(18) 仍可抢占入环——出环速率被确定性
钉死 ~500 帧/s，环稳定打满（high_wm 1976/2048，DROP cnt 到 896）。
Impact: practice/lwip-pcapx-lab 的 slow_sink；后续一切「QEMU 下构造时序压力」
的实验统一用自旋不用 sleep；S4 文章实验节。
