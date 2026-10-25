# lab01-discovery — WS-Discovery 应答（ONVIF 设备端实验室第 1 站）

把 ESP32-S31-Korvo-1 变成局域网里一台**可被发现**的 ONVIF 取流设备：上电连
WiFi，加入 WS-Discovery 组播组，对 Probe 回 ProbeMatch（Types/XAddrs/Scopes/
MetadataVersion）。方案语境见《ONVIF 深度解析》[[ch11-esp32s31-lab-plan|第十一章]]
与套件 [SPEC](../../SPEC.md)（`practice/onvif-labs/SPEC.md`）。

## 拓扑

```text
宿主机（NixOS，本仓工作区）              家庭 AP（192.168.1.0/24）
  python3 tools/onvif_probe.py
      │  UDP 组播 Probe → 239.255.255.250:3702
      │                                        ┌──────────────────────────┐
      └──── 单播 ProbeMatch（XML）◀──────────  │ ESP32-S31-Korvo-1        │
                                               │  WiFi STA（192.168.1.x） │
                                               │  disc_responder :3702/udp│
                                               │  /stream 对照面 :80（MJPEG）│
                                               └──────────────────────────┘
```

固件 = 裁剪版 factory_demo 基座（采集→PPA→硬件 JPEG→双缓冲 + WiFi STA + 串口
控制台，UI/触摸/USB/音频已裁）+ 新增 `onvif_disc` 发现模块。基座复现细节见
SPEC §3，上游实测背景见 `~/code/esp32-video-tran/RUNBOOK.md`（本机工作区）。

## 构建

先备好本地凭据（不进版本库，`.gitignore` 已排除）：

```bash
cd practice/onvif-labs/lab01-discovery
cp main/wifi_secrets.h.example main/wifi_secrets.h   # 然后填入真实 SSID/密码
```

首次构建需联网拉取 registry 组件（BSP/适配器/传感器栈），完成后 `dependencies.lock`
固化、后续离线可重复。环境激活与构建壳（NixOS）：

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py --preview set-target esp32s31 && idf.py build'
```

（esp32s31 是 IDF v6.1 的 preview target，`set-target` 必带 `--preview`。）

## 烧录与上板

```bash
# 烧录口按 VID:PID=10c4:ea60（CP2102N）定位，口名随枚举顺序变（ttyUSB0/ttyUSB1 都出现过）：
#   udevadm info -q property -n /dev/ttyUSB0 | grep -E '10c4|ea60'   # 烧前核身份
# 重插后需 sudo chmod 666 <口>；同机若插着 CH340（1a86:7523，STM32 板）切勿灌错
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py -p /dev/ttyUSB0 flash'
```

启动日志判据（串口即日志口，115200）：`SC101IOT` 传感器识别 → `$$$ ONVIF LAB01
DISC READY uuid=urn:uuid:…` → WiFi 关联拿 IP → `$$$ ONVIF LAB01 DISC JOIN
grp=239.255.255.250:3702 ip=<板IP>` → `lab01-discovery base ready`。串口控制台
`status` / `ip` / `heap` 随时可查（与日志口同口，`korvo>` 提示符）。

## 验收（宿主侧）

证据以**双端原文**为主（②③必做：探针脚本同屏打出发出的 Probe 原文与收到的
ProbeMatch 原文+hex；① tcpdump 需 sudo，作补充证据）：

```bash
# ① 发现层抓包（补充证据，需 root）：Probe 进 / ProbeMatch 出
#    （wlp0s20f3 为本机唯一网卡；换机时按 `ip route get 239.255.255.250` 定出口）
sudo tcpdump -i wlp0s20f3 -vvv -s0 'udp port 3702' | tee runs/tcpdump-3702.log

# ② 组播探测：发出 Probe 原文 + 收集窗口内应答原文/hex
python3 tools/onvif_probe.py --timeout 3 | tee runs/probe-1.log

# ③ 板端日志：PROBEMATCH 标记行
grep '\$\$\$ ONVIF LAB01' run.log
```

预期：② 打出 `$$$ HOST PROBEMATCH from=<板IP> … xaddrs=http://<板IP>:80/onvif/device_service`；
①里能看到宿主 Probe 与板端单播回包；③出现与 ①② 对应的
`$$$ ONVIF LAB01 PROBEMATCH …` 行。板 IP 以板端日志为准（DHCP 会变，勿写死）。
组播 0 收时改用 `--unicast <板IP>`（本环境实测组播回包不可靠，见「已知边界」）。

## 真实输出摘录（2026-10-25 上板实测，板 IP=192.168.1.4 本轮 DHCP）

启动判据（`run.log` 全文留存）：

```text
I (1179) sc101iot: Detected Camera sensor PID=0xda4a
I (1817) lab01: Free internal DMA before stream init: 356227 bytes
I (1817) lab01: Free internal DMA after stream init: 274983 bytes
I (1837) onvif_disc: $$$ ONVIF LAB01 DISC READY uuid=urn:uuid:1c29047d-26d0-72e8-8a3e-4ba59cd1e2f3
I (1846) lab01: lab01-discovery base ready (camera+stream+disc)
I (3395) onvif_disc: $$$ ONVIF LAB01 DISC JOIN grp=239.255.255.250:3702 ip=192.168.1.4
```

宿主单播直探（`runs/probe-unicast.log` / `runs/probe-unicast-x3.log`）：

```text
probe #1 -> 192.168.1.4:3702
$$$ HOST PROBEMATCH from=192.168.1.4 ep=urn:uuid:1c29047d-26d0-72e8-8a3e-4ba59cd1e2f3 \
  types=dn:NetworkVideoTransmitter xaddrs=http://192.168.1.4:80/onvif/device_service
total ProbeMatch: 1        # ×3 复发：total ProbeMatch: 3（4/4 全部送达）
```

板端标记行与组播对照（同一轮，`run.log`；组播 3 发板端 3 回，宿主 0 收，见边界）：

```text
I (6842)  onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:40682
I (11928) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:47448
I (12930) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:47448
I (13932) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:47448
```

## 已知边界（刻意为之）

- **Scopes 宽松匹配**：Probe 里的 Scopes 不做 scope-matching 校验，一律应答
  （SPEC §6 lab01 明示的简化；ch02 的 MatchBy 语义留到 lab02+ 收紧）。
- **只应答 Probe**：Resolve/Bye/Hello 语义不实现；无重发与惩罚机制。
- **XAddrs 指向的 `/onvif/device_service` 尚不存在**——SOAP 控制面是 lab02 的
  交付；本站只证明「发现面可被标准客户端探到」。
- 仅 IPv4；HTTP 对照面 `/stream`（:80）沿袭基座，端口表见 SPEC §5。
- **家庭 AP 无线组播路径不对称（实测）**：组播 Probe 宿主→板可达（板端 4/4 收到并回包，
  见 `run.log` 标记行），但其单播应答宿主侧 0/4 送达；单播直探（`--unicast`）路径
  4/4 稳定。本环境验收/日常探测用 `--unicast`；丢包精确定位需 tcpdump（sudo，可选）。
  真实部署（有线 NVR、IGMP snooping 正确配置）按 [[ch02-ws-discovery|第二章]]语义走组播。
- 内部 DMA 红线观测：`status` 的 `free_dma` 推流稳态不得低于 170KB（SPEC §4）；
  本轮启动实测：stream init 前 356,227 B / 后 274,983 B（无流客户端连接态）。
