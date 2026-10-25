# lab03-auth-digest — WS-Security 摘要认证与时钟纪律（ONVIF 设备端实验室第 3 站）

给 lab02 的控制面上锁：免鉴权四连原样保留，白名单外的 GetUsers 必须带
WS-Security UsernameToken 过五环判据链（查用户 → nonce 解码 → SHA1 重算比对
→ Created ±300s 窗口 → nonce 环重放拒绝）；对外统一 ter:NotAuthorized，分因只
落板端 run.log。SNTP 启动对时治本、免鉴权对表治标，外加把 ch09 坑 1 复现成
可重放的九行教学矩阵。实战叙事见
《ONVIF 深度解析》[[ch14-lab03-auth-digest-report|第十四章]]，契约见套件
[SPEC](../../SPEC.md)（`practice/onvif-labs/SPEC.md` §6 lab03）。

## 拓扑

```text
宿主机（NixOS，本仓工作区）                ESP32-S31-Korvo-1（WiFi STA，192.168.1.x）
  tools/onvif_smoke.py（onvif-zeep）          ┌──────────────────────────────────┐
      │  UsernameToken 摘要头（zeep 自动带）   │ onvif_svc :80                    │
      ├─ POST /onvif/device_service ────────▶ │  ├ 免鉴权四连（lab02 原样）        │
      │                                       │  └ GetUsers ── onvif_auth 判据链  │
  tools/onvif_auth_probe.py（stdlib 原声）     │      ├ SHA1 重算（PSA/MBEDTLS4）  │
      │  三原料全可控：nonce/Created/摘要      │      ├ nonce 环 64×20B（重放拒绝） │
      ├─ 同上 ─────────────────────────────▶ │      └ Created ±300s 窗口          │
      │                                       │ onvif_auth：SNTP（ntp.aliyun.com  │
  串口控制台 korvo> sntp on|off|status        │   + pool.ntp.org）+ NVS 教学开关   │
  korvo> clock reset（板钟归零复现坑 1）       │ onvif_disc :3702/udp（lab01）      │
      └──────── UART 115200 ◀────────────── └──────────────────────────────────┘
```

固件 = lab02 全量（基座 + `onvif_disc` + `onvif_svc` 免鉴权四连）+ 新增
`onvif_auth` 模块（判据链 + nonce 环 + 时钟窗口 + SNTP），`onvif_svc` 挂
GetUsers（鉴权门）。零新增 registry 组件（PSA/mbedTLS、SNTP 均为 IDF 内置）。
方案语境见 [[ch11-esp32s31-lab-plan|第十一章]] 与 [[ch13-lab02-device-service-report|第十三章]]。

## 构建

```bash
cd practice/onvif-labs/lab03-auth-digest
cp main/wifi_secrets.h.example main/wifi_secrets.h       # WiFi 凭据（同 lab01/02）
cp main/onvif_secrets.h.example main/onvif_secrets.h     # 认证凭据：改 ONVIF_AUTH_PASS
```

口令存编译期注入的**原文**（不存哈希，ch14 §14.1 的如实决策）；改口令走重新
烧录（SetUser 不在白名单）。首次构建联网拉 registry 组件后 `dependencies.lock`
固化；环境壳（NixOS，esp32s31 为 preview target）：

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py --preview set-target esp32s31 && idf.py build'
```

## 烧录与上板

```bash
# 烧录口按 VID:PID=10c4:ea60（CP2102N）定位；重插后 sudo chmod 666 <口>
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py -p /dev/ttyUSB0 flash'
```

启动判据：`SC101IOT` 识别 →
`$$$ ONVIF LAB03 AUTH READY sntp=on window_s=300 ring=64x20B user=admin` →
`$$$ ONVIF LAB03 SNTP synced epoch=<n>`（出外网后数秒内）→
`lab03 base ready (camera+stream+disc+svc+auth)`。串口控制台新增教学开关：
`sntp on|off|status`（落 NVS 重启保持）、`clock reset`（板钟归零复现坑 1）、
`status`/`ip`/`heap`/`restart` 原有。

## 验收（宿主侧，九行矩阵）

```bash
cd practice/onvif-labs/lab03-auth-digest
mkdir -p runs
# 宿主依赖（实测配方；NixOS 裸壳 exec 不了 IDF 自带 glibc python_env）：
python3 -m venv /tmp/onvif-venv && /tmp/onvif-venv/bin/pip install onvif-zeep pyserial
P=/tmp/onvif-venv/bin/python
PASS=$(grep -oP '(?<=ONVIF_AUTH_PASS ")[^"]+' main/onvif_secrets.h)   # 探针口令不落命令行历史外的地方
$P tools/serial_capture.py --port /dev/ttyUSB0 --seconds 110 \
  --send-at 8:status --send-at 40:"sntp off" --send-at 42:"clock reset" \
  --send-at 70:"sntp on" --send-at 95:status > run.log
