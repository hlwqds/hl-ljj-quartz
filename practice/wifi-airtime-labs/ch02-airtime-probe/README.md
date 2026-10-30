# ch02-airtime-probe —— iw survey/station 文本解析：先把 airtime 看见

[[ch02-measuring-airtime|第二章：先看见再动手]] 的配套实验。回答两个问题：

1. **这个信道的 airtime 到底被用掉了多少？**——解析 `iw dev wlan0 survey dump`，
   算信道占用率 `busy/active` 与 rx/tx 各占份额，`busy% > 70%` 打印「饱和预警」；
2. **每个站点的链路质量如何？**——解析 `iw dev wlan0 station dump`，算重传率
   `tx_retries/tx_packets`，`> 30%` 打印「重传偏高」。

C11 零依赖单文件（`airtime_probe.c`），编译器 `zig cc`，无任何第三方库。

## 文件组成

| 文件                          | 作用                                                                         |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `airtime_probe.c`             | 解析器 + 自检 main：对 fixtures 解析并与源码内编码的期望值逐项比对 PASS/FAIL |
| `fixtures/survey_sample.txt`  | **构造样例**（按 iw survey dump 真实输出布局，2 个信道块，其中 1 块在用）    |
| `fixtures/station_sample.txt` | **构造样例**（按 iw station dump 布局，2 个站点，含 signal avg/TID 干扰行）  |
| `collect.sh`                  | 真机采集脚本（树莓派/Linux，**待真机**）：循环抓两类 dump，加时间戳追加 CSV  |
| `run.log`                     | `./airtime_probe` 自检的真实输出（34/34 PASS）                               |

> [!NOTE]
> fixtures 是**按 iw 输出布局构造的样例**（字段与格式忠实于 iw 真实打印，数值为
> 设计值，供解析器自检与阈值验证）；真机数据一律由 `collect.sh` 现场采集，不入库。

## 解析字段表

**survey 侧**（`iw dev wlan0 survey dump`，每个信道一条记录，iw 逐记录打印
`Survey results for wlan0:` 头）：

| iw 输出行                     | 解析为       | 说明                                          |
| ----------------------------- | ------------ | --------------------------------------------- |
| `frequency:`                  | `freq_mhz`   | 如 `2412 MHz`                                 |
| `in use:`                     | `in_use`     | iw 只对当前工作信道打印 `yes`；缺行视为非在用 |
| `noise:`                      | `noise_dbm`  | 底噪                                          |
| `channel active time:`        | `active_us`  | 采样窗内信道总活跃时间（分母）                |
| `channel busy time:`          | `busy_us`    | 忙时间（含本机 rx/tx 与他人流量/干扰）        |
| `channel receive time:`       | `rx_us`      | 本机接收占用                                  |
| `channel transmit time:`      | `tx_us`      | 本机发送占用                                  |
| `extended channel busy time:` | `extbusy_us` | 扩展信道忙时间（HT40 副信道）                 |

**station 侧**（`iw dev wlan0 station dump`，每个关联站点一段）：

| iw 输出行       | 解析为            | 说明                                      |
| --------------- | ----------------- | ----------------------------------------- |
| `Station <MAC>` | `mac`             | 站点 MAC（`(on wlan0)` 里取接口名）       |
| `signal:`       | `signal_dbm`      | 瞬时信号强度（`signal avg:` 是另一标签）  |
| `tx packets:`   | `tx_packets`      | 发送包数（重传率分母）                    |
| `tx bytes:`     | `tx_bytes`        | 发送字节数                                |
| `tx retries:`   | `tx_retries`      | 重传次数（重传率分子）                    |
| `tx failed:`    | `tx_failed`       | 发送失败数                                |
| `tx bitrate:`   | `tx_bitrate_mbps` | 发送速率，kBit/s/GBit/s 自动换算成 Mbit/s |

其余行（`TID 00:`、`authorized:`、`WMM/wme:` 等）按未知标签忽略——样例里特意放了
`signal avg:` 与 `TID` 行，验证干扰行不会误匹配。

