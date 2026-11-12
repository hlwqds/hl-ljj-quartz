# Zig × ESP32-S31 实验套件

对应系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
构建契约：[SPEC.md](SPEC.md)

本目录是系列章节的可构建工程集合。当前第 1–15 章已落地，且 ch01–ch06、ch09–ch15 已在 ESP32-S31 CoreBoard 上实测（ch07/ch08 部分通过，详见 `BRINGUP-2026-11-12.md`）。

## 工程清单

| 工程                                   | 所属章节                                                                    | 模板                             | 状态                                | 入口                                                     |
| -------------------------------------- | --------------------------------------------------------------------------- | -------------------------------- | ----------------------------------- | -------------------------------------------------------- |
| `ch01-board-id`                        | [[ch01-goal-boundary-hardware\|第一章：目标、边界与硬件鉴定]]               | 无（主机侧清单）                 | 真机通过                            | [README](ch01-board-id/README.md)                        |
| `ch02-hello`                           | [[ch02-toolchain-first-image\|第二章：工具链与第一个可烧录镜像]]            | A（IDF 托管 Zig 静态库）         | 真机通过                            | [README](ch02-hello/README.md)                           |
| `ch03-image-inspect`                   | [[ch03-boot-image-partition\|第三章：启动链、镜像格式与分区]]               | 主机（Zig 解析器）               | 真机对拍通过                        | [README](ch03-image-inspect/README.md)                   |
| `ch04-linker-layout`                   | [[ch04-linker-memory-layout\|第四章：链接脚本与内存布局]]                   | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch04-linker-layout/README.md)                   |
| `ch05-clock-reset-wdt`                 | [[ch05-clock-reset-watchdog\|第五章：时钟、复位与看门狗]]                   | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch05-clock-reset-wdt/README.md)                 |
| `ch06-gpio-uart-log`                   | [[ch06-gpio-uart-logging-panic\|第六章：GPIO、UART、日志与 panic]]          | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch06-gpio-uart-log/README.md)                   |
| `ch07-interrupts-clic`                 | [[ch07-interrupts-exceptions-clic\|第七章：中断、异常与 CLIC]]              | B（纯 Zig ELF + IDF bootloader） | 部分实测（中断未投递）              | [README](ch07-interrupts-clic/README.md)                 |
| `ch08-timers-dma`                      | [[ch08-timers-dma-precision\|第八章：定时器、DMA 与精确时序]]               | B（纯 Zig ELF + IDF bootloader） | 部分实测（DMA 不匹配）              | [README](ch08-timers-dma/README.md)                      |
| `ch09-flash-partition-nvs`             | [[ch09-spi-flash-partition-nvs\|第九章：SPI Flash、分区与 NVS 存储]]        | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch09-flash-partition-nvs/README.md)             |
| `ch10-context-switch-scheduler`        | [[ch10-context-switch-cooperative-scheduler\|第十章：上下文切换与协作调度]] | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch10-context-switch-scheduler/README.md)        |
| `ch11-preemptive-scheduler`            | [[ch11-preemptive-scheduler-tcb-tick\|第十一章：抢占调度、TCB 与 tick]]     | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch11-preemptive-scheduler/README.md)            |
| `ch12-sync-primitives-ipc`             | [[ch12-sync-primitives-ipc\|第十二章：同步原语与 IPC]]                      | B（纯 Zig ELF + IDF bootloader） | 部分实测（pi 阶段未跑完）           | [README](ch12-sync-primitives-ipc/README.md)             |
| `ch13-heap-stack-caps`                 | [[ch13-heap-stack-caps\|第十三章：堆、栈保护与内存 caps]]                   | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch13-heap-stack-caps/README.md)                 |
| `ch14-dual-core-smp-ipi`               | [[ch14-dual-core-smp-ipi\|第十四章：双核 SMP 与 IPI]]                       | B（纯 Zig ELF + IDF bootloader） | 真机通过                            | [README](ch14-dual-core-smp-ipi/README.md)               |
| `ch15-observability-testing-stability` | [[ch15-observability-testing-stability\|第十五章：可观测性、测试与稳定性]]  | B（纯 Zig ELF + IDF bootloader） | 真机通过（8/8）                     | [README](ch15-observability-testing-stability/README.md) |
| `ch16-stack-architecture-zero-copy`    | [[ch16-stack-architecture-zero-copy\|第十六章：协议栈架构、缓冲与零拷贝]]   | B（纯 Zig ELF + IDF bootloader） | 真机通过（主机 55 测试 + 板侧自检） | [README](ch16-stack-architecture-zero-copy/README.md)    |
| `ch17-ethernet-mac-phy-driver`         | [[ch17-ethernet-mac-phy-driver\|第十七章：以太网 MAC/PHY 驱动]]             | B（纯 Zig ELF + IDF bootloader） | 部分实测（MAC 读通；DMA 复位超时）  | [README](ch17-ethernet-mac-phy-driver/README.md)         |