# 另开终端（等 SNTP synced 行出现后；板 IP 以板端日志为准）：
$P tools/onvif_smoke.py --host <板IP> --password "$PASS" --outdir runs    # #1 zeep 正向
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --outdir runs          # 正向（默认按板钟对表）
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --no-auth --outdir runs        # #2 无安全头
$P tools/onvif_auth_probe.py <板IP> --pass wrongpass --outdir runs                # #3 错口令（≠$PASS）
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --user ghost --outdir runs     # #4 错用户名
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --nonce-as-text --outdir runs  # #5 字节坑
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --replay 2 --outdir runs       # #6 重放
# 板钟归零后（等 console 回显 clock reset to epoch）：
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --host-clock --outdir runs     # #7 不补偿 → clock_skew
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --outdir runs                  # #8 按板钟补偿 → 过
# sntp on 后（等第二条 SNTP synced）：
$P tools/onvif_auth_probe.py <板IP> --pass "$PASS" --host-clock --outdir runs     # #9 恢复 → 过
grep '\$\$\$ ONVIF LAB03 AUTH' run.log                                   # 分因对账
```

探针启动自检：ch04 4.2 验收向量按规范字节观复算（头里 Nonce 是 base64：
`TEtLMHdpOWNRM1ptdlFwMg==` = 16 字节可打印 ASCII `LKK0wi9cQ3ZmvQp2`，摘要 =
`yN+RxcHPSx2u50AcC/obCm/0zIQ=`），算不出不发报文。

## 真实输出摘录（2026-10-26 上板实测，板 IP=192.168.1.4 本轮 DHCP）

（固件版本串 `v4.5.2-78-g1cae212d-dirty` 里的 hash 是**构建时点**的提交——其后该提交因
凭据页清理被 amend 重写、hash 已变，git 里按此 hash 查不到属预期；设备侧事实以板上
`FirmwareVersion` 字符串与下方 run.log 摘录为准。）

启动判据与 SNTP（`run.log` 全文留存，32.7KB，末尾含 #7 补采标注段）：

```text
I (1854) onvif_auth: $$$ ONVIF LAB03 AUTH READY sntp=on window_s=300 ring=64x20B user=admin
I (3375) onvif_disc: $$$ ONVIF LAB01 DISC JOIN grp=239.255.255.250:3702 ip=192.168.1.4
I (3448) onvif_svc: $$$ ONVIF LAB03 SVC READY http=192.168.1.4:80/onvif/device_service
I (3466) onvif_auth: $$$ ONVIF LAB03 SNTP synced epoch=1792948351
```

矩阵 #1–#6 板端分因标记行（`runs/smoke-zeep.log` / `runs/smoke-probe.log`
为宿主侧对账；External 全部 ter:NotAuthorized，分因只在板端）：

```text
I (4410) onvif_auth: $$$ ONVIF LAB03 AUTH ok user=admin            # #1 zeep + 探针正向
I (4781) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=no_token user=-
I (4855) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=digest_mismatch user=admin  # #3
I (4942) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=user_unknown user=ghost    # #4
I (5031) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=digest_mismatch user=admin  # #5 字节坑
I (5121) onvif_auth: $$$ ONVIF LAB03 AUTH ok user=admin            # #6 第 1 发
I (5136) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=nonce_replay user=admin    # #6 重放
```

坑 1 复现与恢复（`clock reset` 归零板钟后）：

```text
korvo> clock reset
clock reset to epoch (ch09 pit 1 replay)
I (44561) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=clock_skew user=admin
# 探针按板钟对表后（Created=1970-01-01T00:00:02Z）：
I (44652) onvif_auth: $$$ ONVIF LAB03 AUTH ok user=admin
korvo> sntp on
I (71874) onvif_auth: $$$ ONVIF LAB03 SNTP synced epoch=1792948420
I (73664) onvif_auth: $$$ ONVIF LAB03 AUTH ok user=admin           # 不补偿也过
```

内存红线观测（SPEC §4；无流客户端连接态，含鉴权+SNTP 全程活动）：

```text
t=8  status: free_dma=252227 free_spiram=12040164
t=95 status: free_dma=252011 free_spiram=12040164
```

三轮启动打点与 lab01/02 同基线（356K→275K）；全程 free_dma ≈252KB，漂移 216B，
红线 ≥170KB 无压力。

## 已知边界（刻意为之）

- **判据链只认 PasswordDigest**：PasswordText 明文形态会落 digest_mismatch（摘要
  比对是唯一判别器）；Type 属性不参与判断。
- **Created 只认 `Z` 与 `+00:00`**：非零时区偏移（`+08:00` 形态）不宽容——窗口只认
  UTC 时刻，摘要对的是原样字符串（ch04 字节观纪律的变体）。zeep 实测发 `+00:00`。
- **nonce 环 64 槽、失败不记账**：窗口内去重；多客户端高频并发会稀释容量，如实
  为教学边界。
- **esp_restart 不清 RTC 墙钟（实测）**：SNTP 同步过的时间软重启后保留——坑 1 的
  「板钟停纪元」复现改走 `clock reset`（settimeofday 归零），`sntp off` 只断同步。
- **GetUsers 只报 admin 一条**（Administrator）；CreateUser/SetUser/DeleteUsers 不在
  白名单，回 ActionNotSupported。
- 免鉴权四连带凭据请求同样放行（wsse 头在免鉴权操作上一概不查）；XAddr/端口/
  发现面边界沿袭 lab01/02（见各 README）。
