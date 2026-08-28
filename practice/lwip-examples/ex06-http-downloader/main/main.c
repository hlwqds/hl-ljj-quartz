/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex06 http-downloader —— 嵌入式 HTTP 客户端下载模板（裸 socket 版）
 *
 * 演示"嵌入式 HTTP 客户端的正确姿势"：
 *   1. 裸 socket 发 HTTP/1.0 GET，从 SLIRP 网关 10.0.2.2 下载宿主机 tools/serve.py
 *      动态生成的 ~5MiB 确定性伪随机内容；
 *   2. Content-Length 解析 + 分块读（每 512KB 打一条进度）；
 *   3. Fletcher-32 流式校验（边收边算，不缓存整个 body——5MiB 不可能堆上装）；
 *   4. connect/read 双计时口径（ch6 方法学）：建连耗时与净传输耗时分开报；
 *   5. 三条错误分支真实处理：
 *        a) /short.bin     —— 中途断开（服务端少发后关闭，recv 见 EOF/RST）
 *        b) /nolen.bin     —— Content-Length 缺失，退化为读到 EOF 的
 *                             length-unknown 模式，靠 X-Demo-Fletcher32 头对账
 *        c) /blackhole.bin —— 响应头之后服务端沉默，SO_RCVTIMEO 救场
 *      外加 closed-port 快速失败探针（ECONNREFUSED）；配合 README 附录的
 *      iptables 黑洞注入，同一探针还能演示 connect 显式超时分支。
 *   6. 完整关闭：读完即 close，打机器可读结果行便于 CI 化。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（SLIRP：guest 出连宿主 loopback 同端口）。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <assert.h>
#include <stdbool.h>
#include <inttypes.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_system.h"

#include "lwip/sockets.h"
#include "lwip/inet.h"
#include <netdb.h>
#include <sys/select.h>
#include <sys/time.h>

static const char *TAG = "ex06";

/* ---------------- 可调参数（模板改编点集中在这里） ---------------- */

#define SERVER_HOST          "10.0.2.2" /* SLIRP 虚拟网关 == 宿主机 loopback */
#define SERVER_PORT          8250       /* SPEC §4 ex06 号段主槽位 */
#define PROBE_PORT           8257       /* 同号段保留空槽：closed-port/connect-timeout 探针 */
#define CONNECT_DEADLINE_SEC 5          /* connect 阶段显式上限（核心教学点）*/
#define RECV_TIMEOUT_SEC     10         /* SO_RCVTIMEO：读阶段每 recv 的救场上限 */
#define REQ_TIMEOUT_SEC      10         /* SO_SNDTIMEO：发请求也不许裸奔 */

#define HDR_BUF_MAX   2048              /* 响应头累积缓冲上限 */
#define BODY_BUF_SZ   4096              /* body 流式搬运缓冲（不缓存整包的原因见 README） */
#define PROGRESS_STEP (512UL * 1024UL)  /* 每 512KB 一条进度行 */

/* ---------------- Fletcher-32 流式校验器 ----------------
 * 与 zlib fletcher32 同算法：按 little-endian u16 字累加，s1/s2 定期折叠进
 * 16bit；两侧（guest C / 宿主 python）同序同法，内容按 4 字节对齐生成，
 * 尾字节处理仅作健壮性兜底。流式版本跨 recv 分块维持同一组累加和。
 */
typedef struct {
    uint32_t s1, s2;
    uint8_t lo_pending;   /* 待凑字的低字节缓存 */
    bool has_lo;          /* 显式半字标志：不能用哨兵值（数据本身可能含 0xFF） */
    uint64_t nwords_run;  /* 自上次折叠以来累计的字数（zlib 以 359 字为一批折叠） */
    uint64_t nbytes_seen;
} fletch32_t;

static void f32_init(fletch32_t *f)
{
    memset(f, 0, sizeof(*f));
    f->s1 = f->s2 = 0xFFFF;
    f->has_lo = false;
}

static void f32_fold(fletch32_t *f)
{
    f->s1 = (f->s1 & 0xFFFF) + (f->s1 >> 16);
    f->s2 = (f->s2 & 0xFFFF) + (f->s2 >> 16);
    f->nwords_run = 0;
}