## 单位公约与判定公式

内核 nl80211 的 survey 时间字段语义为 **µs**，`iw` 打印时已除以 1000 显示 **ms**。
解析器识别行尾单位（`ms`×1000 / `us`、`µs`×1 / `s`×1000000 / 无单位按 µs）统一归一到
µs 后再算比例——**比例与单位无关，绝对值必须归一**（自检里专门有
`764000 ms → 764000000 us` 一项验证乘子）。

| 指标      | 公式                          | 判定（阈值在源码顶部 `#define`）           |
| --------- | ----------------------------- | ------------------------------------------ |
| 信道占用  | `busy% = busy/active × 100`   | `> 70%`（`BUSY_SATURATION_PCT`）→ 饱和预警 |
| rx 份额   | `rx% = rx/active × 100`       | —                                          |
| tx 份额   | `tx% = tx/active × 100`       | —                                          |
| 其余 busy | `(busy-rx-tx)/active × 100`   | 他人 BSS/干扰占用的信道时间                |
| 重传率    | `tx_retries/tx_packets × 100` | `> 30%`（`RETRY_HIGH_PCT`）→ 重传偏高      |

`active` 缺失或为 0 时该块不计算占比（打印提示），不会除零。

## 复现（宿主，本仓 run.log 即此输出）

```bash
cd practice/wifi-airtime-labs/ch02-airtime-probe
~/zig/zig cc -O2 -o airtime_probe airtime_probe.c   # 或系统 cc/gcc
./airtime_probe                                      # 自检：解析 fixtures → 34/34 PASS，退出码 0
./airtime_probe <survey.txt> [station.txt]          # 只解析打印报告（真机采集文件用）
```

自检的期望值直接编码在 `airtime_probe.c` 的 `self_test()` 里，与 fixtures 设计值
一一对应：在用信道（2412 MHz）busy 76.40%（>70 触发预警）、rx 32.10%、tx 29.80%、
其余 busy 14.50%；邻信道（2437 MHz）busy 35.00% 不触发；站 1 重传率 37.00%（>30 触发）、
站 2 重传率 7.50% 正常。

## 真机采集（树莓派/Linux，待真机）

`collect.sh`（bash）循环执行 `iw dev $IFACE survey dump` 与 `iw dev $IFACE station
dump`，加 ISO 8601 时间戳追加成 CSV（survey 每信道块一行、station 每站点一行，
`kind` 列区分，20 列 schema 见脚本头）：

```bash
sudo ./collect.sh -i wlan0 -o /home/pi/airtime.csv -t 30   # 每 30s 一轮，Ctrl-C 停止
sudo ./collect.sh -n 1 -o /home/pi/airtime.csv             # crontab 用：跑一轮即退
```

crontab 示例（脚本头部注释同款）：

```cron
*/5 * * * * /home/pi/wifi-airtime-labs/ch02-airtime-probe/collect.sh -i wlan0 -o /home/pi/airtime.csv -n 1 >> /home/pi/airtime-collect.log 2>&1
```

现场快照也可以直接喂给解析器看报告：

```bash
sudo iw dev wlan0 survey dump > /tmp/s.txt
sudo iw dev wlan0 station dump > /tmp/t.txt
./airtime_probe /tmp/s.txt /tmp/t.txt
```

> [!NOTE]
> **待真机**：`collect.sh` 尚未上真树莓派验证；在 Windows 宿主上已用 iw 桩脚本
> （PATH 注入假 `iw` 回放 fixtures）干跑 2 轮通过——CSV 8 行数据全部 20 列，
> busy_pct=76.40/35.00 与 warn=busy、retry_pct=37.00/7.50 与 warn=retry 均与
> 解析器输出一致。真机注意：iw 需要 root；树莓派基础环境（系统烧写、权限、
> 排错思路）见 [[rpi-lab|树莓派实验室]]。
