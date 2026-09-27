# lwip_arp_ping —— 裸机 lwIP：第一声 ARP 与手搓 ping（ch21 配套）

对应章节：[[ch21-baremetal-lwip|裸机 lwIP：不带 OS 的协议栈]]（F429 裸机实验室第二十一章）。
前置工程：[[eth-mdio-probe]]（[[ch20-ethernet-emac-phy|ch20]] 的 EMAC/PHY 地基）。
系列总目录：[[f429-lab|F429 裸机实验室索引]]。

lwIP 主系列（ESP32 侧 24 章）拆的是乐鑫配好的整机；本工程把同一颗协议栈
**拆散了亲手装到裸机上**：lwIP 2.2.0 源码 vendor 在 `lwip-src/`，
`lwipopts.h` 自己裁、`ethernetif.c` 自己写（约 250 行，含 ch20 硬件初始化）、
定时器自己喂（`sys_check_timeouts()` + `sys_now()` 接 SysTick 心跳）。

> 状态：**先成文、后实跑**——固件已编译通过（`arm-none-eabi-gcc 15.2`，
> text 23KB / bss 42.8KB），tcpdump 抓包与统计实测后回填本文与章节。

## 模型：NO_SYS=1 轮询

```text
main 循环（无 OS 的全部"线程"）：
  ethernetif_poll()      # RX：描述符环 OWN 位归 CPU 的帧 → pbuf → ethernet_input
  sys_check_timeouts()   # ARP 表老化等定时器——没人替你喂，忘喂=表不老化
  app_tick()             # 500ms Link 轮询（BSR→netif）/ 1s etharp_query / 1s 手搓 ping
```

## 硬件拓扑

```text
[STM32F429 挑战者 V2] --RMII--> [板载 PHY] --RJ45--> [树莓派 4B eth0: 10.42.0.20/24]
 F429 = 10.42.0.10/24（静态，裸机版 ip addr add）
[野火 DAP] --SWD--> 烧录；CH340 --USART1--> 串口日志
```

## 目录结构

| 文件                                      | 说明                                                                                   |
| ----------------------------------------- | -------------------------------------------------------------------------------------- |
| `main.c`                                  | 时钟 180MHz + lwip_init + netif_add（静态 IP）+ 主循环 + 手搓 ping（raw API）+ DWT RTT |
| `ethernetif.c/.h`                         | 移植层三件套：`eth_hw_init`（ch20 成果）/ `low_level_input` / `low_level_output`       |
| `port/lwipopts.h`                         | 协议栈裁剪：NO_SYS=1，ARP+ICMP+raw 开，TCP/UDP/socket/DHCP 全关                        |
| `port/arch/cc.h`                          | 小端 + PACK_STRUCT + `LWIP_PLATFORM_DIAG`(串口) + `sys_prot_t`                         |
| `port/arch/sys_arch.h`                    | NO_SYS 占位（lwIP 仅在 OS 模式自动包含；升级 FreeRTOS 时映射队列）                     |
| `port/support.c`                          | 极简 `uart_printf`、freestanding libc 桩（memcpy 族/atoi）、`sys_now`、PRIMASK 临界区  |
| `lwip-src/`                               | lwIP 2.2.0 官方源码裁剪版（ARP+ICMP+raw+IPv4 编译闭包，23 个 .c）                      |
| `startup.S` / `stm32f429.ld` / `Makefile` | 与 eth-mdio-probe 同款骨架                                                             |

## 复现命令

```bash
make                 # 编译（NixOS 下 nix-shell -p gcc-arm-embedded）
make flash && make term
# 树莓派侧（直连对端）：
sudo nmcli con add type ethernet ifname eth0 ipv4.method manual \
     ipv4.addresses 10.42.0.20/24 con-name f429-link
sudo tcpdump -i eth0 -n -e 'arp or icmp'     # 仪式现场：who-has 10.42.0.20 tell 10.42.0.10
ping 10.42.0.10                              # RPi→F429：lwIP 本能回，零应用代码
```

## 预期输出（待实测核销）

```text
=== lwip_arp_ping : ch21 bare-metal lwIP (NO_SYS=1) ===
netif en0  MAC 12:34:56:78:9A:BC  IP 10.42.0.10/24
[link] UP                              # 插网线后 BSR 轮询喂入
[ping] reply seq=3 rtt_us=xxx          # 手搓 ICMP echo，DWT 周期差/180
---- lwip stats ----                   # 30s 周期：pbuf/mem 有没有漏（章节清单#3）
```

实测后回填真实数字与 tcpdump 输出（`run.log` 存档，超 1MB 按 SPEC 截断）。

## 已知取舍（与章节一致的诚实边界）

- `low_level_output` 环满自旋等待（教学取舍，绝不返回 ERR_MEM——errno 穿透事故，见 lwIP 十七）；
- 收帧是拷贝派（一跳 memcpy 立即还槽），零拷贝派对照见 lwIP 十七 17.4 的 A/B 表；
- `SYS_LIGHTWEIGHT_PROT=1` 临界区用 PRIMASK 实现好放在那儿——纯轮询用不上，
  升级实验一开 ETH 中断它就是 pbuf 引用计数的安全带；
- TCP/UDP 未编入（`lwipopts.h` 全关）：ch22 打流实验要 TCP 时回来开 `LWIP_TCP` 并补源码。