static void f32_feed(fletch32_t *f, const uint8_t *p, size_t len)
{
    f->nbytes_seen += len;
    while (len--) {
        uint8_t b = *p++;
        if (!f->has_lo) {
            f->lo_pending = b; /* 低字节先到（LE 约定与生成端一致） */
            f->has_lo = true;
            continue;
        }
        uint16_t w = (uint16_t)(b << 8) | f->lo_pending;
        f->has_lo = false;
        f->s1 += w;
        f->s2 += f->s1;
        if (++f->nwords_run >= 359) { /* 与 zlib 相同的防溢出批长 */
            f32_fold(f);
        }
    }
}

static uint32_t f32_final(fletch32_t *f)
{
    if (f->has_lo) {
        /* 悬挂低字节：补零高字节收尾（本例长度恒为 4 的倍数，正常走不到） */
        f->s1 += (uint16_t)f->lo_pending << 8;
        f->nwords_run++;
        f->has_lo = false;
    }
    while (f->nwords_run) {
        f32_fold(f);
    }
    f->s1 = (f->s1 & 0xFFFF) + (f->s1 >> 16);
    f->s2 = (f->s2 & 0xFFFF) + (f->s2 >> 16);
    return (f->s2 << 16) | f->s1;
}

/* ---------------- 计时辅助（esp_timer 1µs 网格，避开 sys_now 10ms 粗格） */

#include "esp_timer.h"

static int64_t now_us(void)
{
    return esp_timer_get_time();
}
static long us_to_ms(int64_t us)
{
    return (long)((us + 500) / 1000);
}

/* ---------------- 结果分类（CI 友好的枚举 + 机器可读标记行） --------- */

typedef enum {
    DL_OK = 0,
    DL_OK_NO_LEN,       /* 成功但走的是 EOF 定界模式（Content-Length 缺失） */
    DL_CONNECT_REFUSED,
    DL_CONNECT_TIMEOUT,
    DL_CONNECT_ERR,
    DL_TRUNCATED,       /* 中途断开：EOF/RST 时还没收满承诺字节数 */
    DL_READ_TIMEOUT,    /* SO_RCVTIMEO 救场 */
    DL_CHECKSUM_FAIL,   /* X-Demo-Fletcher32 对账失败 */
    DL_HTTP_STATUS,     /* 非 2xx 状态行 */
    DL_HEADER_TOOLONG,
} dl_status_t;

typedef struct {
    dl_status_t status;
    long bytes_got;      /* 实收 body 字节（不含响应头） */
    long bytes_want;     /* Content-Length 承诺值；-1 = 头里没给 */
    long hdr_bytes;      /* 响应头字节 */
    uint32_t f32;        /* 本地流式计算值 */
    uint32_t f32_peer;   /* 服务端 X-Demo-Fletcher32 宣称值；0 = 头里没给 */
    int http_code;       /* 状态行码；0 = 未解析出 */
    long t_connect_ms;   /* 口径一：socket()→connect() 完成（含非阻塞往返） */
    long t_hdr_ms;       /* 口径二前段：connect 完成→响应头收齐 */
    long t_xfer_ms;      /* 口径二主体：首字节 body→收尾（EOF/CL 满） */
} dl_result_t;

static const char *dl_status_name(dl_status_t s)
{
    switch (s) {
    case DL_OK: return "OK";
    case DL_OK_NO_LEN: return "OK_NO_LEN";
    case DL_CONNECT_REFUSED: return "CONNECT_REFUSED";
    case DL_CONNECT_TIMEOUT: return "CONNECT_TIMEOUT";
    case DL_CONNECT_ERR: return "CONNECT_ERR";
    case DL_TRUNCATED: return "TRUNCATED";
    case DL_READ_TIMEOUT: return "READ_TIMEOUT";
    case DL_CHECKSUM_FAIL: return "CHECKSUM_FAIL";
    case DL_HTTP_STATUS: return "HTTP_BAD_STATUS";
    default: return "HEADER_TOOLONG";
    }
}

/* 在 HDR_BUF_MAX 内忽略大小写找 header 行并取 value（教学版：够用即可） */
static bool find_header(const char *hdr, size_t hlen, const char *name, char *out, size_t outmax)
{
    size_t nlen = strlen(name);
    const char *p = hdr;
    const char *end = hdr + hlen;
    while (p < end) {
        const char *eol = memchr(p, '\n', end - p);
        if (!eol) {
            eol = end;
        }
        size_t line = eol - p;
        if (line > nlen && strncasecmp(p, name, nlen) == 0 && p[nlen] == ':') {
            const char *v = p + nlen + 1;
            while (v < eol && (*v == ' ' || *v == '\t')) {
                v++;
            }
            const char *ve = eol;
            while (ve > v && (ve[-1] == '\r' || ve[-1] == ' ')) {
                ve--;
            }
            size_t vlen = ve - v;
            if (vlen >= outmax) {
                vlen = outmax - 1;
            }
            memcpy(out, v, vlen);
            out[vlen] = '\0';
            return true;
        }
        p = eol + 1;
    }
    return false;
}

