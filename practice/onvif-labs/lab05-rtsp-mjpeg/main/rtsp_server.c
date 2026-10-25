/*
 * rtsp_server.c — raw socket RTSP 状态机 + RFC 2435 MJPEG/RTP（lab05；契约 = ch16 / SPEC §6 lab05）。
 *
 * 形态：8554/tcp 串行单客户端；信令五方法白名单；传输双档（TCP interleaved 优先——
 * 一条连接全搞定，UDP 第二档伺候 ffmpeg 默认）；60s 空闲单方面 TEARDOWN。
 * 封包：RFC 2435 缩略格式——量化表带内（Q=255：MBZ(4)+Precision(1)+Length(2)+128B
 * 纯系数 = 135B，从编码器 DQT 段剥 Pq|Tq 后逐表拷 64B 系数）；熵数据 = SOS 段后至 EOI
 * 前；type 0 = 4:2:2（板上 SOF 实测 Y 2x1 / U 1x1 / V 1x1，逐字节证据见 run.log 补录）；
 * 无 DRI 合规（type 0 禁重启标记）。1400B 载荷避开 IP 分片。
 * 消费者纪律：copy_latest_id 30ms 轮询 + frame_id 去重——只丢整帧、绝不半帧，不碰
 * frame_sem（不改变 /stream 对照面的唤醒节拍）。
 */
#include "rtsp_server.h"
#include "factory_demo_stream.h"

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "lwip/sockets.h"
#include <string.h>
#include <stdlib.h>

#define RTSP_PORT           8554
#define RTP_PAYLOAD_MAX     1400   /* IP20+TCP20+$4+RTP12+JPEG8+1400 = 1464 < 1500 */
#define SESSION_TIMEOUT_S   60
#define FRAME_POLL_MS       30
#define RTSP_BUF            1024
#define FRAME_BUF           (300 * 1024)
#define RTCP_CH             1

static const char *TAG = "rtsp_server";

typedef enum { TRANSPORT_TCP, TRANSPORT_UDP } transport_t;

/* 单客户端、逐连接串行：状态全静态，无并发会话 */
static int s_listen = -1;
static char *s_frame;   /* PSRAM：最新成品 JPEG 拷贝落点 */
static char *s_pkt;     /* PSRAM：最大 RTP 包组装（12+8+135+1400 = 1555） */

typedef struct {
    int conn;
    int udp_sock;
    struct sockaddr_in peer;
    transport_t transport;
    uint8_t rtp_ch;
    char session_id[16];
    bool playing;
    int64_t last_activity;
    uint16_t seq;
    uint32_t rtptime;
    uint32_t frames_sent;
    uint32_t last_frame_id;
    bool have_fid;
} rtsp_sess_t;

static rtsp_sess_t s_sess = { .conn = -1, .udp_sock = -1 };

static void heap3(const char *at)
{
    ESP_LOGI(TAG, "heap@%s free_dma=%u free_internal=%u free_spiram=%u", at,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
}

static void sess_reset(rtsp_sess_t *s)
{
    if (s->conn >= 0) {
        close(s->conn);
        s->conn = -1;
    }
    if (s->udp_sock >= 0) {
        close(s->udp_sock);
        s->udp_sock = -1;
    }
    s->playing = false;
    s->have_fid = false;
}

/* 读一个以 \r\n\r\n 结尾的信令报文（timeout_ms 内无完整报文视为空闲/断开）。
 * 返回报文字节数；超时/对端关闭返回 -1。 */
static int read_request(int sock, char *buf, size_t max, int timeout_ms)
{
    size_t got = 0;
    int64_t deadline = esp_timer_get_time() + (int64_t)timeout_ms * 1000LL;
    while (got < max - 1) {
        fd_set r;
        FD_ZERO(&r);
        FD_SET(sock, &r);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 100 * 1000 };
        int64_t left = deadline - esp_timer_get_time();
        if (left <= 0) {
            return got ? (int)got : -1; /* 有半截按空闲处理 */
        }
        tv.tv_usec = (left % 1000000LL);
        tv.tv_sec = (long)(left / 1000000LL);
        if (select(sock + 1, &r, NULL, NULL, &tv) <= 0) {
            continue;
        }
        ssize_t n = recv(sock, buf + got, max - 1 - got, 0);
        if (n <= 0) {
            return -1;
        }
        got += (size_t)n;
        buf[got] = '\0';
        if (strstr(buf, "\r\n\r\n") != NULL || strstr(buf, "\n\n") != NULL) {
            return (int)got;
        }
    }
    return (int)got;
}

