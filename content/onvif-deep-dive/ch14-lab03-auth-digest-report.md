---
title: "ONVIF 深度解析（十四）：实战实录三——lab03，WS-Security 摘要认证与时钟纪律"
date: 2026-10-25 12:00:00
description: "实战篇第三站：把第四章客户端手工推导的 PasswordDigest = Base64(SHA1(Nonce+Created+Password)) 搬到设备侧当验证器——onvif_auth 五环判据链（查用户→nonce 解码→SHA1 重算→±300s 窗口→nonce 环重放拒绝）坐进 lab02 的路由表，GetUsers 当靶子，对外统一 ter:NotAuthorized、分因只落板端 run.log；SNTP 对时治本、免鉴权对表治标；ch09 坑 1 复现成九行教学矩阵（clock reset 归零板钟，2026 Created 撞 clock_skew、1970 对表通过、sntp on 恢复），zeep 正向 + 原声探针九发全绿，free_dma 252KB 红线无压力。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 13. [[ch13-lab02-device-service-report|第十三章]] 14. **第十四章：实战实录三**

# ONVIF 深度解析（十四）：实战实录三——lab03，WS-Security 摘要认证与时钟纪律

[[ch04-ws-security-auth|第四章]]站在客户端，把摘要一行一行手工推导给设备看；本章站到柜台
对面——**设备怎么验这张支票**。lab01 让板子被探到（[[ch12-lab01-discovery-report|第十二章]]），
lab02 让控制面开口说话（免鉴权四连 + 合规 Fault，[[ch13-lab02-device-service-report|第十三章]]），
lab03 给控制面上锁：免鉴权白名单之外的一切操作，必须带 UsernameToken 过门。工程契约是
[practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)（[GitHub
源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）§6 的 lab03
一节：验收三件套（带凭据全通 / 无凭据 ter:NotAuthorized / 重放 nonce 被拒）与「故意制造时钟
漂移复现 ch09 坑 1（实测：仅关 SNTP 不足以复现，需显式 `clock reset` 拨回纪元）并记录恢复
路径」都是契约原文，本章按设计展开并逐项上板对账
（2026-10-26 实跑，九行矩阵全绿，实测记录见 14.5）。

## 14.1 定位：从「算给人看」到「验它算得对」

设备侧不发明新数学，四件套逐字段照着客户端义务做镜像：

| 字段       | 客户端义务（[[ch04-ws-security-auth\|第四章]]） | 设备侧义务（lab03）                             |
| ---------- | ----------------------------------------------- | ----------------------------------------------- |
| `Username` | 明文用户名，告诉设备查谁                        | 查花名册；不存在的用户与错口令同拒（防枚举）    |
| `Nonce`    | 每请求随机，base64 编码进头                     | base64 解码回原始字节参与重算；用过的进环形缓存 |
| `Created`  | 按设备时钟生成（对表之后）                      | 按自家时钟校验 ±300s 窗口                       |
| `Password` | 摘要值，口令本体不上线                          | 取存储的口令重算一遍，常量时间比对              |

对称性一眼看穿：客户端唯一看不见的原料是设备侧口令；设备唯一信不过的是报文——以及
（14.3 会看到）自己的时钟。于是设备侧的全部增量收敛为两条纪律：**重放拒绝**（14.2 的
nonce 环）与**时钟纪律**（14.3 的 SNTP + 对表窗口）。媒体面的另一套鉴权（RTSP 的 HTTP
Digest，ch04 4.5）不归本站，留 lab05。

工程形态：lab03 = 裁剪基座（采集→PPA→硬件 JPEG→双缓冲 + WiFi STA + 串口控制台，SPEC
§3）+ lab02 的 `onvif_svc`（单 httpd 挂 `/onvif/*`，:80）+ 本站新增 `onvif_auth`。零新增
registry 组件——mbedTLS 与 esp_sntp 都是 IDF 内置，dependencies.lock 纪律（SPEC §3）
不受扰动。受保护靶子选 GetUsers：ch04 4.4 拿它演示过请求结构，本站实现它返回单条
admin（Administrator）记录；用户管理四件套的其余三件（CreateUser/SetUser/DeleteUsers）
不在白名单，回 ActionNotSupported——与 lab02 的 Fault 纪律一致，能力边界如实声明。
目录形态按 SPEC §1 规划：

```text
lab03-auth-digest/
├── main/
│   ├── onvif_auth.c/.h          ← 本站新增：判据链 + nonce 环 + 时钟窗口
│   ├── onvif_svc.c              ← 自 lab02 移植：白名单外先过 onvif_auth_check()
│   ├── onvif_secrets.h.example  ← admin 口令模板（gitignore 纪律同 wifi_secrets）
│   └── 基座模块原样（factory_demo_* / factory_console / main）
├── tools/onvif_auth_probe.py    ← 原声探针：nonce/Created/摘要三原料全可控
├── runs/                        ← 坏 case 矩阵证据归档（按操作名存样）
└── README.md / run.log / CMakeLists.txt / sdkconfig.defaults / dependencies.lock
```

口令存储的一个如实决策：存编译期注入的**原文**（`onvif_secrets.h`，gitignore + example
模板，沿用 lab01 的 wifi_secrets 纪律），不存 SHA1(口令)——ch04 4.4 末提过「存哈希、以
哈希为原料」的设备变体会造成第三种摘要失配，本站不实现该变体；改口令走重新烧录
（SetUser 不在白名单）。

## 14.2 摘要认证：mbedTLS 重算一遍，五环判据

公式与 ch04 逐字相同：**PasswordDigest = Base64(SHA1(Nonce+Created+Password))**——设备侧
不做任何新发明，只是把「推导」换成「重算 + 比对」。字节观三纪律原样继承：nonce 参与
运算的是**解码后的原始字节**而非头里的 base64 文本；Created 是**原样字符串**（含 T、
毫秒、Z）而非重新格式化的时间；口令取明文 UTF-8。

请求过门的位置——免鉴权白名单就是 ch04 4.1 的四连问（lab02 已交付，本站原样保留）：

```text
httpd POST /onvif/device_service（:80，SPEC §5）
  └→ onvif_svc 分发器
       ├─ 免鉴权白名单：GetSystemDateAndTime / GetDeviceInformation /
       │  GetServices / GetCapabilities（四连问）→ 模板应答
       └─ 其余操作（本站靶子：GetUsers）→ onvif_auth_check()
            ├─ AUTH_OK    → 业务应答 + 标记行 AUTH ok
            └─ 五种失败码 → 同一个 ter:NotAuthorized，run.log 分因落因
```

校验路径实态（[main/onvif_auth.c](/static/code/#/onvif-labs/lab03-auth-digest/main/onvif_auth.c)
原文节选；Security 头定向解析沿用 lab01 `disc_extract` 同款小函数，不引 XML 栈）：

```c
auth_rc_t onvif_auth_verify(const char *rx)
{
    char user[32] = {0}, nonce_b64[64] = {0}, created[40] = {0}, digest_b64[48] = {0};
    uint8_t nonce[AUTH_NONCE_MAX];
    size_t nlen = sizeof(nonce), glen = AUTH_RING_FP;

    /* wsse 命名空间 URI 前缀无关判存（zeep/探针的 wsse 前缀都指向同一 URI） */
    if (strstr(rx, "oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext") == NULL)
        return finish(AUTH_NO_TOKEN, "-");
    if (!tag_value(rx, "Username", user, sizeof(user)) ||
        !tag_value(rx, "Nonce", nonce_b64, sizeof(nonce_b64)) ||
        !tag_value(rx, "Created", created, sizeof(created)) ||
        !tag_value(rx, "Password", digest_b64, sizeof(digest_b64)))
        return finish(AUTH_BAD_TOKEN, user[0] ? user : "-");
    if (strcmp(user, ONVIF_AUTH_USER) != 0)
        return finish(AUTH_USER_UNKNOWN, user); /* 与错口令同拒：不泄露花名册 */
    if (mbedtls_base64_decode(nonce, sizeof(nonce), &nlen,
                              (const uint8_t *)nonce_b64, strlen(nonce_b64)) != 0 || nlen == 0)
        return finish(AUTH_BAD_TOKEN, user);    /* nonce 非 base64 / 超 32B 上限 */

    /* SHA1(解码后 nonce 字节 + Created 原样字符串 + 口令 UTF-8)：三段拼进栈上 blob */
    uint8_t blob[AUTH_NONCE_MAX + 40 + 64];
    memcpy(blob, nonce, nlen);
    memcpy(blob + nlen, created, strlen(created));
    memcpy(blob + nlen + strlen(created), ONVIF_AUTH_PASS, strlen(ONVIF_AUTH_PASS));
    uint8_t calc[AUTH_RING_FP], got[AUTH_RING_FP];
    size_t calc_len = 0;
    if (psa_hash_compute(PSA_ALG_SHA_1, blob, nlen + strlen(created) + strlen(ONVIF_AUTH_PASS),
                         calc, sizeof(calc), &calc_len) != PSA_SUCCESS || calc_len != AUTH_RING_FP)
        return finish(AUTH_BAD_TOKEN, user);
    if (mbedtls_base64_decode(got, sizeof(got), &glen, (const uint8_t *)digest_b64,
                              strlen(digest_b64)) != 0 ||
        glen != AUTH_RING_FP || !ct_equal(calc, got, AUTH_RING_FP))
        return finish(AUTH_DIGEST_MISMATCH, user); /* 口令错 / 字节观错，都落这里 */
    long long made = 0;
    if (!created_epoch(created, &made))
        return finish(AUTH_BAD_TOKEN, user);       /* 解析不了/形态不收 */
    long long now = (long long)time(NULL);
    long long diff = now - made;
    if (diff < -AUTH_WINDOW_S || diff > AUTH_WINDOW_S)
        return finish(AUTH_CLOCK_SKEW, user);      /* ±300s，设备时钟说了算 */
    if (nonce_ring_hit(nonce, nlen))
        return finish(AUTH_NONCE_REPLAY, user);    /* 环上撞指纹 = 窗口内重放 */
    nonce_ring_add(nonce, nlen);                   /* 全校验通过才记账 */
    return finish(AUTH_OK, user);
}
```

四个实现备注（成文期方案与上板实态的出入如实记账）：① IDF v6.1 的 mbedTLS 是
**4.x/TF-PSA-Crypto**，经典流式 API（`mbedtls_sha1_starts/update/finish`）已不存在——SHA1
改走 PSA（三段拼进栈上 blob 后 `psa_hash_compute(PSA_ALG_SHA_1, …)` 一把出，`psa_crypto_init()`
在 `onvif_auth_init` 一次初始化）；② `ct_equal` 自写异或累加三行保留（不看
mbedTLS 版本脸色）；③ 解析发生在 `onvif_svc` 的 PSRAM 请求缓冲内（SPEC §4 纪律），
`onvif_auth` 零新增大缓冲，blob 与摘要全在栈上；④ Created 窗口解析按固定形态手写
（sscanf 一把）：**`Z` 与 `+00:00` 两种形态收**（zeep 实测发 `+00:00`，只认 Z 会挂自己
的验收客户端），非零时区偏移（`+08:00` 形态）仍不宽容，列为已知边界——窗口只决定收
不收，摘要对的是字符串本身，两件事不混（ch04 字节观纪律的变体）。

**判据顺序本身就是排错大纲**：先证明「你知道口令」（摘要），再证明「你来自当下」
（时钟），最后证明「这条报文第一次见」（重放）。每一环失败落不同的 reason，而客户端
看到的永远是同一个 Fault——ch04 抱怨过「设备不会告诉你 nonce 处理错了，只回 not
authorized」，本站的回应是把分因做进板端 run.log，等于把 [[ch09-interop-ecosystem|第九章]]
的三层对账做进设备本身：

| 失败码（返回值）     | 板端日志 reason=   | 典型根因（客户端侧失误）                                       |
| -------------------- | ------------------ | -------------------------------------------------------------- |
| AUTH_USER_UNKNOWN    | user_unknown       | 用户名不存在（与错口令同拒，防花名册枚举）                     |
| AUTH_BAD_TOKEN       | no_token/bad_token | 没带安全头；nonce 非 base64 或超 32B；Created 解析不了         |
| AUTH_DIGEST_MISMATCH | digest_mismatch    | 口令错；字节观错——nonce 拼了 base64 文本、Created 被重新格式化 |
| AUTH_CLOCK_SKEW      | clock_skew         | Created 出窗：设备时钟漂移（ch09 坑 1）                        |
| AUTH_NONCE_REPLAY    | nonce_replay       | 窗口内重放同一报文                                             |

**nonce 环形缓存：重放拒绝的记账本。** 职责边界先划清：环只负责**时间窗口内**的去重
——超出 ±300s 的报文本来就过不了窗口判据，轮不到环操心。槽位存 SHA1(nonce) 的 20
字节指纹而非原文：定长槽、任意 nonce 长度通吃、比对代价 = 一次哈希 + 64 次 memcmp
（环初始零填充，全零指纹无实际原像，教学形态不做占用位图）：

```c
/* nonce 环：64 槽 × 20B 指纹 = 1,280B 静态 BSS，零动态分配 */
#define AUTH_RING_SLOTS 64
static uint8_t s_ring[AUTH_RING_SLOTS][20];  /* 存 SHA1(nonce)：定长槽，长度无关 */
static uint8_t s_ring_head;

static bool nonce_ring_hit(const uint8_t *nonce, size_t n)
{
    uint8_t fp[20];
    mbedtls_sha1(nonce, n, fp);              /* 一次哈希换来定长比对 */
    for (int i = 0; i < AUTH_RING_SLOTS; i++)
        if (memcmp(s_ring[i], fp, sizeof(fp)) == 0)
            return true;                     /* 全环线性扫：64 次 memcmp 可忽略 */
    return false;
}

static void nonce_ring_add(const uint8_t *nonce, size_t n)
{
    mbedtls_sha1(nonce, n, s_ring[s_ring_head]);
    s_ring_head = (s_ring_head + 1) % AUTH_RING_SLOTS;  /* 轮转覆盖最旧 */
}
```

三条环纪律：**零锁**——esp_http_server 单线程串行处理请求（lab02 形态沿袭），环访问
天然互斥，日后若改多 worker 补一把自旋锁即可（当前形态用不到）；**只在全校验通过后
记账**——失败请求不占坑，坑位留给真正通过过的报文，重放实验的靶子才干净；**环满即
覆盖最旧**——64 槽对单客户端冒烟（窗口内几十次请求）绰绰有余，多客户端高频并发会
稀释环容量、放行个别重放，如实列为已知边界，教学形态优先可解释性。

内存预算：环 1,280B 静态 BSS + 栈上摘要上下文约 0.1KB，相对 SPEC §4 红线（推流稳态
free_dma ≥ 170KB，基线 ≈190KB）不在一个量级；启动参照 lab01/02 实测 356,211→274,975 B
（无流客户端），lab03 上线后实测 252,227→252,011 B（全程鉴权+SNTP 活动，见 14.5）。

## 14.3 时钟纪律：SNTP 治本，免鉴权对表治标

[[ch09-interop-ecosystem|第九章]]坑 1 的设备侧全文：设备无 NTP、RTC 掉电、首次开机时钟
停在纪元起点——ESP-IDF 的默认现场正是**不对时就从 1970 附近起步**。客户端摘要算得再
对，Created 落在 2026 而板钟停在 1970，窗口判据一票否决——这就是 14.4 矩阵 #7 要
主动复现的现场。

治本：**SNTP 启动对时**。上电后启动 `esp_sntp`（IDF 内置，POLL 模式 init 即发起一轮
查询；服务器 `ntp.aliyun.com` + `pool.ntp.org`），同步回调落
`$$$ ONVIF LAB03 SNTP synced epoch=<n>` 标记行，之后按 lwIP 默认周期再同步把板钟钉住。
教学开关：串口控制台 `sntp on|off`，状态落 NVS、重启保持；实测同步耗时秒级
（AUTH READY 后约 1.6s 首同步，见 14.5）。一个如实边界：NTP 服务器可达性依赖家庭 AP
出外网，不可达时 SNTP 持续失败，等效于「关」形态——实验矩阵天然覆盖这条退化路径。

**成文期假设被实测推翻的一处**：原以为「`sntp off` + 重启」即复现「时钟停在纪元」——
实测 `esp_restart()` **不清 RTC 墙钟**，SNTP 同步过的 2026 时间软重启后从上次同步值
继续走（首轮实验重启后板钟仍≈宿主钟——同步 epoch 1792947997≈17:06:37Z，探针发
17:07:23Z 的 Created 时板钟也正走到 17:07:2x，差值≈0 照样落窗）。坑 1 的「板钟停纪元」现场改由
确定性开关 `clock reset`（`settimeofday` 归零，等效 RTC 掉电起步）复现，不用重烧固件、
不受重启语义绑定。

治标：**免鉴权 GetSystemDateAndTime 如实报时**（lab02 已交付）。客户端拿板钟算偏移、
按板钟生成 Created——ch09 坑 1 的两步走原文，python-onvif-zeep 等主流库内置。设备侧
义务只有一条：报真话——板钟错就报错的值，让客户端看见真实偏差去补偿。

窗口：±300s 默认（对齐 ch04「±5 分钟量级」），Kconfig 可调。四象限预期行为：

| 设备 SNTP  | 客户端不补偿（按宿主钟）  | 客户端按板钟补偿 |
| ---------- | ------------------------- | ---------------- |
| 开（默认） | 过（双方钟都准）          | 过               |
| 关（教学） | 拒：clock_skew——坑 1 现场 | 过（治标生效）   |

恢复路径（SPEC lab03 明示「记录恢复路径」）两级：① 立即可用的治标——客户端按板钟
生成 Created（规范推荐、主流库默认行为）；② 治本——控制台 `sntp on` 重开对时（可
立即触发一轮同步，不必重启），板钟归正后不补偿的客户端也过。SetSystemDateAndTime
手动写时不在本站白名单（回 ActionNotSupported）——lab 序列没有给客户端改时配置的
入口，改时只走 SNTP，边界如实声明。

## 14.4 教学实验设计：把坑变成可复现的矩阵

[[ch11-esp32s31-lab-plan|第十一章]]11.4 说过 lab03 单独成站的理由：时钟与重放是设备侧
最容易翻车的组合，**故意搞坏比一次做对更有教学价值**。SPEC §6 lab03 的验收三件套 +
§7 第 8 条的坏 case 矩阵（加分项）合成一张九行矩阵。

工具分工——标准客户端管「能通」，原声探针管「怎么坏」：

- **python-onvif-zeep**（lab02 的第一验收客户端，[[ch09-interop-ecosystem|第九章]]
  工作流）：带凭据正向冒烟，内置时钟补偿；
- **tools/onvif_auth_probe.py**（stdlib，lab01 `onvif_probe.py` 同族规划）：nonce/
  Created/摘要三原料全部命令行可控，能精确重放（同一报文原样连发），能故意复现 ch04
  4.2 的字节坑（拿 base64 文本当 nonce 原料算摘要）。工具启动自检直接用 ch04 4.2 的
  验收向量——**字节观按 WS-Security Profile 落准**：raw nonce 是 16 字节可打印 ASCII
  `LKK0wi9cQ3ZmvQp2`，头里的 Nonce 是它的 base64 `TEtLMHdpOWNRM1ptdlFwMg==`，摘要 =
  Base64(SHA1(解码后 16 字节 + `2026-10-10T12:00:00.000Z` + `onvif-demo-pass`)) =
  `yN+RxcHPSx2u50AcC/obCm/0zIQ=`（成文期把 raw 形态误标成「nonce_b64」，按那个字面值
  解码算出的摘要对不上向量——自检在宿主上先拦下了这个坑），算不出就不许发报文——
  向量验收纪律同款。

```bash
# 原声探针用法（板 IP 以板端日志为准，DHCP 会变，勿写死）；
# 口令取 main/onvif_secrets.h 的 ONVIF_AUTH_PASS（--pass 必填，不落源码/仓库）：
PASS=$(grep -oP '(?<=ONVIF_AUTH_PASS ")[^"]+' main/onvif_secrets.h)
python3 tools/onvif_auth_probe.py <板IP> --pass "$PASS" --op GetUsers                  # 自动 nonce+按板钟对表
python3 tools/onvif_auth_probe.py <板IP> --pass "$PASS" --op GetUsers --no-auth        # 不带安全头
python3 tools/onvif_auth_probe.py <板IP> --pass wrongpass --op GetUsers                # 错口令
python3 tools/onvif_auth_probe.py <板IP> --pass "$PASS" --user ghost --op GetUsers     # 错用户名
python3 tools/onvif_auth_probe.py <板IP> --pass "$PASS" --nonce-as-text --op GetUsers  # ch04 4.2 字节坑
python3 tools/onvif_auth_probe.py <板IP> --pass "$PASS" --replay 2 --op GetUsers       # 同一报文连发两次
python3 tools/onvif_auth_probe.py <板IP> --pass "$PASS" --host-clock --op GetUsers     # Created 按宿主钟（不补偿）
```

九行矩阵（判据为设计预期；「实测」列 = 2026-10-26 上板结果，板端标记行见 14.5）：

| #   | 实验       | 条件                                   | 预期应答                 | 板端日志判据（预期）               | 实测                   |
| --- | ---------- | -------------------------------------- | ------------------------ | ---------------------------------- | ---------------------- |
| 1   | 正向基线   | 正确凭据（zeep 与探针各一轮）          | GetUsers 正常应答        | `AUTH ok user=admin`               | ✅ 两轮均过            |
| 2   | 无凭据     | `--no-auth`                            | ter:NotAuthorized        | `deny reason=no_token`             | ✅                     |
| 3   | 错口令     | `--pass wrong`                         | 同 #2                    | `deny reason=digest_mismatch`      | ✅                     |
| 4   | 错用户名   | `--user ghost`                         | 同 #2（防枚举）          | `deny reason=user_unknown`         | ✅                     |
| 5   | 字节坑     | `--nonce-as-text`                      | 同 #2                    | `deny reason=digest_mismatch`      | ✅ 与 #3 外部逐字一致  |
| 6   | 重放       | `--replay 2`（窗口内立即重发）         | 第 1 次 ok、第 2 次同 #2 | 第 2 次 `deny reason=nonce_replay` | ✅                     |
| 7   | 时钟漂移   | `sntp off`+`clock reset`，不补偿       | 同 #2                    | `deny reason=clock_skew`           | ✅                     |
| 8   | 漂移下补偿 | 同 #7 环境，探针默认按板钟生成 Created | 正常应答                 | `AUTH ok`                          | ✅ Created=1970 照样过 |
| 9   | 恢复       | `sntp on` 后不补偿重试                 | 正常应答                 | SNTP 同步日志 + `AUTH ok`          | ✅                     |

对设计的三处修订（上板才暴露）：① #7 的复现机制从「`sntp off`+重启」改为
「`sntp off`+`clock reset`」（esp_restart 不清 RTC 墙钟，见 14.3）；② 探针 `--no-auth`
初版在信封上保留了 wsse/wsu 命名空间声明，设备的 URI 判存被 xmlns 声明骗过、分因落
`bad_token` 而非 `no_token`——修探针（报文干净纪律的现场版：多余声明连分因都会带偏）；
③ #5 与 #3 的外部表现逐字节一致实测成立（同为 500 + ter:NotAuthorized，分因只在
板端）。

两个设计细节，都在防「测了个寂寞」：**重放必须在窗口内立即重发**（#6）——判据链顺序
是摘要→时钟→重放，超过 ±300s 再重放，先撞上的是 clock_skew，看到的拒绝理由就不对了；
**#5 与 #3 的外部表现必须逐字节一致**（同 Fault 同子码）——字节坑只有板端日志分得出，
这正是 ch04 4.2「设备只回 not authorized」在现场的复刻，也是把分因做进 run.log 的全部
意义。#6 的宿主侧补充证据：tcpdump 80 断面两帧对账本轮未采（sudo，可选；探针同一
body 变量原样重发由代码保证，`runs/auth-probe-*.res.1/2.xml` 与板端 ok→nonce_replay
标记行互证），留待 lab06 互通收口时三断面齐采。

标记行格式（SPEC §6 lab03 契约 `$$$ ONVIF LAB03 AUTH <result> user=<u>` 的值域展开，
reason 取值见 14.2 判据表）：

```text
$$$ ONVIF LAB03 AUTH ok user=admin
$$$ ONVIF LAB03 AUTH deny reason=digest_mismatch user=admin
```

实测后 run.log 按标记行 grep 对账，`runs/` 按操作名存 Fault 原文（SPEC §7 第 8 条加分项）。

## 14.5 实测记录

2026-10-26 实跑，板 IP=192.168.1.4（本轮 DHCP，与 lab01/02 同址）；`run.log` 全文
32.7KB 入库（`practice/onvif-labs/lab03-auth-digest/run.log`，末尾含 #7 补采标注段），
宿主侧留样 23 件入 `runs/`（探针逐 case req/res、zeep 交换、双份冒烟日志）。固件版本
`v4.5.2-78-g1cae212d-dirty`（版本串里的 hash 为构建时点提交，其后因凭据页清理该提交
被 amend 重写、hash 已变）。

**启动判据**（串口取证窗口，`serial_capture.py` 复位从头收全）：

```text
I (1854) onvif_auth: $$$ ONVIF LAB03 AUTH READY sntp=on window_s=300 ring=64x20B user=admin
I (3448) onvif_svc:  $$$ ONVIF LAB03 SVC READY http=192.168.1.4:80/onvif/device_service
I (3466) onvif_auth: $$$ ONVIF LAB03 SNTP synced epoch=1792948351
```

AUTH READY → 首同步 1.6 秒（`ntp.aliyun.com` 出外网即达）。

**正向基线（#1）**：zeep 带凭据 `GetUsers()` 过门返回单条
`user=admin level=Administrator`（`runs/zeep-GetUsers.req/res.xml`，请求里可见 zeep 自动
附上的 UsernameToken 摘要头）；原声探针正向同样 200（`AUTH ok`）。免鉴权四连在带
凭据请求下照常放行。

**坏 case 矩阵（#2–#5）**：四发全部 500 + ter:NotAuthorized（外部逐字节一致），板端
分因各行其是：

```text
I (4781) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=no_token user=-
I (4855) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=digest_mismatch user=admin   # #3 错口令
I (4942) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=user_unknown user=ghost     # #4 错用户
I (5031) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=digest_mismatch user=admin   # #5 字节坑
```

#5 与 #3 的板端 reason 相同而宿主请求原料不同（`runs/auth-probe-*.req.xml`）——
「外部不可区分、日志一眼分清」的设计目标实测成立。

**重放（#6）**：同一报文连发两次——第 1 发 `AUTH ok`（I(5121)），第 2 发 15ms 后
`AUTH deny reason=nonce_replay`（I(5136)，间隔即板端标记行时间戳差）；原文
`auth-probe-*.res.1/2.xml` 双留样。

**时钟漂移与恢复（#7–#9）**：`sntp off`（`sntp stopped`）→ `clock reset`（板钟归零，
探针读到的对表值为 `1970-01-01T00:00:02Z`）→ 未补偿请求（Created=2026-10-25T17:11:04Z）
`deny reason=clock_skew`；随后按板钟对表的请求照常通过（板端 `AUTH ok`）——客户端看
见真实偏差去补偿的治标路径成立。`sntp on` 后 1.5 秒再同步（epoch=1792948420），未补偿
请求恢复放行——治本路径成立。#7 的 Fault 原文由补采段归档（run.log 末尾
`[LOG SUPPLEMENT …]` 段，探针 `--tag skew-redo`）：
`runs/auth-probe-getusers-hostclock-host-clock-skew-redo.res.xml`（1.1 壳两件套，
faultcode s:Receiver + faultstring ter:NotAuthorized）。

**内存红线**：启动打点 stream init 前 356K/后 275K（同 lab01/02 基线）；实验窗口两端
`status` 打点 free_dma=252,227 → 252,011 B（含鉴权、SHA1、SNTP 全程活动），漂移 216B，
红线 ≥170KB 无压力——nonce 环 1,280B 静态 BSS + 栈上 blob 的预算兑现。

**计划外发现**（本轮四件）：

1. **esp_restart() 不清 RTC 墙钟**：SNTP 同步过的时间软重启后原样保留——成文期
   「`sntp off`+重启即复现坑 1」的假设被实测推翻（重启后板钟仍≈宿主钟——它从上次
   同步值 epoch 1792947997≈17:06:37Z 继续走，探针 17:07:23Z 的 Created 差值≈0 照样
   落窗），坑 1 现场改由 `clock reset`（`settimeofday` 归零）确定性复现（14.3/14.4
   已同步修订）。
2. **IDF v6.1 的 mbedTLS 是 4.x/TF-PSA-Crypto**：经典流式 SHA1 API（
   `mbedtls_sha1_starts/update/finish`）不存在，SHA1 走 `psa_hash_compute(PSA_ALG_SHA_1, …)`
   ——成文期代码草案按 3.x API 写的，首编即被编译器拦下（14.2 已按实态改写）。
3. **多余的 xmlns 声明会把分因带偏**：探针 `--no-auth` 初版信封上残留 wsse/wsu 声明，
   设备端 URI 判存被字符串匹配骗过、`no_token` 分因变成 `bad_token`——修探针（不带
   安全头就连命名空间声明一并去掉），分因回到设计值。「报文干净」不只是互通礼貌，
   还是自家排错日志的准确性前提。
4. **验收向量的字节观陷阱**：ch04 4.2 的向量 raw nonce 是 16 字节可打印 ASCII，成文期
   把它误标成 base64 形态——探针自检在宿主上直接拦下（算不出期望值不发报文），按
   规范语义（头里 `TEtLMHdpOWNRM1ptdlFwMg==`）复算精确命中（14.4 已修订）。

**已知边界实测确认**：`+00:00` 形态 Created 收（zeep 默认形态，设计修订）；非零偏移、
超长 nonce 未在本轮触发（矩阵外，仍为文档化边界）；NTP 不可达退化路径未触发
（出外网正常）。另有一处覆盖边界要如实点明：本轮六份 Fault 留样（noauth/wrongpass/
ghost/bytewrong/重放第二发/#7 补采，`runs/auth-probe-*.res*.xml`）**全是 SOAP 1.1 壳**
（faultcode/faultstring 两件套——原声探针只走 1.1），1.2 壳的 Code/Subcode(
ter:NotAuthorized) 结构本轮**未在链路上取样**（zeep 只跑了正向用例，从未吃到
Fault）——14.2 的双壳 Fault 模板两代都在固件里，1.2 侧的拒绝留样待下一站用带凭据的
zeep 主动触发一次补上。目录演进注记：本轮 run.log 对应的固件期间 GetServices 仍只列
Device 一条；「Media 条目」在 lab04 目录模板补 Media 后由重编固件交付，双条目留样见
[[ch15-lab04-media-snapshot-report|第十五章]]工程的 `runs/zeep-GetServices.res.xml`。

## 14.6 小结

- lab03 是 [[ch04-ws-security-auth|第四章]]的镜像：设备侧不发明新公式，只做 PSA
  SHA1 重算比对——PasswordDigest = Base64(SHA1(Nonce+Created+Password))，字节观三纪律
  （nonce 解码后字节、Created 原样字符串、口令 UTF-8）实测成立。
- 五环判据链（查用户→解码→重算比对→时钟窗口→重放记账）实测九发九中：对外统一
  ter:NotAuthorized、板端五种分因（no_token/digest_mismatch/user_unknown/clock_skew/
  nonce_replay）各落其位——错口令与字节坑在网络上不可区分，在 run.log 里一眼分清，
  三层对账做进设备本身。
- nonce 环：64×20B 指纹槽 = 1,280B 静态 BSS，零锁、零动态分配、只在全校验通过后
  记账；重放实验第二发 15ms 内即被拒（板端标记行时间戳），实测有效。
- 时钟纪律治本组合实测：SNTP 启动对时（首同步 1.6s）+ 免鉴权 GetSystemDateAndTime
  如实报时（1970 也照报）+ ±300s 窗口——坑 1 复现（`clock reset`）→ 治标（板钟补偿
  通过）→ 治本（`sntp on` 恢复）三级全链留证。
- 上板新账四笔（RTC 墙钟跨软重启、mbedTLS 4 的 PSA 化、xmlns 残留带偏分因、向量
  字节观）——全部反哺设计文档本身，「计划态」在实测面前逐一校准。
- 内存红线无压力：全程 free_dma ≈252KB（漂移 216B），nonce 环与 blob 全在静态 BSS/
  栈上，PSRAM 纪律未破。

门装好了，下一章回到媒体面：受保护操作从此成为常态（GetProfiles/GetSnapshotUri 都要
过 lab03 这道门），Media Profile 的单 profile（token `profile_1`、MJPEG 编码档）怎么落地、
`/onvif-http/snapshot` 怎么从最新帧双缓冲里拷出一张完整 JPEG、curl 与 python-onvif 各自
怎么验收——[[ch15-lab04-media-snapshot-report|第十五章：实战实录四——lab04，Media Profile
与快照]]。