/* ---------------- 单轮下载（含完整错误分支处理） ---------------- */

typedef struct {
    const char *path;     /* GET 目标路径 */
    const char *host;     /* 目标 host（默认 10.0.2.2；探针可换） */
    int port;             /* 目标端口 */
    bool probe_only;      /* true=只测 connect 阶段，发完请求即收工 */
} dl_request_t;

static void download_round(int round, const dl_request_t *req, dl_result_t *r)
{
    memset(r, 0, sizeof(*r));
    r->bytes_want = -1;
    r->f32_peer = 0;

    ESP_LOGI(TAG, "[DL] R=%d BEGIN path=%s host=%s:%d", round, req->path, req->host, req->port);
    size_t heap0 = esp_get_free_heap_size();
    int64_t t0 = now_us();

    /* --- 1. 解析（数值地址也统一走 getaddrinfo，模板扩展到域名不用改骨架） */
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    int rc = getaddrinfo(req->host, NULL, &hints, &res); /* 服务字段在 connect 前手工填端口 */
    if (rc != 0 || res == NULL) {
        ESP_LOGE(TAG, "[DL] R=%d getaddrinfo(\"%s\") failed rc=%d", round, req->host, rc);
        r->status = DL_CONNECT_ERR;
        return;
    }
    ((struct sockaddr_in *)res->ai_addr)->sin_port = htons(req->port);

    /* --- 2. connect 阶段：非阻塞 + select 死线（教学核心）
     * lwIP 阻塞 connect 的默认放弃时间由 SYN 重传预算决定（SYNMAXRTT×RTO 背退，
     * 可达分钟级），嵌入式中必须自己封顶。做法：connect 置 O_NONBLOCK，通常立刻
     * 返回 EINPROGRESS，随后 select 写集等死线。 */
    int s = socket(res->ai_family, res->ai_socktype, IPPROTO_TCP);
    if (s < 0) {
        ESP_LOGE(TAG, "[DL] R=%d socket() failed errno=%d (%s)", round, errno, strerror(errno));
        freeaddrinfo(res);
        r->status = DL_CONNECT_ERR;
        return;
    }

    int flags = fcntl(s, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(s, F_SETFL, flags | O_NONBLOCK);
    }

    rc = connect(s, res->ai_addr, res->ai_addrlen);
    dl_status_t cstat = DL_OK;
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(s, &wfds);
        struct timeval tv = { .tv_sec = CONNECT_DEADLINE_SEC, .tv_usec = 0 };
        rc = select(s + 1, NULL, &wfds, NULL, &tv);
        if (rc == 0) {
            cstat = DL_CONNECT_TIMEOUT; /* 应用级死线触发，不等协议栈慢慢重传 */
        } else if (rc > 0) {
            int soerr = 0;
            socklen_t slen = sizeof(soerr);
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &slen);
            if (soerr != 0) {
                errno = soerr;
                cstat = (errno == ECONNREFUSED) ? DL_CONNECT_REFUSED : DL_CONNECT_ERR;
            }
        } else {
            cstat = DL_CONNECT_ERR;
        }
    } else if (rc != 0) {
        cstat = (errno == ECONNREFUSED) ? DL_CONNECT_REFUSED : DL_CONNECT_ERR;
    }

    flags = fcntl(s, F_GETFL, 0); /* 无论成败先把阻塞模式还原（错误路径也要 close 干净 fd） */
    if (flags >= 0) {
        fcntl(s, F_SETFL, flags & ~O_NONBLOCK);
    }

    r->t_connect_ms = us_to_ms(now_us() - t0);
    int64_t t_conn = now_us(); /* 精确基点：hdr 段计时从这里起算 */
    freeaddrinfo(res);

    if (cstat != DL_OK) {
        r->status = cstat;
        ESP_LOGW(TAG,
                 "[DL] R=%d RESULT status=%s errno=%d(%s) connect_ms=%ld note=\"connect 阶段失败，"
                 "deadline=%ds\"",
                 round, dl_status_name(cstat), errno, strerror(errno), r->t_connect_ms,
                 CONNECT_DEADLINE_SEC);
        close(s);
        return;
    }
    ESP_LOGI(TAG, "[DL] R=%d connected %s:%d in %ld ms", round, req->host, req->port,
             r->t_connect_ms);

    /* --- 3. 超时参数齐上：read/write 都不许裸奔（SPEC：超时必须有） */
    struct timeval tv10 = { .tv_sec = RECV_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv10, sizeof(tv10));
    tv10.tv_sec = REQ_TIMEOUT_SEC;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv10, sizeof(tv10));

    /* --- 4. 发 GET 请求（HTTP/1.0 + Connection: close，服务端回完就关） */
    char reqbuf[256];
    int reqlen = snprintf(reqbuf, sizeof(reqbuf),
                          "GET %s HTTP/1.0\r\n"
                          "Host: %s:%d\r\n"
                          "User-Agent: ex06-http-downloader/1.0 (esp32-qemu)\r\n"
                          "Accept: */*\r\n"
                          "Connection: close\r\n"
                          "\r\n",
                          req->path, req->host, req->port);
    if (send(s, reqbuf, reqlen, 0) != reqlen) {
        ESP_LOGE(TAG, "[DL] R=%d send request failed errno=%d (%s)", round, errno, strerror(errno));
        r->status = DL_CONNECT_ERR;
        close(s);
        return;
    }
    if (req->probe_only) { /* 探针模式：connect 建立即视为通过 */
        r->status = DL_OK;
        r->http_code = 200;
        ESP_LOGI(TAG, "[DL] R=%d RESULT status=CONNECT_ONLY connect_ms=%ld", round,
                 r->t_connect_ms);
        close(s);
        return;
    }

    /* --- 5. 读循环状态机：HEADER 态 → BODY 态
     * 第一块数据大概率是「头的一部分或全部+body 开头」，必须把头的边界找出来，
     * 余量转记为 body。头累积超过 HDR_BUF_MAX 判死（防御畸形服务端）。 */
    static char hdr[HDR_BUF_MAX];
    static uint8_t buf[BODY_BUF_SZ];
    size_t hlen = 0;
    bool in_body = false;
    fletch32_t f32st;
    f32_init(&f32st);
    int64_t t_first_body = 0;
    int64_t t_end_body = 0;

    for (;;) {
        int n = recv(s, in_body ? (char *)buf : hdr + hlen,
                     in_body ? sizeof(buf) : (int)(HDR_BUF_MAX - hlen), 0);
        if (n < 0) {
            int e = errno;
            if (e == EAGAIN || e == EWOULDBLOCK) {
                r->status = in_body ? DL_READ_TIMEOUT : DL_CONNECT_ERR;
                ESP_LOGW(TAG, "[DL] R=%d recv timeout after %ds: "
                              "got=%ld want=%ld（SO_RCVTIMEO 救场，连读静默服务端）",
                         round, RECV_TIMEOUT_SEC, r->bytes_got, r->bytes_want);
            } else {
                r->status = DL_TRUNCATED; /* ECONNRESET 等：连接被硬断 */
                ESP_LOGW(TAG, "[DL] R=%d recv error errno=%d (%s): got=%ld want=%ld", round, e,
                         strerror(e), r->bytes_got, r->bytes_want);
            }
            break;
        }
        if (n == 0) { /* EOF */
            if (!in_body) {
                r->status = DL_TRUNCATED;
                ESP_LOGW(TAG, "[DL] R=%d EOF before headers complete hlen=%zu", round, hlen);
            } else if (r->bytes_want >= 0 && r->bytes_got < r->bytes_want) {
                r->status = DL_TRUNCATED;
                ESP_LOGW(TAG,
                         "[DL] R=%d TRUNCATED: EOF at got=%ld but Content-Length=%ld "
                         "(少发 %ld B 后断开)",
                         round, r->bytes_got, r->bytes_want, r->bytes_want - r->bytes_got);
            } else if (r->bytes_want < 0) {
                /* 无 CL 头：以 EOF 为界，头里的 X-Demo-Fletcher32 对账定案 */
                r->f32 = f32_final(&f32st);
                if (r->f32_peer != 0 && r->f32_peer != r->f32) {
                    r->status = DL_CHECKSUM_FAIL;
                } else {
                    r->status = DL_OK_NO_LEN;
                }
                t_end_body = now_us();
                r->t_xfer_ms = us_to_ms(t_end_body - t_first_body);
            } else {
                r->status = DL_OK;
                r->f32 = f32_final(&f32st);
                t_end_body = now_us();
                r->t_xfer_ms = us_to_ms(t_end_body - t_first_body);
            }
            break;
        }

        if (!in_body) {
            hlen += n;
            char *head_end = NULL;
            for (size_t i = 0; i + 3 < hlen; i++) {
                if (hdr[i] == '\r' && hdr[i + 1] == '\n' && hdr[i + 2] == '\r'
                    && hdr[i + 3] == '\n') {
                    head_end = hdr + i + 4;
                    break;
                }
            }
            if (!head_end) {
                if (hlen >= HDR_BUF_MAX) {
                    ESP_LOGE(TAG, "[DL] R=%d response header exceeds %dB, abort", round,
                             HDR_BUF_MAX);
                    r->status = DL_HEADER_TOOLONG;
                    break;
                }
                continue; /* 头还没完，继续攒 */
            }

            /* 解析状态行 */
            if (hlen >= 12 && strncmp(hdr, "HTTP/", 5) == 0) {
                r->http_code = atoi(hdr + 9);
            }
            /* 解析关键头 */
            char val[80];
            if (find_header(hdr, head_end - hdr, "Content-Length", val, sizeof(val))) {
                r->bytes_want = atol(val);
            }
            if (find_header(hdr, head_end - hdr, "X-Demo-Fletcher32", val, sizeof(val))) {
                r->f32_peer = (uint32_t)strtoul(val, NULL, 16);
            }

            size_t blen = hlen - (size_t)(head_end - hdr); /* 首块夹带的 body 前缀 */
            r->hdr_bytes = (long)(head_end - hdr);
            ESP_LOGI(TAG,
                     "[DL] R=%d status=%d content_length=%ld x_demo_fletcher32=%08" PRIx32
                     " hdr_bytes=%ld",
                     round, r->http_code, r->bytes_want, r->f32_peer, r->hdr_bytes);

            if (r->http_code < 200 || r->http_code >= 300) {
                r->status = DL_HTTP_STATUS;
                break;
            }

            in_body = true;
            t_first_body = now_us();
            r->t_hdr_ms = us_to_ms(t_first_body - t_conn);
            if (blen) {
                f32_feed(&f32st, (const uint8_t *)head_end, blen);
                r->bytes_got += blen;
                ESP_LOGI(TAG, "[DL] R=%d progress %lu KB / first-chunk carry %zuB", round,
                         r->bytes_got / 1024, blen);
            }
            continue;
        }

        /* BODY 态主流：计数 + 流式校验 + 每 512KB 进度 */
        f32_feed(&f32st, buf, (size_t)n);
        r->bytes_got += n;

        if (r->bytes_got / PROGRESS_STEP >
            (r->bytes_got - n) / PROGRESS_STEP) { /* 刚跨过 512KB 边界才打 */
            ESP_LOGI(TAG, "[DL] R=%d progress %lu KB", round,
                     (unsigned long)(r->bytes_got / 1024));
        }

        if (r->bytes_want >= 0 && r->bytes_got >= r->bytes_want) {
            r->status = DL_OK;
            r->f32 = f32_final(&f32st);
            t_end_body = now_us();
            r->t_xfer_ms = us_to_ms(t_end_body - t_first_body);
            break; /* 收满即止：HTTP/1.0 + Connection:close，尾部不会有下一响应 */
        }
    }

    /* 校验对账（CL 已知且成功路径之外的补算） */
    if (r->status == DL_OK) {
        if (r->f32_peer != 0 && r->f32_peer != r->f32) {
            r->status = DL_CHECKSUM_FAIL;
            ESP_LOGE(TAG, "[DL] R=%d CHECKSUM MISMATCH local=%08" PRIx32 " peer=%08" PRIx32, round,
                     r->f32, r->f32_peer);
        } else {
            ESP_LOGI(TAG, "[DL] R=%d checksum ok: %08" PRIx32, round, r->f32);
        }
    }

    /* --- 6. 完整关闭：全双工 shutdown 再 close（服务端 1.0 也正关着） */
    shutdown(s, SHUT_RDWR);
    close(s);

    /* 统一结果行：机器可读（CI 抓取），附双计时吞吐 */
    double mbit = (r->t_xfer_ms > 0)
                      ? ((double)r->bytes_got * 8.0 / 1000.0 / 1000.0)
                            / ((double)r->t_xfer_ms / 1000.0)
                      : 0.0;
    ESP_LOGI(TAG,
             "[DL] R=%d RESULT status=%s bytes=%ld/%ld f32_local=%08" PRIx32
             " f32_peer=%08" PRIx32 " connect_ms=%ld hdr_ms=%ld xfer_ms=%ld mbit=%.1f",
             round, dl_status_name(r->status), r->bytes_got, r->bytes_want, r->f32, r->f32_peer,
             r->t_connect_ms, r->t_hdr_ms, r->t_xfer_ms, mbit);

    size_t heap1 = esp_get_free_heap_size();
    ESP_LOGI(TAG, "[DL] R=%d heap free %u -> %u (delta=%d)", round, heap0, heap1,
             (int)heap0 - (int)heap1);
}