static bool hdr_get(const char *req, const char *field, char *out, size_t out_max)
{
    const char *p = strcasestr(req, field);
    if (p == NULL) {
        return false;
    }
    p += strlen(field);
    while (*p == ' ') {
        p++;
    }
    size_t n = 0;
    while (*p != '\0' && *p != '\r' && *p != '\n' && n + 1 < out_max) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return n > 0;
}

/* RTSP 应答：CSeq 回显 + 可选附加头（Session/RTP-Info/Public） */
static void send_resp(int sock, const char *cseq, const char *extra)
{
    char resp[512];
    int n = snprintf(resp, sizeof(resp),
                     "RTSP/1.0 200 OK\r\nCSeq: %s\r\n%s\r\n",
                     cseq != NULL ? cseq : "0", extra != NULL ? extra : "");
    send(sock, resp, (size_t)n, 0);
}

/* 从 JPEG 里定位熵数据与量化表，组装 RFC 2435 的两种帧内头。
 * 返回 false = 报文形态解析不了（缺 SOF/SOS/DQT），该帧跳过。 */
static bool jpeg_parse_for_rtp(const uint8_t *jpeg, size_t len, size_t *scan_off,
                               size_t *scan_len, uint8_t *qhdr, size_t *qhdr_len)
{
    size_t i = 2, coeffs = 0;
    bool got_sos = false;
    while (i + 3 < len && jpeg[i] == 0xFF) {
        uint8_t m = jpeg[i + 1];
        if (m == 0xD9) { /* EOI：熵数据在它前面结束 */
            *scan_off = 0;
            *scan_len = i - *scan_off;
            return got_sos;
        }
        uint16_t seglen = (uint16_t)((jpeg[i + 2] << 8) | jpeg[i + 3]);
        if (m == 0xDB) { /* DQT：逐表剥 Pq|Tq 字节，只拷 64B 系数（zig-zag 序） */
            size_t p = i + 4, end = i + 2 + seglen;
            while (p + 64 <= end) {
                memcpy(qhdr + 4 + coeffs, jpeg + p + 1, 64);
                coeffs += 64;
                p += 65;
            }
        }
        if (m == 0xDA) { /* SOS：熵数据从段后开始 */
            *scan_off = i + 2 + seglen;
            *scan_len = len - *scan_off;
            if (*scan_len >= 2 && jpeg[len - 2] == 0xFF && jpeg[len - 1] == 0xD9) {
                *scan_len -= 2; /* 剥 EOI */
            }
            got_sos = true;
            break;
        }
        i += 2 + seglen;
    }
    if (!got_sos || coeffs == 0 || coeffs > 128) {
        return false;
    }
    /* RFC 2435 §3.1.8 / ffmpeg rtpenc_jpeg：MBZ(1)+Precision(1)+Length(2)+系数
     * （Length = 64×表数 = 128；总块 4+128 = 132B；Pq|Tq 字节不进表数据） */
    *qhdr_len = 4 + coeffs;
    qhdr[0] = 0; /* MBZ */
    qhdr[1] = 0; /* Precision：8bit */
    qhdr[2] = (uint8_t)(coeffs >> 8);
    qhdr[3] = (uint8_t)(coeffs & 0xFF);
    return true;
}

static void put_be16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void put_be24(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 16);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)v;
}

static void put_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

/* 一帧 = RTP 头(12) + RFC 2435 主 JPEG 头(8) + [量化头 135（仅首包）] + 熵数据切片；
 * TCP 档外加 $ 交织帧头(4)。逐字段依据见 ch16 §16.3。 */
