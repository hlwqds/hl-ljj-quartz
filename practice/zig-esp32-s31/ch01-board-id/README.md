# ch01-board-id — ESP32-S31 板卡鉴定与 16 MB 全片备份

第一章配套实验。目标只有一个：**在写第一行固件之前，证明你手上的板子确实是 ESP32-S31，并把它的出厂状态完整备份下来**。本章不做任何写操作；只读命令之外一律不执行。

对应文章：[[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]

> [!warning] 全部硬件步骤待真机验证
> 本目录只提供命令与判据，不含任何运行输出。所有涉及真机的步骤都按「待真机验证」处理：执行后把**原始输出**贴进 `board-id.md`，不要改写、不要凭记忆补全。esptool 子命令名与参数以 esptool 5.2+ `--help` 为准。

## 目的

产出一份可复查的板卡身份档案，包含：

1. 芯片型号与修订号（确认是 ESP32-S31，不是 S3 或经典 ESP32）；
2. Flash 厂商/设备 ID 与实际容量（应为 16 MB）；
3. 出厂 MAC；
4. 16 MB 全片备份文件及其 SHA-256；
5. ROM 启动日志原文（strap 值、启动模式）。

这份档案是后续所有章节的回滚基线与排障参照：任何"烧坏了/不启动"，先回查这里。

## 前置条件

| 项       | 要求                                                               |
| -------- | ------------------------------------------------------------------ |
| 板卡     | ESP32-S31-Function-CoreBoard-1（模组 ESP32-S31-WROOM-3，N16R16V）  |
| 主机     | Linux / macOS / Windows 均可，能识别串口（`/dev/ttyACM*`、`COMx`） |
| Python   | 3.10+，可 `pip install`                                            |
| esptool  | ≥ 5.2（S31 支持自 5.2 起）                                         |
| 串口工具 | `idf.py monitor`、`minicom`、`picocom` 或任意 115200 8N1 终端      |
| 线材     | 两根 USB-C：一根供电 + UART 控制台，一根接 USB Serial/JTAG（可选） |
| 磁盘     | 至少 16 MB 空闲（备份文件大小恰为 16 MB）                          |

安装并确认版本：

```bash
python -m pip install -U "esptool>=5.2"
esptool version
```

判据：输出 ≥ 5.2。若系统里同时存在 IDF venv 的 esptool，注意 `which esptool` 解析到哪一个，整个实验固定用同一个。

> [!note] 两个 USB 口不要混
> 板上同时有 **USB-to-UART**（接 UART0，GPIO58/59，用于控制台日志）与 **USB Serial/JTAG**（用于烧录、OpenOCD/GDB，也能当控制台）。烧录走哪个口，`-p` 就填哪个口的设备名；抓 ROM 日志要走 UART0 那个口。

## 步骤 1：识别芯片

```bash
esptool -p <PORT> --chip esp32s31 chip-id
```

「待真机验证」。

- `<PORT>` 换成实际设备名，例如 Linux `-p /dev/ttyACM0`、Windows `-p COM7`。
- 连上后 esptool 会先打印检测到的芯片类型、MAC 与 stub 上传过程，再输出芯片标识。
- 若你的 esptool 版本里子命令名不同，执行 `esptool --help` 查看当前注册的命令；本书统一用 v5 的连字符写法。

记录：芯片型号、修订号、原始输出（整段）。

## 步骤 2：读 Flash ID 与 MAC

```bash
esptool -p <PORT> --chip esp32s31 flash-id
esptool -p <PORT> --chip esp32s31 read-mac
```

「待真机验证」。

判据：

- `flash-id` 输出厂商 ID、设备 ID 与检测容量；容量应为 **16 MB**，与模组丝印 N16R16V 一致。
- `read-mac` 输出出厂 MAC，应唯一且稳定（重跑一次结果相同）。

记录：厂商/设备 ID、容量、MAC、原始输出。

## 步骤 3：16 MB 全片备份

```bash
esptool -p <PORT> --chip esp32s31 -b 460800 read-flash 0 0x1000000 s31-factory-16mb.bin
```

「待真机验证」。`0x1000000` = 16 MiB。读完后立刻校验：

```bash
sha256sum s31-factory-16mb.bin          # Linux / macOS
certutil -hashfile s31-factory-16mb.bin SHA256   # Windows
```

判据：

- 文件大小恰为 16 777 216 字节；
- SHA-256 记录进 `board-id.md`；
- 备份文件**不要**提交进仓库（体积大且含出厂校准数据），只提交摘要与记录。

需要恢复时（确认过后果再执行）：

```bash
esptool -p <PORT> --chip esp32s31 write-flash 0x0 s31-factory-16mb.bin
```

> [!warning] 顺序纪律
> 备份没落盘、SHA-256 没记录之前，不做任何擦除或烧录。这一步是整个系列唯一"不可跳过"的操作。

## 步骤 4：记录 ROM 日志

1. 用串口工具连 **UART0**（GPIO58/59，板载 USB-UART 桥），先按 115200 8N1 打开（ROM 默认值；乱码则依次试常见波特率）；
2. 打开串口后按一下复位键（EN），或重新插拔供电；
3. 抓取 ROM 打印的启动日志，直到进入应用或停在下载模式。

「待真机验证」。关注：

- `boot:0xNN` 之类的 strap 采样值（解码与启动模式判断是第三章的内容）；
- Flash 模式/大小/频率的 ROM 侧判断；
- 若一直停在 `waiting for download`，说明 BOOT 键被按住或 strap 电平不对。

把日志**原文**贴进 `board-id.md`，不要只写结论。

## 预期字段（记录模板）

在实验目录新建 `board-id.md`，按下表填写。模板里的"待填"必须由实测值替换；万一某项无法测（例如接口不可用），明确写"未测"，不要猜：

| 字段               | 记录值                                                        |
| ------------------ | ------------------------------------------------------------- |
| 板卡 / 模组丝印    | ESP32-S31-Function-CoreBoard-1 / ESP32-S31-WROOM-3（N16R16V） |
| 芯片型号与修订     | 待填                                                          |
| Flash 厂商 / 设备  | 待填                                                          |
| Flash 容量         | 待填（期望 16 MB）                                            |
| 出厂 MAC           | 待填                                                          |
| ROM 日志首行       | 待填（原文）                                                  |
| 备份文件           | `s31-factory-16mb.bin`                                        |
| 备份字节数         | 待填（期望 16777216）                                         |
| 备份 SHA-256       | 待填                                                          |
| 主机 / 端口 / 日期 | 待填（例如 Windows COM7，2026-11-12）                         |

## 排障

| 现象                                   | 常见原因                                          | 处理                                                                             |
| -------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------- |
| 找不到串口                             | 线材只供电、驱动缺失、USB 口选错                  | 换数据线；确认接的是哪个 USB 口；Linux 看 `dmesg`，Windows 看设备管理器          |
| 连接超时 / `Failed to connect`         | 没进下载模式；ModemManager 抢占；monitor 占用端口 | 按住 BOOT 再点 EN 进下载模式；Linux 停 `ModemManager`；关闭占用端口的 monitor    |
| 一直停在 `waiting for download`        | BOOT（GPIO61）被按住或 strap 电平异常             | 松开 BOOT 后复位；确认没有外部电路拉低该引脚                                     |
| esptool 读到 `ESP32-S3`                | 板子/模组不是 S31，或拿错板                       | **停止**。S3 是 Xtensa，工具链、启动链、ABI 全不同，本系列命令不适用；记录并换板 |
| esptool 读到经典 `ESP32`               | 同上，且架构更老                                  | 停止并记录，联系供板方；不要硬凑                                                 |
| 读到 S31 但容量不是 16 MB              | 模组型号不符（如 N8R8）                           | 记录实际容量；后续备份长度与分区按实际值调整，档案里标注偏差                     |
| `-p` 指向 USB Serial/JTAG 却抓不到日志 | 该口不是 UART0 控制台                             | 抓日志换 UART0 口；烧录可以用 USB Serial/JTAG                                    |
| 备份 SHA-256 与记录不一致              | 读取中断、供电不稳、Flash 有坏块                  | 重读一次并比对；两次不一致则降低波特率重试，仍不一致就停止后续烧录               |

## 验收清单

- [ ] esptool 版本 ≥ 5.2，且全程使用同一个可执行文件
- [ ] `chip-id` 读到 ESP32-S31，修订号已记录
- [ ] `flash-id` 读到 16 MB，与模组丝印一致
- [ ] `read-mac` 读出 MAC，重跑结果一致
- [ ] 16 MB 备份已落盘，字节数与 SHA-256 已记录
- [ ] ROM 启动日志原文已存档，strap 值可指出
- [ ] `board-id.md` 填完，空值明确写"未测"
- [ ] 未执行任何擦除/写入操作

全部打勾后回到 [[ch01-goal-boundary-hardware|第一章]]，进入第二章的工具链与第一个可烧录镜像。