## 快速入口

1. **板卡鉴定与 16 MB 全片备份**：按 [`ch01-board-id/README.md`](ch01-board-id/README.md) 执行
   `chip-id` / `flash-id` / `read-mac` / `read-flash`，把原始输出与 SHA-256 记进
   `board-id.md`。只读阶段，不做任何写操作。
2. **第一个可烧录镜像**：按 [`ch02-hello/README.md`](ch02-hello/README.md) 构建、烧录、
   监视。IDF v6.1 的 `esp32s31` 是 **preview target**，统一用：

   ```bash
   idf.py --preview set-target esp32s31
   idf.py build
   idf.py -p <PORT> flash monitor
   ```

   `--preview` 是 `idf.py` 的全局选项，必须放在子命令之前；v6.1 正式版转正后可省略。
   本仓已有 S31 实机基线：[[onvif-deep-dive|ONVIF 深度解析系列]]的
   [[ch11-esp32s31-lab-plan|第十一章]]与 `practice/onvif-labs/SPEC.md`。

3. **镜像/分区解析（主机侧）**：进入 `ch03-image-inspect/`，用
   `zig build run -- <app.bin|partition-table.bin>` 读取字段；与 `esptool image-info`
   的对拍待真机镜像。
4. **形态 B（纯 Zig ELF + IDF bootloader）**：进入 `ch04-linker-layout/`，按 README
   先 `zig build`，再 `esptool elf2image`，最后 `sh tools/flash.sh <PORT>`；`app_desc`
   必须位于段 #0 开头，烧录前确认 `flash_args` 已生成。

## 约定

- **只提交源码**：`.zig`、`.c`、`.h`、`CMakeLists.txt`、`sdkconfig.defaults`、链接脚本、
  `README.md`、真实 `run.log`。生成物（`.zig-cache/`、`zig-out/`、`build*/`、
  `managed_components/`、`sdkconfig`）由仓库 `.gitignore` 统一忽略。
- **不伪造日志**：尚未上机的工程没有 `run.log`，README 写“run.log 待真机回填”；真机跑通
  后回填原始串口输出，超 1 MB 按 SPEC §6 截断。
- **不引入 managed component**：依赖只允许 IDF 树内组件或本仓相对路径。
- **代码浏览**：收录规则已在 `scripts/gen-code-site.mjs` 登记；本批已重新生成，
  正文/README 里的 `/static/code/#/zig-esp32-s31/<工程>/<文件>` 深链可用。

## 状态

| 项                 | 状态                                                         |
| ------------------ | ------------------------------------------------------------ |
| 第 1–15 章正文     | 已落地；ch01–ch06、ch09–ch15 真机通过（ch07/ch08 部分）      |
| ch01-board-id      | 命令清单与记录模板已落地；实机输出待回填                     |
| ch02-hello         | 模板 A 工程已落地；真机 `hello s31` + 每秒 `tick` 通过       |
| ch03-image-inspect | 与 `esptool image-info` 逐字段对拍通过（186 832 B 镜像）     |
| ch04–ch15          | 模板 B 工程已落地；除 ch07/ch08 外均已真机跑通（见上表状态） |
| `run.log`          | 均未生成（不伪造；真机回填）                                 |