static void rtp_send_frame(rtsp_sess_t *s, const uint8_t *jpeg, size_t jpeg_len)
{
    size_t scan_off = 0, scan_len = 0, qhdr_len = 0;
    uint8_t qhdr[132];
    if (!jpeg_parse_for_rtp(jpeg, jpeg_len, &scan_off, &scan_len, qhdr, &qhdr_len)) {
        ESP_LOGW(TAG, "jpeg parse failed, frame skipped");
        return;
    }

    s->rtptime += 6000; /* 90kHz / 15fps 档，帧内所有分片共享同一时间戳 */
    size_t off = 0;
    bool first = true;
    do {
        size_t hdr_len = 12 + 8 + (first ? qhdr_len : 0);
        size_t slice = RTP_PAYLOAD_MAX - (hdr_len - 12 - 8) - (first ? 0 : 0);
        slice = first ? (RTP_PAYLOAD_MAX - qhdr_len) : RTP_PAYLOAD_MAX;
        if (slice > scan_len - off) {
            slice = scan_len - off;
        }
        bool last = (off + slice == scan_len);

        uint8_t *pkt = (uint8_t *)s_pkt;
        /* RTP 头（12B）：v=2, PT=26, seq, ts, ssrc */
        pkt[0] = 0x80;
        pkt[1] = 26 | (last ? 0x80 : 0x00); /* M 位 = 帧末包 */
        put_be16(pkt + 2, s->seq++);
        put_be32(pkt + 4, s->rtptime);
        put_be32(pkt + 8, 0x12345678); /* SSRC（单会话固定值） */
        /* RFC 2435 主 JPEG 头（8B） */
        pkt[12] = 0;                 /* type-specific：逐行扫描 */
        put_be24(pkt + 13, (uint32_t)off); /* 帧内偏移（熵数据相对，大端） */
        pkt[16] = 0;                 /* type 0 = 4:2:2（板上 SOF 实测对齐） */
        pkt[17] = 255;               /* Q=255：量化表带内（本包首帧携带） */
        pkt[18] = 80;                /* width/8 = 640/8 */
        pkt[19] = 60;                /* height/8 = 480/8 */
        size_t pkt_len = 20;
        if (first) {
            memcpy(pkt + 20, qhdr, qhdr_len);
            pkt_len += qhdr_len;
        }
        memcpy(pkt + pkt_len, jpeg + scan_off + off, slice);
        pkt_len += slice;

        if (s->transport == TRANSPORT_TCP) {
            uint8_t fh[4] = { '$', s->rtp_ch, (uint8_t)(pkt_len >> 8), (uint8_t)pkt_len };
            if (send(s->conn, fh, sizeof(fh), 0) < 0 ||
                send(s->conn, pkt, pkt_len, 0) < 0) {
                s->playing = false; /* 对端断了：退出流循环，交上层回收 */
                return;
            }
        } else {
            if (sendto(s->udp_sock, pkt, pkt_len, 0,
                       (struct sockaddr *)&s->peer, sizeof(s->peer)) < 0) {
                s->playing = false;
                return;
            }
        }

        off += slice;
        first = false;
    } while (off < scan_len);

    s->frames_sent++;
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 FRAME seq=%u bytes=%zu", s->frames_sent, scan_len);
}

/* 流媒体期间非阻塞窥探控制面（保活/TEARDOWN）；返回 -1 = 连接断开 */
static int rtsp_poll_control(rtsp_sess_t *s)
{
    fd_set r;
    FD_ZERO(&r);
    FD_SET(s->conn, &r);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 0 };
    if (select(s->conn + 1, &r, NULL, NULL, &tv) <= 0) {
        return 0;
    }
    char buf[RTSP_BUF];
    int n = read_request(s->conn, buf, sizeof(buf), 200);
    if (n <= 0) {
        return -1;
    }
    s->last_activity = esp_timer_get_time();
    char cseq[16] = "0";
    hdr_get(buf, "CSeq:", cseq, sizeof(cseq));
    if (strstr(buf, "TEARDOWN") != NULL) {
        send_resp(s->conn, cseq, NULL);
        s->playing = false;
        ESP_LOGI(TAG, "TEARDOWN by client");
        return 0;
    }
    /* OPTIONS/SET_PARAMETER 等一律 200（保活语义，ch06 6.5） */
    send_resp(s->conn, cseq, NULL);
    return 0;
}

