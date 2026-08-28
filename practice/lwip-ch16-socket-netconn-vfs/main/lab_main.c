/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十六）实验工程：socket / netconn / VFS
 *
 * 基于系列 ch3 联网模板（openeth bring-up + DHCP），在本章中：
 *   A. 分层成本标定：同一 TCP echo 收发（64B RTT / 突发吞吐），socket vs netconn 各 3 轮。
 *      全部走 127.0.0.1 loopback（2.2.0-dev 内建于 ip4_route 特判），排除 SLIRP 干扰，
 *      度量的是纯 API 层深度差异（client + server 两端各差一层 socket/netconn 包装）。
 *   B. VFS 集成验证：accept 返回的 fd 值域(>=54)、fstat(S_IFSOCK)、用 POSIX read/write
 *      操作 socket fd、poll 双连接就绪检测。
 *   C. 故障注入·fd 耗尽：循环 socket() 直到失败，观察 ENFILE 临界与 errno 序列，
 *      以及 close 后槽位回收延迟（重试扫描计时）。
 *   D. 故障注入·阻塞 recv 的窒息：对端连上后不发数据，阻塞 recv 挂死；
 *      SO_RCVTIMEO / O_NONBLOCK / select 三种逃生对照 + 跨任务 close 解救时延实测。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8018-:8888（hostfwd 仅保留模板习惯）
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <assert.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"
#include <arpa/inet.h>
#include <sys/fcntl.h>
#include <sys/stat.h>
#include <sys/poll.h>

/* netconn API（第二层） */
#include "lwip/api.h"
/* BSD socket API（第三层，经 IDF VFS 分派到 lwip_*） */
#include "lwip/sockets.h"

static const char *TAG = "ch16lab";

#define DHCP_TIMEOUT_MS 10000

#define PORT_SOCK_ECHO  9001   /* 实验 A socket 自环 */
#define PORT_NC_ECHO    9002   /* 实验 A netconn 自环 */
#define PORT_VFS        9003   /* 实验 B */
#define PORT_SILENT     9004   /* 实验 D：只 accept 永不回发 */

static SemaphoreHandle_t s_got_ip;

static inline int64_t now_us(void) { return esp_timer_get_time(); }

/* ======================= 事件处理（ch3 模板原样） ======================= */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_START:       ESP_LOGI(TAG, "ETH_EVENT: START"); break;
    case ETHERNET_EVENT_STOP:        ESP_LOGI(TAG, "ETH_EVENT: STOP"); break;
    case ETHERNET_EVENT_CONNECTED:   ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)"); break;
    case ETHERNET_EVENT_DISCONNECTED:ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED (link down)"); break;
    default: ESP_LOGI(TAG, "ETH_EVENT: id=%ld", (long)event_id); break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* ======================= echo 服务端（socket 版 / netconn 版） ======================= */

typedef struct {
    int port;
    int echo;          /* 1=正常回显；0=只吞数据(silent) */
    volatile int ready;
} srv_arg_t;

