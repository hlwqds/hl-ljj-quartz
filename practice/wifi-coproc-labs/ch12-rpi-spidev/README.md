# ch12-rpi-spidev —— spidev 传输层 + 守护进程（协议层零改动上 Linux）

[[ch12-rpi-spidev-host|第十二章]] 的实现：**transport.h** 把传输层抽象成两个动词
（`xfer` 512B 全双工交换 + `drdy` 就绪探测）；**transport_spidev.c** 是真树莓派版
（三 ioctl、Mode0、sysfs DRDY 轮询的零依赖骨架，真机建议换 libgpiod——正文
§12.2）；**transport_fake.c** 是内存对端的假 S3（PING 应答 + DATA echo，DRDY
语义同 ch02 时序图）；**hostd.c** 是与 ch02 F429 主循环同构的事件泵。协议源文件
（cobs/crc32/framing/control）从 ch03/ch05 工程**原样拷入、零改动**——多宿主
承诺的兑现现场。

## 验证（run.log）

| 目标         | 命令                                                                                          | 结果                                                  |
| ------------ | --------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Windows 全链 | `zig cc -o test test.c hostd.c transport_fake.c control.c cobs.c crc32.c framing.c && ./test` | 5/5 PASS（PING/echo×50/460B 上限/DRDY 时序/空闲稳定） |
| Linux 真机   | `zig cc -target x86_64-linux -c transport_spidev.c hostd.c`                                   | ELF64 目标过编译器，真机待板                          |

真机点火：`dtparam=spi=on` → export DRDY 的 sysfs → 编译整个目录（去 `-DHOSTD_LINUX_MAIN`
任选）→ `./hostd /dev/spidev0.0 1000000` 进 PING 循环。排错实录（原型作用域冲突、
暂存区时序）见 run.log。