static void stream_loop(rtsp_sess_t *s)
{
    s->playing = true;
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 PLAY seq=%u rtptime=%u", s->seq, s->rtptime);
    heap3("PLAYING");
    while (s->playing) {
        if (rtsp_poll_control(s) < 0) {
            break;
        }
        int64_t now = esp_timer_get_time();
        if (now - s->last_activity > (int64_t)SESSION_TIMEOUT_S * 1000000LL) {
            ESP_LOGI(TAG, "idle %ds, single-side TEARDOWN", SESSION_TIMEOUT_S);
            break;
        }
        uint32_t fid = 0;
        ssize_t n = factory_stream_copy_latest_id((uint8_t *)s_frame, FRAME_BUF, &fid);
        if (n <= 0) {
            vTaskDelay(pdMS_TO_TICKS(FRAME_POLL_MS));
            continue;
        }
        if (s->have_fid && fid == s->last_frame_id) {
            vTaskDelay(pdMS_TO_TICKS(FRAME_POLL_MS));
            continue; /* 同一帧不重发：只丢整帧、绝不半帧 */
        }
        s->last_frame_id = fid;
        s->have_fid = true;
        rtp_send_frame(s, (const uint8_t *)s_frame, (size_t)n);
    }
    heap3("TEARDOWN");
}

/* SETUP：解析 Transport 头，双档匹配；会话建立 */
static void handle_setup(rtsp_sess_t *s, const char *req, const char *cseq)
{
    char tr[256] = {0};
    hdr_get(req, "Transport:", tr, sizeof(tr));
    struct sockaddr_storage peer_ss = {0};
    socklen_t plen = sizeof(peer_ss);
    getpeername(s->conn, (struct sockaddr *)&peer_ss, &plen);
    memcpy(&s->peer, &peer_ss, sizeof(s->peer));

    char extra[256] = {0};
    if (strstr(tr, "RTP/AVP/TCP") != NULL) {
        s->transport = TRANSPORT_TCP;
        s->rtp_ch = 0;
        snprintf(extra, sizeof(extra),
                 "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"
                 "Session: %s;timeout=%d\r\n", s->session_id, SESSION_TIMEOUT_S);
    } else if (strstr(tr, "RTP/AVP") != NULL) {
        s->transport = TRANSPORT_UDP;
        char ports[32] = "5000-5001";
        char *cp = strcasestr(tr, "client_port=");
        if (cp != NULL) {
            snprintf(ports, sizeof(ports), "%s", cp + strlen("client_port="));
        }
        int lo = atoi(ports);
        s->peer.sin_port = htons((uint16_t)lo);
        s->udp_sock = lwip_socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in local = {0};
        local.sin_family = AF_INET;
        local.sin_port = htons(8556); /* server_port（设计预留，避开端口表） */
        bind(s->udp_sock, (struct sockaddr *)&local, sizeof(local));
        snprintf(extra, sizeof(extra),
                 "Transport: RTP/AVP;unicast;client_port=%s;server_port=8556-8557\r\n"
                 "Session: %s;timeout=%d\r\n", ports, s->session_id, SESSION_TIMEOUT_S);
    } else {
        snprintf(extra, sizeof(extra), "Session: %s;timeout=%d\r\n", s->session_id,
                 SESSION_TIMEOUT_S);
    }
    send_resp(s->conn, cseq, extra);
    s->last_activity = esp_timer_get_time();
    ESP_LOGI(TAG, "SETUP transport=%s", s->transport == TRANSPORT_TCP ? "TCP" : "UDP");
    heap3("SETUP");
}

