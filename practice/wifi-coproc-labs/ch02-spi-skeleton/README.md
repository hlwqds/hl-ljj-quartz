# ch02-spi-skeleton —— SPI 链路两侧骨架（三重编译验证）

[[ch02-spi-link|第二章：SPI 全双工链路]] 的板级骨架：**f429/spi_master.c**（寄存器级
主机：Mode0 配置、CS 包裹、512B 交换、DRDY 的 EXTI 路径与本端直发路径）与
**esp32s3/spi_slave_task.c**（IDF `spi_slave` 任务：队列挂缓冲、post 回调维护 DRDY、
IDLE 填充）。按套件 SPEC §2 的诚实性规则做**三重验证**（真机点火时只换真头文件与
真引脚）：

| 验证          | 命令                                                                                | 结果                                                       |
| ------------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| F429 板级编译 | `zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m4 -O2 -c f429/spi_master.c` | ✓ 过编译器                                                 |
| F429 逻辑用例 | `zig cc -DHOST_TEST -o host_test f429/host_test.c f429/spi_master.c && ./host_test` | 8/8 PASS（CS 包裹顺序、双发起路径、IDLE 填充、空闲不空转） |
| S3 API 形状   | `zig cc -I esp32s3/stub -c esp32s3/spi_slave_task.c`                                | ✓（桩头只查形状不仿真，真机待板）                          |

## 真机点火清单

1. 按系列 ch01/04 的审计表填两侧引脚（F429 规避 RMII 的 PA7；Korvo-1 避开音频/LCD 住户）；
2. `spi_master.c` 的寄存器偏移换成实际外设基址（位段命名已对齐 RM0090）；
3. S3 侧删除 stub include 路径回到真 IDF 头，`idf.py build` 刷机；
4. 跑 ch02 §2.5 的三层回环（字节序列 → 事件路径 → 时钟爬坡）。

五条排错实录（寄存器名跨目标、双发起路径语义、API 指针层级、观测缓冲容量、
手算常数）见 `run.log`。
