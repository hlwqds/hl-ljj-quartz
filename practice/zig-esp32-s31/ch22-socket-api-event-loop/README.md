# ch22 Socket API 与事件循环

> 所属章节：[[ch22-socket-api-event-loop|第二十二章：Socket API 与事件循环]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已跑通**：`zig build test` → `28/28 tests passed`（27 个具名用例 +
>   根文件容器 test），2026-11-13，宿主 x86_64 / Zig 0.17.1。
> - **镜像合法**：交叉编译退出 0；`esptool elf2image` 打印
>   `Merged 2 ELF sections.`；`image-info` 里落在 flash 的 `DROM, IROM` 行
>   正好两条（`0x40000020` 与 `0x40020020`），`image-info` 的
>   `Project name: ch22-socket-api-event-loop` 与本工程一致。
> - **已上板（2026-11-13）**：板侧 12 条判据全部 PASS
>   （`checks: passed=12 failed=0 total=12`，`main: verdict=pass`），
>   原始输出见 `../logs/ch22-boot.log`。
> - **本章没有真链路结论**：ch17 的以太网驱动仍未闭环（DMA 软复位超时、
>   MDIO 扫不到 PHY，见 `../logs/ch17d-boot.log`）。板侧 socket 层收到
>   的每一段都由 `netstub` 造出来投递，事件循环的每个 tick 都由自检注入。
>   “连上服务器”“真实 socket 可用”这类断言需要 ch17 + ch20 + ch21 一起
>   上线后才能做，见章节 22.12 的判据。

## 目的

这是形态 B 的第十七个工程。它回答一个问题：**有了 TCP 状态机，应用到底
拿到什么。**

ch20 交付了“字节可靠送达”，ch21 交付了“发多快”，但两者都还只是**协议
内部的机制**。应用不能直接对着一个 `tcb` 结构体写代码——它需要一个整数
句柄、一套返回值契约、一种“同时等 N 个连接”的办法。这三样合起来就是
socket API 与事件循环，也是本章的全部内容。

| 模块                 | 覆盖内容                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------------- |
| `src/socket.zig`     | 固定上限 FD 表（8 槽）、套接字状态机、非阻塞 `accept/connect/send/recv/close`、部分读写与 EAGAIN 契约     |
| `src/event.zig`      | `poll` 式事件循环（注册+就绪集）、轮转起点公平化、相对 tick 超时轮、连接池（上限 4，拒绝/踢最旧两种策略） |
| `src/netstub.zig`    | 不依赖网卡的注入源：10 字节首部的段线格式、脚本顺序投递、FNV-1a 指纹（重放判据）                          |
| `src/selftest.zig`   | 板侧 12 条判据（对应章节 22.10 的判读顺序）                                                               |
| `src/host_tests.zig` | `zig build test` 的根：只 import 上面三个纯逻辑模块                                                       |

## 工程不做的事

- **没有 MAC/DMA、没有 IPv4、没有真实 TCP 发送队列**：链路层在 ch17（未闭环），
  IPv4 在 ch18，状态机与重传在 ch20。本章的“段”是 `netstub` 的抽象。
- **不发任何真实报文**：所有段都由脚本注入，串口不驱动网口。
- **不测真链路握手/吞吐**：所有结论标注「注入路径，非真链路」。
- **没有调度器、没有中断、没有时钟**：`mstatus.MIE = 0`，时间由 `tick`
  参数注入（章节 22.5 解释为什么不用时钟中断）。
- **不做阻塞语义**：阻塞等待需要“让出 CPU”，形态 B 没有调度器；
  本章只实现非阻塞 + 事件循环这一种组合（`Socket.nonblocking` 恒为 true）。
- **不使用堆、不使用浮点**：FD 表（8 × sizeof(Socket) ≈ 10 KiB 含收发
  缓冲）是 `.bss` 里的静态对象，主栈只有 16 KiB（`linker/s31.ld` 的
  `_stack_size = 0x4000`），把这张表放栈上会直接越过 `_stack_top`。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章自检只需要串口；不需要网线、路由器或抓包                    |

## 快速开始

前置（一次性）：`idf-bootstrap/` 里完成一次 IDF 构建，产出
`build/bootloader/bootloader.bin`、`build/partition_table/partition-table.bin`
与 `build/flash_args`（该目录按 `.gitignore:97` 的 `build*/` 规则不入库，
所以新克隆的仓库必须自己生成一次）：

```bash
cd idf-bootstrap
. ~/esp/esp-idf/export.sh
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

```bash
# 1) 主机侧单测（不需要板子）
zig build test --summary all

# 2) 交叉编译 + 转镜像（产物 zig-out/bin/app.{elf,bin}）
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
python -m esptool --chip esp32s31 elf2image --flash-mode dio \
  --flash-size 16MB --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf

# 3) 烧录（两块 agent 共用一块板时用 flock 串行）
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
```

烧完串口按 115200 8N1 打开即可看到 `check:` 行；串口抓取脚本见章节 22.10。

## 文件表

| 路径                 | 角色                                                                    | 代码浏览                                                                           |
| -------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`（三个纯逻辑模块）                  | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界符号、四条 ASSERT                  | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/main.zig)       |
| `src/socket.zig`     | FD 表、状态机、`recv/send/close`、就绪判定、部分读写                    | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/socket.zig)     |
| `src/event.zig`      | `poll` 就绪集、轮转公平、超时轮、连接池两种策略                         | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/event.zig)      |
| `src/netstub.zig`    | 段线格式（编码/解码）、脚本投递、FNV-1a 指纹                            | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/netstub.zig)    |
| `src/selftest.zig`   | 板侧 12 条判据与一行脚本指纹读数                                        | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/selftest.zig)   |
| `src/host_tests.zig` | `zig build test` 的根：只 import 纯逻辑模块                             | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/host_tests.zig) |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/log.zig)        |
| `idf-bootstrap/`     | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                | —                                                                                  |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/tools/flash.sh)     |

