# ch20 TCP 状态机与可靠传输：把丢包变成一次重传

> 所属章节：[[ch20-tcp-state-machine-reliable-delivery|第二十章：TCP 状态机与可靠传输]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已全部跑通**：`zig build test` → `All 27 tests passed`
>   （26 个具名用例 + 根文件容器 test），2026-11-13，宿主 x86_64 / Zig 0.17.1。
> - **板侧镜像已生成**：`zig build -Dtarget=riscv32-freestanding-eabihf …` 退出 0；
>   `esptool elf2image` 打印 `Merged 2 ELF sections.`；`image-info` 的段表里
>   落在 flash 的 `DROM, IROM` 行正好两条（`0x40000020` 与 `0x40020020`）。
> - **已上板（2026-11-13）**：板侧 11 条判据全部 PASS
>   （`checks: passed=11 failed=0 total=11`，`main: verdict=pass`），
>   原始输出见 `../logs/ch20-boot.log`。
> - **证据只来自注入路径**：所有 TCP 段都是 `.bss` 里自造的字节数组，
>   没有 MAC、没有 IP 收发、没有中断。**真实链路上的握手/重传尚未验证**
>   （ch17 的以太网 DMA 仍未闭环）——这一项写成「待 ch17 闭环」，不是本章结论。

## 目的

这是形态 B 的第十五个工程（ch16=十一、ch17=十二、ch18=十三、ch19=十四），
也是 Part IV 里唯一一个**同时拥有状态、定时器和内存管理**的协议：

- 11 个状态，每条边都对应一个“当前该发什么”的判断；
- 两个时间尺度：RTO 重传（毫秒到秒）与 TIME_WAIT 的 2MSL（60 秒）；
- 三块定容内存：发送缓冲、接收缓冲、乱序重组槽——没有堆，也不许无界增长。

本章的纯逻辑全部在 `src/tcp.zig` 与 `src/checksum.zig` 里，`zig build test`
覆盖 27 项；板侧只复用同一份代码，用注入的段把 10 个场景各走一遍。

| 模块               | 覆盖内容                                                                                                                                                    |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/tcp.zig`      | 20 字节首部 + 选项（MSS/WS/SACK）编解码、seq 回绕比较、11 状态迁移、MSS 分段、RFC 6298 RTO、单段重传计时器、重复 ACK/快速重传、有界乱序重组、TIME_WAIT 2MSL |
| `src/checksum.zig` | RFC 1071 反码和、IPv4 伪首部、已知 TCP 向量 `0xeca5`、奇数字节跨片配对                                                                                      |

## 工程不做的事

- **不做拥塞控制**：没有 cwnd/ssthresh，没有慢启动与 AIMD；重复 ACK 只做一次
  快速重传。这部分留给 [[ch21-tcp-congestion-throughput|第二十一章]]。
- **不做窗口管理**：`snd_wnd` 只记录不生效；WS 选项只解析不应用，窗口恒按
  1 字节粒度理解。
- **不做 SACK**：SACK-permitted 只解析；重传永远是“从 `snd_una` 重发单段”。
- **不做真实链路**：不碰 EMAC/DMA（ch17）、不解析 IPv4/ARP（ch18）。
  自检里的段不经过任何网卡。
- **不使用堆**：所有缓冲、重组槽、自检报文都在 `.bss` 的定容对象里。
- **不等待真实的 60 秒**：TIME_WAIT 用注入的 `now_us` 判定，自检两次
  `tick()` 就跨过 2MSL。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章自检只需要串口；真实链路联调才需要网线与抓包                |

## 快速开始

```bash
# 1) 主机侧单测（不需要开发板）
zig build test

# 2) 交叉编译 + 生成应用镜像
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
. /tmp/idfenv.sh
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

# 3) 烧录（与其它章节共用一个板子时用 flock 串行化）
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
```

> [!note] 本机的 zig 调用
> 本机 `zig` 在 `LD_LIBRARY_PATH` 被污染时会加载错误的 `libc`，
> 需要在命令前加 `env -u LD_LIBRARY_PATH`（nix store 里的
> `zig-0.17.1` 二进制路径见本节上方的验证记录）。上面的三行保持
> 可移植写法，换机器/换 zig 版本时不用改命令结构。

`tools/flash.sh` 的偏移全部来自 `idf-bootstrap/build/flash_args`：
bootloader（0x2000）与分区表（0x8000）原样保留，应用行（0x10000）替换成
`zig-out/bin/app.bin`。注意 `.gitignore` 忽略了
`practice/zig-esp32-s31/**/build*/` 与 `**/sdkconfig`，所以 **fresh clone 里
没有 `idf-bootstrap/build/`**：先在本机 `idf-bootstrap/` 里执行一次
`idf.py --preview set-target esp32s31` 与 `idf.py build` 生成
`bootloader.bin`、`partition-table.bin` 与 `flash_args`，再运行上面的烧录命令。
本机工作树里这套产物已经存在（本章的上板记录就是用它烧的），不需要重跑 IDF。

## 文件职责

| 文件                 | 职责                                                  | 查看                                                                           |
| -------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------ |
| `build.zig`          | 形态 B 构建入口：Zig ELF + 主机侧单测                 | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/build.zig)          |
| `linker/s31.ld`      | 两 flash 段（irom/drom）+ `.trap_ram` + SRAM 边界断言 | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/linker/s31.ld)      |
| `src/tcp.zig`        | 段编解码、选项、seq 算术、状态机、RTO、重组           | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/tcp.zig)        |
| `src/checksum.zig`   | RFC 1071 反码和 + 伪首部 + `fillTcp`/`verifyTcp`      | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/checksum.zig)   |
| `src/selftest.zig`   | 板侧 11 条注入路径判据                                | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/selftest.zig)   |
| `src/host_tests.zig` | 主机侧测试入口（只 import tcp/checksum）              | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/host_tests.zig) |
| `src/main.zig`       | banner + selftest 编排 + verdict                      | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/main.zig)       |
| `src/start.zig`      | `_start`：关中断、设栈、关 WDT、清 bss、装 mtvec      | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/start.zig)      |
| `src/hw.zig`         | 打印/忙等/停机与 CSR 读取                             | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/hw.zig)         |
| `src/trap.zig`       | SRAM 里的 trap 入口 + panic                           | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/trap.zig)       |
| `src/log.zig`        | ROM `esp_rom_printf` 封装（栈上格式化）               | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/log.zig)        |
| `tools/flash.sh`     | 按 `flash_args` 重写应用行并烧录                      | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/tools/flash.sh)     |

[完整工程](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/)

## 与其它章节的边界

- `src/tcp.zig` 是 ch16 `headers.zig` 里 `Tcp` 结构的**超集**：那一版只做
  “20 字节首部的读写”，本章加上选项、状态机、定时器与重组。每章自带一份
  是为了单章能独立 `zig build`，不把“依赖哪一版结构”变成隐式契约。
- 本章不使用 ch16 的 `pbuf`：单段模型里“缓冲”就是一个 `[MSS]u8`，
  零拷贝链表的收益要等 ch21 的滑动窗口才体现。
- IP 首部与以太网帧由 ch17/ch18 负责；本章的 `checksum.fillTcp` 需要调用方
  传入 `src`/`dst`，这就是与 ch18 的接口。
- 真实链路上的握手/重传验收，必须等 ch17 闭环后与本章联调；在此之前，
  本章的结论只覆盖“状态机与算术”，不覆盖“网络里真的能连上”。
