# lab02-device-service — SOAP 控制面最小集（ONVIF 设备端实验室第 2 站）

兑现 lab01 发现层开出的支票：在同一个 80 端口的 httpd 实例上挂
`/onvif/device_service`，实现免鉴权四连（GetSystemDateAndTime /
GetDeviceInformation / GetServices / GetCapabilities），白名单之外一律回合规
SOAP Fault（env:Receiver + ter:ActionNotSupported，HTTP 500）。信封双壳
（SOAP 1.1 / 1.2 模板共用 Body，回信跟随请求版本）。实战叙事见
《ONVIF 深度解析》[[ch13-lab02-device-service-report|第十三章]]，实现契约见套件
[SPEC](../../SPEC.md)（`practice/onvif-labs/SPEC.md` §6 lab02）。

## 拓扑

```text
宿主机（NixOS，本仓工作区）                  ESP32-S31-Korvo-1（WiFi STA，192.168.1.x）
  tools/onvif_smoke.py（onvif-zeep 0.2.12）
      │  SOAP 1.2 POST /onvif/device_service      ┌────────────────────────────┐
      │  Content-Type: application/soap+xml       │ httpd :80（单实例）         │
      ├─────────────────────────────────────────▶ │  ├ /onvif/device_service   │
      │                                           │  │   （lab02 SOAP 控制面）  │
  tools/soap11_probe.py（stdlib 手搓 1.1）        │  ├ /stream（MJPEG 对照面）  │
      │  SOAP 1.1 POST text/xml + SOAPAction      │  └ /（查看页）              │
      ├─────────────────────────────────────────▶ │                            │
      │                                           │ onvif_disc :3702/udp（lab01）│
  tools/serial_capture.py（串口取证+打点）         │ 相机 SC101IOT→JPEG 25fps 管线│
      └──────── UART 115200 ◀─────────────────── └────────────────────────────┘
```

固件 = lab01 基座（采集→PPA→硬件 JPEG→双缓冲 + WiFi STA + 串口控制台 +
`onvif_disc` 发现模块）+ 新增 `onvif_svc` 控制面模块（原站点副本已于 ch17 §17.5.2
并入共享组件 `../components/onvif/src/onvif_svc.c`，按 `onvif_svc_config_t` 旗标装配；
393 行）。基座复现细节见 SPEC §3，方案语境见
[[ch11-esp32s31-lab-plan|第十一章]]。

## 构建

先备好本地凭据（不进版本库，`.gitignore` 已排除）：

```bash
cd practice/onvif-labs/lab02-device-service
cp main/wifi_secrets.h.example main/wifi_secrets.h   # 然后填入真实 SSID/密码
```

首次构建需联网拉取 registry 组件（BSP/传感器栈等），完成后 `dependencies.lock`
固化、后续离线可重复。环境激活与构建壳（NixOS，esp32s31 是 IDF v6.1 的
preview target）：

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py --preview set-target esp32s31 && idf.py build'
```

## 烧录与上板

```bash
# 烧录口按 VID:PID=10c4:ea60（CP2102N）定位，口名随枚举顺序变（ttyUSB0/ttyUSB1 都出现过）：
#   udevadm info -q property -n /dev/ttyUSB0 | grep -E '10c4|ea60'   # 烧前核身份
# 重插后需 sudo chmod 666 <口>；同机若插着 CH340（1a86:7523，STM32 板）切勿灌错
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py -p /dev/ttyUSB0 flash'
```

启动日志判据（串口即日志口，115200）：`SC101IOT` 传感器识别 →
`$$$ ONVIF LAB01 DISC READY/JOIN`（发现面，lab01 交付）→
`$$$ ONVIF LAB02 SVC READY http=<板IP>:80/onvif/device_service` →
`lab02 base ready (camera+stream+disc+svc)`。串口控制台
`status` / `ip` / `heap` / `restart` 随时可查（`korvo>` 提示符）。

## 验收（宿主侧）

客户端两路：python-onvif-zeep 0.2.12（随包 WSDL 全为 soap12 绑定）走 1.2 壳；
stdlib 手搓探针走 1.1 壳（`text/xml` + `SOAPAction` 头）。串口取证用
`serial_capture.py`（打开端口即硬复位从头收日志，`--send-at SS:CMD` 定时往
控制台写打点命令）：

```bash
cd practice/onvif-labs/lab02-device-service
mkdir -p runs
# 宿主依赖用独立 venv（实测配方；NixOS 裸壳 exec 不了 IDF 自带的 glibc python_env）：
python3 -m venv /tmp/onvif-venv && /tmp/onvif-venv/bin/pip install onvif-zeep pyserial
# 本仓实测版本：onvif-zeep 0.2.12（WSDL 随包在 site-packages/wsdl，ONVIFCamera 默认即取到）+ zeep 4.3.3 + pyserial 3.5
/tmp/onvif-venv/bin/python tools/serial_capture.py --port /dev/ttyUSB0 --seconds 75 \
  --send-at 9:status --send-at 32:status --send-at 60:heap > run.log