完整工程（入口为工程 README，可再进目录树）：[ch22-socket-api-event-loop](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/README.md)

> 表里的 `/static/code/#/…` 深链要重跑一次 `npm run code-site`
> （`scripts/gen-code-site.mjs` 的 `PROJECT_GLOBS` 已覆盖
> `practice/zig-esp32-s31/*`）之后才能打开；本批按“只动本章两个路径”的
> 约束没有改 code-site。

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF
内置 single-app-large）、没有 `components/`。生成物 `zig-out/`、
`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 不入库。

## 主机侧测试

```bash
cd practice/zig-esp32-s31/ch22-socket-api-event-loop
zig build test --summary all
zig test src/host_tests.zig        # 想立刻看到 "All 28 tests passed" 时用这个
```

> 覆盖边界：`src/host_tests.zig` 只 import `netstub.zig` / `socket.zig` /
> `event.zig`，**不编译 `src/selftest.zig`**。那 12 条板侧判据由 rv32
> 交叉编译 + 上板运行验证；28 个用例不等于“板侧判据已被主机覆盖”。

分布（27 个具名用例 + 根文件容器 test）：

| 模块          | 用例数 | 代表用例                                                                                                                                                                                   |
| ------------- | -----: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `netstub.zig` |      5 | `线格式：编码与解码往返`、`截断/未知种类/长度不符都被拒绝`、`out 太短时返回 0`、`脚本重放指纹一致`、`改动脚本后指纹必变`                                                                   |
| `socket.zig`  |     11 | `FD 表容量 8`、`关闭槽位被复用`、`SYN→syn_rcvd→ACK→established`、`FIN→close_wait→last_ack→closed`、`recv 部分读与 EOF`、`send 背压`、`EAGAIN/ENOTCONN/ECONNRESET 契约`、`backlog 丢弃计数` |
| `event.zig`   |     11 | `poll 就绪集`、`水平触发可写`、`轮转起点前进`、`就绪项超预算时截断`、`超时轮到期/取消/容量`、`池 reject_new`、`池 evict_oldest`、`accept 未完成握手时 again`                               |

## 与相邻章节的关系

| 关系         | 说明                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ |
| ch20         | **签名级依赖**：`State` 的名字（`syn_rcvd`/`established`/`close_wait`/`last_ack`）对齐，但状态迁移表是本章自己的一份实现 |
| ch21         | **签名级依赖**：本章不调用 `cong.Cwnd`；拥塞窗口在真实链路上才需要，本章的发送缓冲只有 1 KiB                             |
| ch16         | 不引用：`headers.zig` 只到 UDP，本章的段格式是 `netstub` 自己的 10 字节首部                                              |
| ch23（下一） | 依赖本章的“注册—就绪—处理”形状：TLS 握手同样是一串“下一步该读还是该写”的状态                                             |