static void handle_describe(rtsp_sess_t *s, const char *cseq)
{
    factory_stream_status_t st = {0};
    factory_stream_get_status(&st);
    const char *ip = st.ip[0] ? st.ip : "0.0.0.0";
    char sdp[512];
    int n = snprintf(sdp, sizeof(sdp),
                     "v=0\r\n"
                     "o=- %u 1 IN IP4 %s\r\n"
                     "s=ONVIF LAB05 MJPEG\r\n"
                     "c=IN IP4 0.0.0.0\r\n"
                     "t=0 0\r\n"
                     "a=control:rtsp://%s:8554/mjpeg\r\n"
                     "m=video 0 RTP/AVP 26\r\n"
                     "a=control:rtsp://%s:8554/mjpeg/trackID=0\r\n",
                     (unsigned)(esp_random() & 0x7FFFFFFF), ip, ip, ip);
    char head[128];
    int hn = snprintf(head, sizeof(head),
                      "Content-Type: application/sdp\r\nContent-Length: %d\r\n", n);
    char resp[128];
    int rn = snprintf(resp, sizeof(resp), "RTSP/1.0 200 OK\r\nCSeq: %s\r\n", cseq);
    send(s->conn, resp, (size_t)rn, 0);
    send(s->conn, head, (size_t)hn, 0);
    send(s->conn, "\r\n", 2, 0);
    send(s->conn, sdp, (size_t)n, 0);
    ESP_LOGI(TAG, "DESCRIBE -> SDP %d bytes", n);
}

static void rtsp_handle_connection(int conn)
{
    char buf[RTSP_BUF];
    rtsp_sess_t *s = &s_sess;
    s->conn = conn;
    s->playing = false;
    s->frames_sent = 0;
    s->seq = 0;
    s->rtptime = 0;
    s->last_activity = esp_timer_get_time();

    while (s->playing == false) {
        int n = read_request(conn, buf, sizeof(buf), SESSION_TIMEOUT_S * 1000);
        if (n <= 0) {
            ESP_LOGI(TAG, "idle/EOF before PLAY, closing");
            return;
        }
        s->last_activity = esp_timer_get_time();
        char cseq[16] = "0";
        hdr_get(buf, "CSeq:", cseq, sizeof(cseq));
        if (strstr(buf, "OPTIONS") != NULL) {
            send_resp(conn, cseq,
                      "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n");
        } else if (strstr(buf, "DESCRIBE") != NULL) {
            handle_describe(s, cseq);
        } else if (strstr(buf, "SETUP") != NULL) {
            uint8_t sid[4];
            esp_fill_random(sid, sizeof(sid));
            snprintf(s->session_id, sizeof(s->session_id),
                     "%02x%02x%02x%02x", sid[0], sid[1], sid[2], sid[3]);
            handle_setup(s, buf, cseq);
        } else if (strstr(buf, "PLAY") != NULL) {
            char extra[160];
            snprintf(extra, sizeof(extra),
                     "RTP-Info: url=rtsp://*/mjpeg;seq=%u;rtptime=%u\r\n"
                     "Session: %s\r\n", (unsigned)s->seq, (unsigned)s->rtptime,
                     s->session_id);
            send_resp(conn, cseq, extra);
            stream_loop(s); /* 阻塞到 TEARDOWN/空闲/断连 */
            return;
        } else {
            send_resp(conn, cseq, NULL);
        }
    }
}

static void rtsp_server_task(void *arg)
{
    s_listen = lwip_socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(RTSP_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    int on = 1;
    lwip_setsockopt(s_listen, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    if (lwip_bind(s_listen, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        lwip_listen(s_listen, 1) < 0) {
        ESP_LOGE(TAG, "listen :%d failed", RTSP_PORT);
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 RTSP LISTENING port=8554");
    heap3("LISTENING");

    for (;;) {
        struct sockaddr_in peer = {0};
        socklen_t plen = sizeof(peer);
        int conn = lwip_accept(s_listen, (struct sockaddr *)&peer, &plen);
        if (conn < 0) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        ESP_LOGI(TAG, "client %s:%d", inet_ntoa(peer.sin_addr), ntohs(peer.sin_port));
        rtsp_handle_connection(conn); /* 逐连接串行：PLAY 结束后才 accept 下一个 */
        sess_reset(&s_sess);
    }
}

void rtsp_server_init(void)
{
    s_frame = heap_caps_malloc(FRAME_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_pkt = heap_caps_malloc(12 + 8 + 135 + RTP_PAYLOAD_MAX + 8,
                             MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_frame == NULL || s_pkt == NULL) {
        ESP_LOGE(TAG, "rtsp buffers alloc failed");
        return;
    }
    if (xTaskCreate(rtsp_server_task, "rtsp_srv", 8192, NULL, 8, NULL) != pdPASS) {
        ESP_LOGE(TAG, "rtsp task create failed");
    }
}