# 另开终端（或等 READY 行出现后）：
/tmp/onvif-venv/bin/python tools/onvif_smoke.py --host <板IP> --outdir runs   # 四连 + 拒绝语义，双端原文留样
/tmp/onvif-venv/bin/python tools/soap11_probe.py --host <板IP> --outdir runs  # 1.1 壳：四连代表 + Fault + GET 405
grep '\$\$\$ ONVIF LAB02' run.log                                             # 板端标记行与宿主输出对账
```

冒烟覆盖：①构造 `ONVIFCamera` 即零号用例（`update_xaddrs()` 内部先发
GetCapabilities，答不好走不到下一行）→ ②③④逐操作 zeep 反序列化 + 字段断言
（DateTimeType=Manual、身份五行、单一 Device 服务、能力树仅 Device 小节、
XAddr 必须等于 Host 头拼出的地址）→ ⑤GetUsers 必须收到
`ter:ActionNotSupported`。全部 SOAP 交换由 zeep HistoryPlugin 抓取，请求/应答
原文落 `runs/`（`zeep-*.req/res.xml`、`fault-*.res.xml`、`soap11-*` 为原始字节）。

## 真实输出摘录（2026-10-26 上板实测，板 IP=192.168.1.4 本轮 DHCP）

启动判据（`run.log` 全文留存，15.9KB）：

```text
I (1329) lab02: Free internal DMA before stream init: 356211 bytes
I (1438) sc101iot: Detected Camera sensor PID=0xda4a
I (1832) lab02: Free internal DMA after stream init: 274975 bytes
I (1847) lab02: lab02 base ready (camera+stream+disc+svc)
I (3417) onvif_disc: $$$ ONVIF LAB01 DISC JOIN grp=239.255.255.250:3702 ip=192.168.1.4
I (3447) onvif_svc: $$$ ONVIF LAB02 SVC READY http=192.168.1.4:80/onvif/device_service
```

zeep 1.2 壳冒烟全绿（`runs/smoke-zeep.log`，四连 + Fault 5/5）：

```text
$$$ HOST LAB02 OP GetCapabilities(implicit-on-init) ok  # 零号用例：构造成功
$$$ HOST LAB02 OP GetSystemDateAndTime ok  type=Manual utc=1970-01-01 00:00:04
$$$ HOST LAB02 OP GetDeviceInformation ok  Manufacturer=Espressif \
  Model=ESP32-S31-Korvo-1 ONVIF Lab FirmwareVersion=v4.5.2-77-gf46e24ab-dirty \
  SerialNumber=1c2904d072e8 HardwareId=ESP32-S31
$$$ HOST LAB02 OP GetServices ok  n=1 ns=tds \
  xaddr=http://192.168.1.4/onvif/device_service version=10.12
$$$ HOST LAB02 OP GetCapabilities ok  sections=Device xaddr=http://192.168.1.4/onvif/device_service
$$$ HOST LAB02 FAULT GetUsers ok  \
  reason='Unknown error: Requested action not supported (ter:ActionNotSupported)'
