# lab06-interop-harness — 互通收口（ONVIF 设备端实验室第 6 站·收官）

五站总装：lab01–lab05 的完整固件合成一台「普通 ONVIF 摄像机」（发现→鉴权→Profile
→RTSP 全链），串口控制台新增 `witness` 命令打互通结论标记行。实战叙事见
《ONVIF 深度解析》[[ch17-lab06-interop-harness-report|第十七章]]，契约见套件
[SPEC](../../SPEC.md)（`practice/onvif-labs/SPEC.md` §6 lab06）。

## 拓扑（五站全链）

```text
宿主机                                    ESP32-S31-Korvo-1（总装固件）
  onvif_probe.py ── WS-Discovery 3702 ──▶ onvif_disc（lab01）
  onvif_smoke.py ── SOAP :80 ──────────▶ onvif_svc（lab02–04：四连/GetUsers/）
      │                                      ├ GetProfiles / GetStreamUri（lab04–05）
      │                                      └ Profile S 补齐八操作（ch17 §17.5.1）
      │                                        GetProfile 单数 · VideoSource/Encoder
      │                                        Configuration(s) · Options · NetIf · Scopes
  rtsp_ledger.py ── RTSP :8554 ─────────▶ rtsp_server（lab05：RFC 2435 封包）
  curl /onvif-http/snapshot                快照（lab04）
  ../tests/runner.py                       套件级统一自测 21 项（见 tests/README.md）
  console: witness ha ok                   ← 互通结论标记行（lab06 新增）
```

## 构建 / 烧录

同 lab03–05（复制上一站 → 改工程名；凭据 gitignore 头文件 + example 模板）。

## 验收（全链走通 + witness 标记）

```bash
~/.venvs/onvif/bin/python ../tests/runner.py --host <板IP>               # 统一自测 21 项（首选）
$P tools/onvif_smoke.py --host <板IP> --password "$PASS" --outdir runs    # GetStreamUri+Fault+回归
$P tools/rtsp_ledger.py <板IP> --seconds 12                              # RTSP 账本
$P tools/onvif_probe.py --unicast <板IP>                                 # 发现面
curl --noproxy '*' -fsS -o runs/snap-witness.jpg http://<板IP>/onvif-http/snapshot
# 串口：witness ha ok
grep '\$\$\$ ONVIF LAB0' run.log                                         # 全链标记行
```

## 真实输出摘录（2026-10-26 上板实测，板 IP=192.168.1.4）

```text
I (1858) onvif_auth: $$$ ONVIF LAB03 AUTH READY sntp=on window_s=300 ring=64x20B user=admin
I (1867) rtsp_server: $$$ ONVIF LAB05 RTSP LISTENING port=8554
I (17093) onvif_auth: $$$ ONVIF LAB03 SNTP synced epoch=1792961096
I (30129) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service
I (30022) onvif_svc: $$$ ONVIF LAB05 SNAPSHOT bytes=77624
I (17964) rtsp_server: SETUP transport=TCP
I (17970) rtsp_server: $$$ ONVIF LAB05 PLAY seq=0 rtptime=0
I (18076)–(29957) rtsp_server: $$$ ONVIF LAB05 FRAME seq=1..100 (≈76.5–77.4KB)
```

内存红线：`free_dma=243195`（TEARDOWN 时），≥170KB 红线无压力。

## 已知边界

- **HA onvif 集成 H264-only**：HA 2026.2.3 的 onvif 集成只接受 `Encoding=="H264"`
  的 profile（`config_flow.py` → `AbortFlow("no_h264")`），本板只有 JPEG 编码档
  （ESP32-S31 无硬编 H264）→ HA onvif 摄像头集成在建 entry 前中止。绕行：HA 的
  通用 RTSP camera 集成可直接拉 `rtsp://<ip>:8554/mjpeg`（lab05 实测 ffmpeg 解码
  180 帧/12s），但「零手工 URL 的 ONVIF 全自动」对 JPEG-only 设备不可达。
- **HA Core NixOS pip venv 不稳**：`default_config` 拉进 `pyspeex_noise`/`numpy`
  （需 GLIBC 2.43 vs 本机 2.42），最小配置可绕但进程不稳定——容器化是正确部署
  形态，本环境无 docker。
- 其余沿袭 lab01–05（单客户端、无 Digest、无 RTCP 等，见各 README）。