/* ---------------- 自动演示时刻表（一轮启动跑全部分支） ---------------- */

static void download_task(void *arg)
{
    dl_result_t r;
    /* 双 good 交错坏轮次：证明错误分支处理后系统回到正常轨道（ch6 方法学回声） */
    dl_request_t plan[] = {
        { "/good.bin", SERVER_HOST, SERVER_PORT, false },   /* 正常满血下载 × 计时基准 */
        { "/short.bin", SERVER_HOST, SERVER_PORT, false },  /* 分支②：中途断开 */
        { "/good.bin", SERVER_HOST, SERVER_PORT, false },   /* 回归正常（交错验证） */
        { "/nolen.bin", SERVER_HOST, SERVER_PORT, false },  /* 分支③：CL 缺失 */
        { "/blackhole.bin", SERVER_HOST, SERVER_PORT, false }, /* 附赠：读静默超时救场 */
        { "/probe", SERVER_HOST, PROBE_PORT, true },        /* closed-port 快速失败探针 */
    };
    const char *plan_note[] = { "基准", "错误分支TRUNCATED", "交错回归", "错误分支NO_LEN",
                                "错误分支READ_TIMEOUT", "CLOSED-PORT探针(经iptables可变TIMEOUT)" };

    ESP_LOGI(TAG, "== download schedule: %u rounds ==",
             (unsigned)(sizeof(plan) / sizeof(plan[0])));
    unsigned ok = 0, fail = 0;
    double mbit_acc = 0;
    unsigned mbit_n = 0;

    for (unsigned i = 0; i < sizeof(plan) / sizeof(plan[0]); i++) {
        ESP_LOGI(TAG, "-- round %u: %s (%s)", i + 1, plan[i].path, plan_note[i]);
        download_round((int)i + 1, &plan[i], &r);
        bool pass = (r.status == DL_OK || r.status == DL_OK_NO_LEN);
        if (pass) {
            ok++;
            /* 只累计成功的大块下载做吞吐平均（探针与坏轮次不掺水） */
            if (r.t_xfer_ms > 0 && r.bytes_got > 1024 * 1024) {
                mbit_acc += (double)r.bytes_got * 8.0 / 1000.0 / 1000.0
                            / ((double)r.t_xfer_ms / 1000.0);
                mbit_n++;
            }
        } else {
            fail++;
        }
    }

    ESP_LOGI(TAG,
             "[EX06] SUMMARY ok=%u fail=%u avg_mbit_good=%.1f avg_rounds=%u host=%s:%d",
             ok, fail, mbit_n ? mbit_acc / mbit_n : 0.0, mbit_n, SERVER_HOST, SERVER_PORT);
    ESP_LOGI(TAG, "[EX06] PHASE=DONE -- all branches exercised, restarting to exit QEMU");
    vTaskDelay(pdMS_TO_TICKS(3000)); /* 让 SUMMARY 有机会从 UART 冲刷出去 */
    esp_restart(); /* 主动复位退出 QEMU（-no-reboot 时进程干净结束，退出码合法） */
}

/* ---------------- openeth bring-up（ch3/ch24 沉淀的标准 15 步） -------------- */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "[EX06] ETH START");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[EX06] ETH CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[EX06] ETH DISCONNECTED (link down)");
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "[EX06] GOT_IP " IPSTR " gw " IPSTR, IP2STR(&evt->ip_info.ip),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex06 http-downloader (bare socket HTTP client) ==");
    ESP_LOGI(TAG, "[EX06] build " __DATE__ " " __TIME__);

    /* 1. esp_netif_init 必须是第一句网络调用（tcpip 邮箱在此建立） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;          /* 虚拟 PHY 无复位脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(
        esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &ip_event_handler,
                                               NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "[EX06] DHCP timeout after 15s -- check QEMU -nic");
        return;
    }
    ESP_LOGI(TAG, "[EX06] PHASE=READY target=%s:%d", SERVER_HOST, (int)SERVER_PORT);

    xTaskCreate(download_task, "dl_task", 4096, NULL, 5, NULL);
}