$$$ HOST LAB02 SMOKE PASS 5/5 (四连 + Fault)，原文留样见 runs/
```

1.1 壳手工探针（`runs/smoke-soap11.log`）：

```text
$$$ HOST LAB02 SOAP11 GetDeviceInformation http=200 ctype=text/xml; charset=utf-8 bytes=552
$$$ HOST LAB02 SOAP11 GetServices http=200 ctype=text/xml; charset=utf-8 bytes=510
$$$ HOST LAB02 SOAP11 GetUsers http=500 ctype=text/xml; charset=utf-8 bytes=372
$$$ HOST LAB02 SOAP11 GET http=405  # 期望 405
```

双端对账（板端标记行 ↔ 宿主留样一一对应，`run.log`）：

```text
I (4571) onvif_svc: $$$ ONVIF LAB02 OP GetCapabilities ok      # zeep 零号
I (4582) onvif_svc: $$$ ONVIF LAB02 OP GetSystemDateAndTime ok # zeep ①
I (4640) onvif_svc: $$$ ONVIF LAB02 OP GetDeviceInformation ok # zeep ②
I (4691) onvif_svc: $$$ ONVIF LAB02 OP GetServices ok          # zeep ③
I (4741) onvif_svc: $$$ ONVIF LAB02 OP GetCapabilities ok      # zeep ④
I (4788) onvif_svc: $$$ ONVIF LAB02 OP (unlisted) fault action-not-supported  # zeep ⑤
I (4929) onvif_svc: $$$ ONVIF LAB02 OP GetDeviceInformation ok # 1.1 探针 ①
I (4950) onvif_svc: $$$ ONVIF LAB02 OP GetServices ok          # 1.1 探针 ①b
I (4982) onvif_svc: $$$ ONVIF LAB02 OP (unlisted) fault action-not-supported  # 1.1 探针 ②
```

Fault 结构留样（`runs/fault-GetUsers.res.xml`，1.2 壳；1.1 壳对应
`soap11-fault-GetUsers.res.xml` 的 faultcode/faultstring 两件套）：

```xml
<s:Fault>
  <s:Code>
    <s:Value>s:Receiver</s:Value>
    <s:Subcode>
      <s:Value xmlns:ter="http://www.onvif.org/ver10/error">ter:ActionNotSupported</s:Value>
    </s:Subcode>
  </s:Code>
  <s:Reason>
    <s:Text xml:lang="en">Requested action not supported (ter:ActionNotSupported)</s:Text>
  </s:Reason>
</s:Fault>
```

内存红线观测（SPEC §4，`run.log` 打点；无流客户端连接态）：

```text
t=9s  status: free_dma=253751 free_spiram=12055112   # 冒烟前
t=32s status: free_dma=253719 free_spiram=12055112   # 冒烟后（双客户端全过）
t=60s heap : free_dma=253687 free_spiram=12055112
```

红线 free_dma ≥ 170KB：三轮打点全部 ≈253.7KB，冒烟前后漂移仅 32B（至 t=60s 末次打点累计
64B）——SOAP 缓冲全在 PSRAM 的纪律没欠账。

## 已知边界（刻意为之）

- **免鉴权四连，s:Header 一概不校验**：zeep 每发都带 WS-UsernameToken
  摘要头（`runs/zeep-*.req.xml` 留样可见 Username/PasswordDigest/Nonce/Created），
  设备照单全收——校验是 lab03 的交付。
- **无 SNTP，UTCDateTime=系统时钟**：开机后 `time()` ≈ 开机秒数，实测
  `utc=1970-01-01 00:00:04`；DateTimeType 诚实填 Manual。NTP 对时与补偿窗口
  是 lab03 的活（[[ch09-interop-ecosystem|第九章]]坑 1 的翻车实验也在那边）。
- **能力只报真实的**：GetServices 只报 Device 服务一条（Version 10.12），
  GetCapabilities 只长 Device 小节（XAddr/Network/System 六 false）；
  GetServices 的 IncludeCapability=true 时 Capabilities 元素为空——等
  GetServiceCapabilities 真正实现再议。
- **端点语义**：GET `/onvif/device_service` 回 405（不吐 WSDL，ch03 §3.3
  纪律）；未注册路径自然 404（实测 `/onvif/events_service` →
  `404 Nothing matches the given URI`）——不装作有服务。
- **1.1 壳的先天取舍**：SOAP 1.1 无 Subcode 位，ter:ActionNotSupported 只能
  落 faultstring 文本（`soap11-fault-GetUsers.res.xml`）。
- **XAddr 纪律**：所有地址字段由请求 Host 头拼出（缺失回落板端 netif 地址），
  禁写死 IP（SPEC §5）。
- 仅 IPv4；`/stream` 对照面（:80）沿袭基座；发现面边界见 lab01 README。