static void socket_echo_task(void *arg)
{
    srv_arg_t *sa = (srv_arg_t *)arg;
    struct sockaddr_in local = {
        .sin_family = AF_INET,
        .sin_port   = htons(sa->port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    int lfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(lfd >= 0);
    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    assert(bind(lfd, (struct sockaddr *)&local, sizeof(local)) == 0);
    assert(listen(lfd, 4) == 0);

    if (sa->port == PORT_SOCK_ECHO) {
        /* 记录监听 fd 值域证据 */
        printf("[VFS] listen fd=%d (expect >= LWIP_SOCKET_OFFSET)\n", lfd);
    }
    sa->ready = 1;

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { ESP_LOGE(TAG, "accept err %d", errno); continue; }
        char buf[1600];
        for (;;) {
            /* 循环凑满/耗尽，回显 */
            int n = recv(cfd, buf, sizeof(buf), 0);
            if (n <= 0) break;
            if (sa->echo) {
                int off = 0;
                while (off < n) {
                    int w = send(cfd, buf + off, n - off, 0);
                    if (w <= 0) goto out;
                    off += w;
                }
            }
        }
out:
        close(cfd);
    }
}

static void netconn_echo_task(void *arg)
{
    srv_arg_t *sa = (srv_arg_t *)arg;
    struct netconn *lconn = netconn_new(NETCONN_TCP);
    assert(lconn != NULL);
    ip_addr_t any;
    IP_SET_TYPE_VAL(any, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&any), PP_HTONL(LWIP_MAKEU32(0, 0, 0, 0)));
    assert(netconn_bind(lconn, &any, sa->port) == ERR_OK);
    assert(netconn_listen(lconn) == ERR_OK);
    sa->ready = 1;

    for (;;) {
        struct netconn *nc = NULL;
        assert(netconn_accept(lconn, &nc) == ERR_OK);
        struct netbuf *nb;
        while ((netconn_recv(nc, &nb)) == ERR_OK) {
            void *data; u16_t len;
            netbuf_data(nb, &data, &len);
            if (sa->echo && netconn_write(nc, data, len, NETCONN_COPY) != ERR_OK) {
                netbuf_delete(nb);
                break;
            }
            netbuf_delete(nb);
        }
        netconn_close(nc);
        netconn_delete(nc);
    }
}

/* 等待服务端就绪 */
static void wait_ready(volatile int *flag)
{
    while (!*flag) vTaskDelay(pdMS_TO_TICKS(10));
}

/* ======================= 实验 A：分层成本标定 ======================= */

#define RTT_PAYLOAD   64
#define RTT_ITER      150
#define THPUT_CHUNK   1460
#define THPUT_GROUP   3      /* 每组 3 块在途（4380B），小于默认 SND_BUF=5760，避免与
                                对端回显互相灌满对方接收窗口的全双工互锁 */
#define THPUT_GROUPS  24     /* 一轮 24 组 = 105.1KB */

static int sock_connect_to(int port)
{
    int c = socket(AF_INET, SOCK_STREAM, 0);
    assert(c >= 0);
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
    };
    dst.sin_addr.s_addr = PP_HTONL(LWIP_MAKEU32(127, 0, 0, 1)); /* loopback */
    int rc = connect(c, (struct sockaddr *)&dst, sizeof(dst));
    if (rc != 0) {
        printf("[A] connect fail errno=%d\n", errno);
        close(c);
        return -1;
    }
    return c;
}

static int recv_full(int fd, void *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        int n = recv(fd, (char *)buf + got, len - got, 0);
        if (n <= 0) return -1;
        got += n;
    }
    return 0;
}

