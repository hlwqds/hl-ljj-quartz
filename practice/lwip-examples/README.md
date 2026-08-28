# lwIP Examples 套件（RTOS+lwIP 示例工程）

ESP32 + ESP-IDF v6.0.2 上的 RTOS+lwIP 模板级示例集：每个示例自成一个干净工程，在 QEMU
（OpenCores 网卡 + SLIRP 用户态网络）中实测构建运行，README 即文档，复制改名即可作为新
项目起点。实现契约见 [SPEC.md](SPEC.md)，调研依据见 [research/](research/)，
环境事实与陷阱速查见 [`../lwip-labs/CONVENTIONS.md`](../lwip-labs/CONVENTIONS.md)。

## 示例总表

| #   | 工程                                                  | 一句话                                                 | 端口                  | 关键实证                                                                          |
| --- | ----------------------------------------------------- | ------------------------------------------------------ | --------------------- | --------------------------------------------------------------------------------- |
| 01  | [ex01-ethernet-dhcp](ex01-ethernet-dhcp/)             | 以太网起播基线：事件序列 + DHCP + READY 行             | 无                    | START→CONNECTED→GOT_IP 全程 1.2s，10.0.2.15 到手                                  |
| 02  | [ex02-tcp-echo-server](ex02-tcp-echo-server/)         | TCP 服务端模板（accept 循环 + 三种断开路径）           | tcp::8210             | 并发连接排队语义实测；bench digest 全 PASS                                        |
| 03  | [ex03-tcp-echo-client](ex03-tcp-echo-client/)         | TCP 客户端模板 + 错误分支教学（REFUSED/TIMEOUT/RESET） | 出连 8220             | 四场景全 PASS；lwIP 下 refused 实为 ECONNRESET                                    |
| 04  | [ex04-udp-echo-bidir](ex04-udp-echo-bidir/)           | UDP 入向 hostfwd + 出向双路径回声                      | udp::8230             | 500 包 0% 丢失对账；洪水丢包归因 RX 环                                            |
| 05  | [ex05-http-server](ex05-http-server/)                 | esp_http_server 模板（/hello /info /404）              | tcp::8240→80          | keep-alive vs 非 keep-alive 延迟对照 + 5s 超时判死                                |
| 06  | [ex06-http-downloader](ex06-http-downloader/)         | HTTP 大文件下载：分块+Fletcher32+进度                  | 出连 8250             | 5MB @88.5 Mbit 双端校验一致；三种错误分支实证                                     |
| 07  | [ex07-sntp-clock](ex07-sntp-clock/)                   | SNTP 对时模板【SLIRP UDP 转发裁决】                    | UDP 8260              | **裁决：可行**。guest→10.0.2.2 UDP 落宿主 loopback 同端口                         |
| 08  | [ex08-mqtt-pubsub](ex08-mqtt-pubsub/)                 | MQTT 客户端模板（订阅/发布/LWT/重连）                  | 出连 1883             | 断连离线 outbox→复联补投全过程；LWT 双触发                                        |
| 09  | [ex09-tls-client](ex09-tls-client/)                   | TLS 客户端模板【含已知悬案逃生舱】                     | 出连 8280             | 外环悬案 9/9 复现如实记录；回环替代 4/4 通                                        |
| 10  | [ex10-ping-monitor](ex10-ping-monitor/)               | ping 监控守护（告警锁存+自动注入自愈）                 | ICMP                  | link_down 注入→告警精确=阈值×周期→自愈恢复                                        |
| 11  | [ex11-throughput-bench](ex11-throughput-bench/)       | 吞吐基准（TX/RX 双模式+旋钮变体）                      | 8290/8291             | 默认 TX 94.8/RX 89.9 Mbit；宽窗 TX +20% 达天花板 94%                              |
| 12  | [ex12-net-stats-dashboard](ex12-net-stats-dashboard/) | 观测台模板（协议计数/heap/任务表周期仪表盘）           | 纯观测                | 1 pps 自流量 → ip.recv 每帧精确 +30                                               |
| 13  | [ex13-tcp-hostlink](ex13-tcp-hostlink/)               | 双向 TCP：入向命令服务 + 出向心跳并发                  | tcp::8300 / 出连 8301 | 毫秒级命令响应与心跳同窗共存；心跳不可达 34s 服务面存活；500B 截断保护实测        |
| 14  | [ex14-perf-gym-tcp](ex14-perf-gym-tcp/)               | TCP 配置错误健身房（4 场景：症状→诊断→修复→前后数据）  | 8310/8311             | tcp_sent 漏挂 170 倍坍缩实测；小窗不发病的诚实负结果课                            |
| 15  | [ex15-perf-gym-rtos](ex15-perf-gym-rtos/)             | RTOS 调度错误健身房（倒挂/慢回调/邮箱满/栈告警）       | 自环 8320             | 四场景心跳失联指纹各异；首版栈溢出 Backtrace 现场成教学案例                       |
| 16  | [ex16-zero-copy-cases](ex16-zero-copy-cases/)         | 零拷贝优化案例集（4 案例 + IDF 边界实证）              | tcp::8330 / 出连 8331 | RX 就地解析 -18%、分段提交 -17%、流式校验内存峰值 112KiB→0；TX 强制 COPY 钉死证据 |

## 快速开始

```bash
cd practice/lwip-examples/ex01-ethernet-dhcp/tools && ./run_qemu.sh   # 零改动体验
# 或作为起点：
cp -r ex01-ethernet-dhcp my-app && cd my-app && rm -rf build sdkconfig run.log
. ~/esp/esp-idf/export.sh && idf.py set-target esp32 && idf.py build
```

需要宿主侧配合的示例（03/05/06/07/08/09/11/13）先看各自 README 的「宿主准备」节：
监听器/broker/NTP 应答器/s_server 都有单文件脚本。

## 统一约定

- 目标芯片 ESP32（QEMU 仿真），联网 = OpenCores 网卡 + SLIRP（DHCP 10.0.2.15、网关
  10.0.2.2、DNS 10.0.2.3）；全离线构建，禁止在线拉取组件。
- QEMU runner 统一去 efuse `-global` 行（偶发 NIC 不创建的坑）；日志统一 `run.log`；
  机器可读标记行 `$ $$ EXNN...` 便于自动化断言。
- 端口专用号段 8200–8299（分配表见 SPEC §4）；README 缺失、编造输出、超限日志均一票否决。
- 与系列的关系：章节实验见 [`../lwip-ch*`](../)，方法论与八批实测沉淀见 CONVENTIONS.md。
