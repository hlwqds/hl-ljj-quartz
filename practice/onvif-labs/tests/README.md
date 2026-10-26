# ONVIF Labs 统一测试集

六站散落工具收拢为套件级测试。**每次改固件重烧后跑一遍**，退化当场现形。

## 跑法

```bash
~/.venvs/onvif/bin/python practice/onvif-labs/tests/runner.py --host 192.168.1.4
# 解释器必须是该 venv（依赖 pyserial + onvif-zeep）；口令默认读 lab06 main/onvif_secrets.h
# 证据落 practice/onvif-labs/tests/runs/selftest.json
```

## 覆盖矩阵

| ID      | 面            | 验什么                                                                                                                                                                         | 对齐         |
| ------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------ |
| T01     | 发现          | Probe→ProbeMatch（随机 uuid + 组播 2 次 + 单播兜底 2 次）                                                                                                                      | lab01/ch12   |
| T02–T04 | 控制面        | 免鉴权 DevInfo/DateTime、GET→405                                                                                                                                               | lab02/ch13   |
| T05–T08 | 鉴权          | 摘要门正路径、无凭据、错口令、nonce 重放                                                                                                                                       | lab03/ch14   |
| T09–T13 | 媒体          | zeep 冒烟逐行证据 + 快照 JPEG magic                                                                                                                                            | lab04/ch15   |
| T14     | 流媒体        | 信令四步 200 + 12s 完整帧 + 板端 TEARDOWN 对账                                                                                                                                 | lab05/ch16   |
| T15–T23 | Profile S     | GetProfile 单数/负路径、VideoSource/Encoder Configuration(s)、Options（zeep 严格校验）、NetworkInterfaces 真实 MAC/IP、Scopes 对账                                             | ch17 §17.5.1 |
| T24     | 鉴权门        | 新操作免凭据 → NotAuthorized                                                                                                                                                   | ch17 §17.5.1 |
| T25     | 内存统计      | console mem → `$$$ ONVIF STATS` 账目行 + free_dma ≥170KB 红线                                                                                                                  | ch17 §17.5.2 |
| T26–T29 | 媒体面鉴权    | 401 质询、带凭据全流程、错口令、nonce 一次性 + 454 状态前置                                                                                                                    | ch17 §17.5.3 |
| T30     | WS-Addressing | 请求 MessageID → 应答 RelatesTo 回显 + 自生成 MessageID                                                                                                                        | ch17 §17.5.4 |
| T31     | httpd 韧性    | 3 条半开连接（CL=100）后 8s 内恢复 200（recv 窗口 1s 截止）                                                                                                                    | ch17 §17.5.5 |
| T32–T34 | Profile G     | trc 能力诚实档（ReceiverSource/MediaProfileSource/DynamicRecordings/DynamicTracks 全 false + MaxStringLength 0）、GetRecordings 空列表、SetSynchronizationPoint + token 门负例 | ch17 §17.5.5 |

固件侧被测对象为套件级组件 `components/onvif/`（disc/auth/svc/rtsp/stats，
六站共源；能力旗标 + 媒体边界注入，见 ch17 §17.5.2）。存储账配套工具
`lab06/tools` 同级：`practice/onvif-labs/tools/size_report.sh`。

## 设计决定

- **逐项证据**：zeep 冒烟按 stdout 证据行拆项，五个操作不是一条退出码。
- **单项失败不中断**：所有异常被 runner 捕获记 FAIL；subprocess 全包 TimeoutExpired。
- **环境事实入测**：本机 AP 过滤组播 → T01 内建单播兜底（ch16 宿主侧边界同源）。
- **三本账**：T14 比对客户端帧数与板端 `TEARDOWN total`（实测精确相等）。
- **zeep 当最严裁判**：T15–T23 全部走 zeep 反序列化，schema 违规当场现形（Options 模板
  的 QualityRange 违规即被它抓出）；口令不进参数：默认读 secrets.h，避免进 shell 历史。
- **RTSP 前置清场**：T14 开测前杀孤儿 ffmpeg/dashboard/keeper（单客户端串行 accept 设计，
  任何存活旧消费者都占死会话槽）。
- **解释器**：`~/.venvs/onvif`（持久）优先，`/tmp/onvif-venv` 兜底；选用路径随 JSON 落盘。
- **双层测试**：组件纯逻辑另配宿主单元测试（`components/onvif/test/run.sh`，gcc +
  RFC 2617 向量，不依赖板子）；板端功能测试走本套件。

## 不进本套件的（避免重复维护）

- lab03 九行矩阵（时钟漂移、ghost-user、byte-trap）——用 `lab03/tools/onvif_auth_probe.py`
- lab06 HA witness（环境受限，独立证据）——`lab06/tools/ha_witness.py`