static void bench_socket_rtt(void)
{
    char req[RTT_PAYLOAD], rsp[RTT_PAYLOAD];
    memset(req, 'S', sizeof(req));
    printf("[A-rtt-sock] begin (%dB x %d x 3 rounds)\n", RTT_PAYLOAD, RTT_ITER);
    for (int r = 0; r < 3; r++) {
        int c = sock_connect_to(PORT_SOCK_ECHO);
        if (c < 0) return;
        int64_t t0 = now_us();
        for (int i = 0; i < RTT_ITER; i++) {
            int off = 0;
            while (off < (int)sizeof(req)) {
                int w = send(c, req + off, sizeof(req) - off, 0);
                assert(w > 0); off += w;
            }
            assert(recv_full(c, rsp, sizeof(rsp)) == 0);
            assert(rsp[0] == 'S');
        }
        int64_t dt = now_us() - t0;
        printf("[A-rtt-sock] round%d avg=%.1f us/RTT\n", r + 1, (double)dt / RTT_ITER);
        close(c);
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

static void bench_netconn_rtt(void)
{
    static char req[RTT_PAYLOAD], rsp[RTT_PAYLOAD];
    memset(req, 'N', sizeof(req));
    printf("[A-rtt-netconn] begin (%dB x %d x 3 rounds)\n", RTT_PAYLOAD, RTT_ITER);
    for (int r = 0; r < 3; r++) {
        struct netconn *c = netconn_new(NETCONN_TCP);
        assert(c != NULL);
        ip_addr_t lo;
        IP_SET_TYPE_VAL(lo, IPADDR_TYPE_V4);
        ip4_addr_set_u32(ip_2_ip4(&lo), PP_HTONL(LWIP_MAKEU32(127, 0, 0, 1)));
        assert(netconn_connect(c, &lo, PORT_NC_ECHO) == ERR_OK);
        int64_t t0 = now_us();
        for (int i = 0; i < RTT_ITER; i++) {
            assert(netconn_write(c, req, sizeof(req), NETCONN_COPY) == ERR_OK);
            u16_t need = sizeof(req), have = 0;
            while (have < need) {
                struct netbuf *nb;
                assert(netconn_recv(c, &nb) == ERR_OK);
                void *d; u16_t l;
                netbuf_data(nb, &d, &l);
                memcpy(rsp + have, d, l);
                have += l;
                netbuf_delete(nb);
            }
            assert(rsp[0] == 'N');
        }
        int64_t dt = now_us() - t0;
        printf("[A-rtt-netconn] round%d avg=%.1f us/RTT\n", r + 1, (double)dt / RTT_ITER);
        netconn_delete(c);
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

static void run_thput_pair(const char *label)
{
    static char chunk[THPUT_CHUNK];
    memset(chunk, label[2], sizeof(chunk));
    const size_t group_bytes = THPUT_CHUNK * THPUT_GROUP;
    const size_t total = group_bytes * THPUT_GROUPS;
    for (int r = 0; r < 3; r++) {
        bool is_sock = (strcmp(label, "sock") == 0);
        int64_t t0, dt;
        if (is_sock) {
            int c = sock_connect_to(PORT_SOCK_ECHO);
            if (c < 0) return;
            t0 = now_us();
            for (int g = 0; g < THPUT_GROUPS; g++) {
                for (int k = 0; k < THPUT_GROUP; k++) {
                    int off = 0;
                    while (off < (int)sizeof(chunk)) {
                        int w = send(c, chunk + off, sizeof(chunk) - off, 0);
                        assert(w > 0); off += w;
                    }
                }
                /* 收回本组回显后再发下一组 */
                static char sink[THPUT_CHUNK];
                size_t got = 0;
                while (got < group_bytes) {
                    int n = recv(c, sink, sizeof(sink), 0);
                    assert(n > 0);
                    got += n;
                }
            }
            dt = now_us() - t0;
            close(c);
        } else {
            struct netconn *c = netconn_new(NETCONN_TCP);
            assert(c != NULL);
            ip_addr_t lo;
            IP_SET_TYPE_VAL(lo, IPADDR_TYPE_V4);
            ip4_addr_set_u32(ip_2_ip4(&lo), PP_HTONL(LWIP_MAKEU32(127, 0, 0, 1)));
            assert(netconn_connect(c, &lo, PORT_NC_ECHO) == ERR_OK);
            t0 = now_us();
            for (int g = 0; g < THPUT_GROUPS; g++) {
                for (int k = 0; k < THPUT_GROUP; k++) {
                    assert(netconn_write(c, chunk, sizeof(chunk), NETCONN_COPY) == ERR_OK);
                }
                size_t got = 0;
                while (got < group_bytes) {
                    struct netbuf *nb;
                    if (netconn_recv(c, &nb) != ERR_OK) break;
                    void *d; u16_t l;
                    netbuf_data(nb, &d, &l);
                    got += l;
                    netbuf_delete(nb);
                }
            }
            dt = now_us() - t0;
            netconn_delete(c);
        }
        double mbit = (double)total * 8 / ((double)dt / 1e6) / 1e6;
        printf("[A-thput-%s] round%d %uKB in %lld us -> %.2f Mbit\n",
               label, r + 1, (unsigned)(total / 1024), (long long)dt, mbit);
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

/* ======================= 实验 B：VFS 集成验证 ======================= */

static void vfs_experiment(void)
{
    printf("[B] ==== VFS integration checks ====\n");
    int c = sock_connect_to(PORT_VFS);
    if (c < 0) return;

    printf("[B] client fd=%d (>=54? %s), FD_SETSIZE=%d\n",
           c, c >= 54 ? "yes" : "no", (int)FD_SETSIZE);
    struct stat st;
    int rc = fstat(c, &st);
    printf("[B] fstat(fd) rc=%d mode=0x%lx S_IFSOCK? %s\n",
           rc, rc == 0 ? (unsigned long)st.st_mode : 0ul,
           (rc == 0 && S_ISSOCK(st.st_mode)) ? "yes" : "no");
    const char *msg = "vfs-posix-write";
    ssize_t w = write(c, msg, strlen(msg));
    char rb[128] = {0};
    ssize_t g = read(c, rb, sizeof(rb) - 1);
    printf("[B] POSIX write()->%zd read()->%zd echoed=\"%s\"\n", w, g, rb);

    /* poll：双连接就绪检测 */
    int c2 = sock_connect_to(PORT_VFS);
    assert(c2 >= 0);
    /* 先写 c，让 c 可读；两连接此时都可写 */
    write(c, "x", 1);
    /* 排掉第一次回显，之后 poll 时 c 又有新数据可读……改为直接测当前状态：
       c 已有数据可读，c2 无数据但可写 */
    struct pollfd pfds[2] = {
        { .fd = c,  .events = POLLIN | POLLOUT },
        { .fd = c2, .events = POLLIN | POLLOUT },
    };
    int nready = poll(pfds, 2, 2000);
    printf("[B] poll(nready=%d): [fd=%d revents=0x%hx POLLIN?%d POLLOUT?%d] "
           "[fd=%d revents=0x%hx POLLIN?%d POLLOUT?%d]\n",
           nready, pfds[0].fd, pfds[0].revents,
           !!(pfds[0].revents & POLLIN), !!(pfds[0].revents & POLLOUT),
           pfds[1].fd, pfds[1].revents,
           !!(pfds[1].revents & POLLIN), !!(pfds[1].revents & POLLOUT));

    /* FIONREAD 经 ioctl 透传（依赖 LWIP_SO_RCVBUF，IDF 默认 n —— 预期观察门控行为） */
    int avail = -1;
    int irc = ioctl(c, FIONREAD, &avail);
    printf("[B] ioctl(FIONREAD) on fd=%d -> rc=%d avail=%d errno=%d "
           "(LWIP_SO_RCVBUF gated)\n", c, irc, avail, errno);

    close(c);
    close(c2);
    printf("[B] done\n");
}

/* ======================= 实验 C：fd 耗尽故障注入 ======================= */

static int s_open_fds[32];
static int s_open_cnt;

static void fd_exhaust_experiment(void)
{
    printf("[C] ==== fd exhaustion ====\n");
    s_open_cnt = 0;
    int first_fail = -1;
    errno = 0;
    for (int i = 1; i <= 24; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            if (first_fail < 0) {
                first_fail = i;
                printf("[C] #%d socket() FAIL errno=%d (ENFILE=%d EMFILE=%d)\n",
                       i, errno, ENFILE, EMFILE);
            } else if (i <= first_fail + 3) {
                /* 连续再试几次，观察 errno 是否稳定、是否还会吃掉槽位 */
                printf("[C] #%d retry socket() FAIL errno=%d\n", i, errno);
            }
        } else {
            printf("[C] #%d socket() ok fd=%d\n", i, fd);
            s_open_fds[s_open_cnt++] = fd;
        }
        if (first_fail > 0 && i >= first_fail + 3) break;
    }

    /* 关闭最后一个槽位，立即重试并扫描回收延迟 */
    printf("[C] closing last slot fd=%d ...\n", s_open_fds[s_open_cnt - 1]);
    close(s_open_fds[--s_open_cnt]);
    int64_t t0 = now_us();
    int rec_fd = -1;
    int attempts;
    for (attempts = 1; attempts <= 3000; attempts++) {
        rec_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (rec_fd >= 0 || attempts == 3000) break;
        vTaskDelay(1); /* 让出 CPU 等待 tcpip_thread 处理完 delconn */
    }
    int64_t dt = now_us() - t0;
    if (rec_fd >= 0) {
        printf("[C] after close, socket() again OK fd=%d, failed_attempts_before=%d, "
               "delta=%lld us\n",
               rec_fd, attempts - 1, (long long)dt);
        s_open_fds[s_open_cnt++] = rec_fd;
    } else {
        printf("[C] after close, socket() still failing\n");
    }
    /* 清理全部测试 fd */
    for (int i = 0; i < s_open_cnt; i++) close(s_open_fds[i]);
    printf("[C] cleanup %d fds, done\n", s_open_cnt);
}

/* ======================= 实验 D：阻塞 recv 的窒息与逃生 ======================= */

static volatile int d_stuck_fd = -1;     /* 被 close 解救实验用的 fd */
static volatile int64_t d_wake_at = 0;   /* worker 返回时间戳 */

static void blocked_recv_worker(void *arg)
{
    int c = sock_connect_to(PORT_SILENT);
    if (c < 0) return;
    *(volatile int *)arg = c;
    char buf[256];
    printf("[D1-block] task blocking in recv(fd=%d) forever...\n", c);
    int n = recv(c, buf, sizeof(buf), 0);
    d_wake_at = now_us();
    printf("[D1-block] recv RETURNED n=%d errno=%d (%s)\n",
           n, errno, strerror(errno));
    close(c);
    vTaskDelete(NULL);
}

static void blocked_experiment(void)
{
    printf("[D] ==== blocked recv strangulation ====\n");

    /* D0: 全默认阻塞 recv —— 应挂死，并由另一任务 close 解救 */
    {
        static volatile int fd_slot = -1;
        TaskHandle_t th = NULL;
        d_wake_at = 0;
        xTaskCreate(blocked_recv_worker, "blkrecv", 4096, (void *)&fd_slot, 5, &th);
        while (fd_slot < 0) vTaskDelay(pdMS_TO_TICKS(5));
        d_stuck_fd = fd_slot;
        vTaskDelay(pdMS_TO_TICKS(4000)); /* 让它挂着 4 秒 */
        printf("[D1-close] another task calls close(fd=%d) ...\n", d_stuck_fd);
        int64_t tc = now_us();
        close(d_stuck_fd);
        /* 等 worker 醒来 */
        for (int i = 0; i < 300 && d_wake_at == 0; i++) vTaskDelay(pdMS_TO_TICKS(10));
        if (d_wake_at) {
            printf("[D1-close] worker woke, close->wake latency=%lld us\n",
                   (long long)(d_wake_at - tc));
        } else {
            printf("[D1-close] worker did NOT wake within 3s after close\n");
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    /* D2: SO_RCVTIMEO 逃生 */
    {
        int c = sock_connect_to(PORT_SILENT);
        struct timeval tv = { .tv_sec = 1, .tv_usec = 500000 };
        int rc = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        char buf[64];
        printf("[D2-timeo] setsockopt(SO_RCVTIMEO,1500ms) rc=%d\n", rc);
        for (int k = 0; k < 3; k++) {
            int64_t t0 = now_us();
            int n = recv(c, buf, sizeof(buf), 0);
            int e = errno;
            printf("[D2-timeo] recv#%d -> %d errno=%d elapsed=%lld ms\n",
                   k + 1, n, e, (long long)((now_us() - t0) / 1000));
        }
        close(c);
    }

    /* D3: O_NONBLOCK 逃生 */
    {
        int c = sock_connect_to(PORT_SILENT);
        int fl = fcntl(c, F_GETFL, 0);
        fcntl(c, F_SETFL, fl | O_NONBLOCK);
        char buf[64];
        printf("[D3-nonblock] O_NONBLOCK armed (F_GETFL=0x%x)\n", fl);
        for (int k = 0; k < 3; k++) {
            int64_t t0 = now_us();
            int n = recv(c, buf, sizeof(buf), 0);
            printf("[D3-nonblock] recv#%d -> %d errno=%d elapsed=%lld us\n",
                   k + 1, n, errno, (long long)(now_us() - t0));
        }
        close(c);
    }

    /* D4: select(timeout) 逃生 + 就绪唤醒 */
    {
        int c = sock_connect_to(PORT_SILENT);
        fd_set rfds;
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        printf("[D4-select] silent server, waiting 2 x 2s ...\n");
        for (int k = 0; k < 2; k++) {
            FD_ZERO(&rfds); FD_SET(c, &rfds);
            int64_t t0 = now_us();
            int r = select(c + 1, &rfds, NULL, NULL, &tv);
            printf("[D4-select] #%d -> %d elapsed=%lld ms\n",
                   k + 1, r, (long long)((now_us() - t0) / 1000));
        }
        close(c);

        /* 对照：echo 链路上已有在途数据，select 应立即返回就绪 */
        int e = sock_connect_to(PORT_SOCK_ECHO);
        assert(e >= 0);
        write(e, "wake", 4);            /* 触发回显，数据即将可读 */
        FD_ZERO(&rfds); FD_SET(e, &rfds);
        int64_t t0 = now_us();
        int r = select(e + 1, &rfds, NULL, NULL, &tv);
        char wakebuf[16];
        if (r > 0) { read(e, wakebuf, sizeof(wakebuf)); }
        printf("[D4-select] with pending echo data -> %d elapsed=%lld us "
               "(immediate=%s)\n", r, (long long)(now_us() - t0),
               ((now_us() - t0) < 20000) ? "YES" : "NO");
        close(e);
    }
    printf("[D] done\n");
}

/* ======================= app_main ======================= */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch16 lab: socket/netconn/VFS benchmark & fault injection ==");

    /* ch3 模板标准 bring-up（也是 Batch 1 的教训点：socket 必须在 esp_netif_init 之后） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;
    phy_cfg.autonego_timeout_ms = 3000;
    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    static srv_arg_t srv_sock = { .port = PORT_SOCK_ECHO, .echo = 1 };
    static srv_arg_t srv_nc   = { .port = PORT_NC_ECHO,   .echo = 1 };
    static srv_arg_t srv_vfs  = { .port = PORT_VFS,       .echo = 1 };
    static srv_arg_t srv_sil  = { .port = PORT_SILENT,    .echo = 0 };

    xTaskCreate(socket_echo_task, "srv_sock", 4096, &srv_sock, 5, NULL);
    xTaskCreate(netconn_echo_task, "srv_nc",   4096, &srv_nc,   5, NULL);
    xTaskCreate(socket_echo_task, "srv_vfs",   4096, &srv_vfs,  5, NULL);
    xTaskCreate(socket_echo_task, "srv_silent",4096, &srv_sil,  5, NULL);
    wait_ready(&srv_sock.ready);
    wait_ready(&srv_nc.ready);
    wait_ready(&srv_vfs.ready);
    wait_ready(&srv_sil.ready);
    vTaskDelay(pdMS_TO_TICKS(100));

    printf("\n===== PHASE A: layering cost =====\n");
    bench_socket_rtt();
    bench_netconn_rtt();
    printf("[A-thput] socket client <-> socket echo server:\n");
    run_thput_pair("sock");
    printf("[A-thput] netconn client <-> netconn echo server:\n");
    run_thput_pair("nc");

    printf("\n===== PHASE B: VFS integration =====\n");
    vfs_experiment();

    printf("\n===== PHASE C: fd exhaustion =====\n");
    fd_exhaust_experiment();

    printf("\n===== PHASE D: blocked recv =====\n");
    blocked_experiment();

    printf("\n===== ALL PHASES DONE, keep alive =====\n");
    vTaskDelay(pdMS_TO_TICKS(60000));
}
