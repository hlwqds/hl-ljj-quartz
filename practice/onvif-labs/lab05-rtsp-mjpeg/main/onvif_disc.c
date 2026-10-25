/*
 * onvif_disc.c — WS-Discovery 应答器（lab01）。
 *
 * 职责（SPEC §6 lab01）：加入 239.255.255.250:3702 组播组，定向解析 Probe
 * （MessageID/Types，任意命名空间前缀；Scopes 匹配刻意宽松——lab01 不校验），
 * 单播回 ProbeMatch。报文格式依据《ONVIF 深度解析》ch02；XAddrs 指向的
 * /onvif/device_service 由 lab02 落地——本阶段刻意只有发现面。
 *
 * 缓冲纪律（SPEC §4）：收包/应答缓冲一律 PSRAM；任务栈 4KB 内部 RAM。
 */

#include "onvif_disc.h"

#include "esp_check.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define DISC_PORT       3702U
#define DISC_GROUP      "239.255.255.250"
#define DISC_TASK_STACK 4096
#define DISC_TASK_PRIO  10
#define DISC_RECV_BUF   2048
#define DISC_REPLY_BUF  1400
#define DISC_XADDR_PORT 80U

static const char *TAG = "onvif_disc";

static char s_ip[16];       /* STA IPv4（点分十进制），GOT_IP 时填入 */
static bool s_task_started; /* GOT_IP 可能带旧地址重放多次，任务只起一次 */
static char s_uuid[48];     /* "urn:uuid:" + 36 + NUL = 46 */

/* 设备 UUID：efuse STA MAC 派生的确定性 UUID（合法 8-4-4-4-12 十六进制形态，
 * 第 9 字节高两位置 10xx 使其形似 RFC4122 变体位）。每次启动一致，
 * 客户端侧 EndpointReference 因此稳定。 */
static void disc_build_uuid(void)
{
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    const uint8_t u[16] = {
        mac[0], mac[1], mac[2], 0x7d, 0x26, mac[3], mac[4], mac[5],
        0x8a,   0x3e,   0x4b,   0xa5, 0x9c, 0xd1,   0xe2,   0xf3,
    };
    snprintf(s_uuid, sizeof(s_uuid),
             "urn:uuid:%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
             u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}

/* 定向提取：找 "<任意前缀:tag>" 的文本值（跳过开标签，读到下一个 '<'）。
 * 用 "tag>" 定位以同时兼容 <w:MessageID> 与 <MessageID> 两种前缀形态。
 * 找不到返回 false；找到时 out 以 NUL 结尾、按 out_max 截断。 */
static bool disc_extract(const char *xml, const char *tag, char *out, size_t out_max)
{
    char pat[32];
    snprintf(pat, sizeof(pat), "%s>", tag);
    const char *p = strstr(xml, pat);
    if (p == NULL) {
        return false;
    }
    p += strlen(pat);
    const char *end = strchr(p, '<');
    if (end == NULL) {
        return false;
    }
    size_t n = (size_t)(end - p);
    if (n >= out_max) {
        n = out_max - 1;
    }
    memcpy(out, p, n);
    out[n] = '\0';
    return true;
}

/* Probe 判定（宽松）：Action 头含 /Probe，或正文出现 Probe 开标签。
 * Resolve/Hello 等同组播报文不回应（lab01 只承诺 Probe）。 */
static bool disc_is_probe(const char *xml)
{
    if (strstr(xml, "discovery/Probe<") != NULL) {
        return true;
    }
    return strstr(xml, ":Probe>") != NULL || strstr(xml, "<Probe>") != NULL;
}

static const char REPL_TMPL[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    "<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\""
    " xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\""
    " xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\""
    " xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">"
    "<e:Header>"
    "<w:MessageID>%s</w:MessageID>"
    "<w:RelatesTo>%s</w:RelatesTo>"
    "<w:To>e:urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
    "<w:Action>e:http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</w:Action>"
    "</e:Header>"
    "<e:Body>"
    "<d:ProbeMatches>"
    "<d:ProbeMatch>"
    "<w:EndpointReference><w:Address>%s</w:Address></w:EndpointReference>"
    "<d:Types>dn:NetworkVideoTransmitter</d:Types>"
    "<d:Scopes>onvif://www.onvif.org/Profile/Streaming"
    " onvif://www.onvif.org/hardware/ESP32-S31-Korvo-1"
    " onvif://www.onvif.org/name/onvif-lab01</d:Scopes>"
    "<d:XAddrs>http://%s:%u/onvif/device_service</d:XAddrs>"
    "<d:MetadataVersion>1</d:MetadataVersion>"
    "</d:ProbeMatch>"
    "</d:ProbeMatches>"
    "</e:Body>"
    "</e:Envelope>";

static void disc_task(void *arg)
{
    /* arg = STA IPv4（网络序），IGMP 组播成员按该接口加入。 */
    const uint32_t sta_ip_netorder = (uint32_t)(uintptr_t)arg;

    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        ESP_LOGE(TAG, "socket failed errno=%d", errno);
        vTaskDelete(NULL);
        return;
    }

    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in local = {
        .sin_family = AF_INET,
        .sin_port = htons(DISC_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(sock, (struct sockaddr *)&local, sizeof(local)) < 0) {
        ESP_LOGE(TAG, "bind :%u failed errno=%d", DISC_PORT, errno);
        close(sock);
        vTaskDelete(NULL);
        return;
    }

    struct ip_mreq mreq = {
        .imr_multiaddr.s_addr = inet_addr(DISC_GROUP),
        .imr_interface.s_addr = (in_addr_t)sta_ip_netorder,
    };
    if (setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
        ESP_LOGE(TAG, "join %s failed errno=%d", DISC_GROUP, errno);
        close(sock);
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "$$$ ONVIF LAB01 DISC JOIN grp=%s:%u ip=%s", DISC_GROUP, DISC_PORT, s_ip);

    char *rx = heap_caps_malloc(DISC_RECV_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    char *tx = heap_caps_malloc(DISC_REPLY_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (rx == NULL || tx == NULL) {
        ESP_LOGE(TAG, "PSRAM buffers alloc failed");
        heap_caps_free(rx);
        heap_caps_free(tx);
        close(sock);
        vTaskDelete(NULL);
        return;
    }

    for (;;) {
        struct sockaddr_in src = {0};
        socklen_t slen = sizeof(src);
        int len = recvfrom(sock, rx, DISC_RECV_BUF - 1, 0, (struct sockaddr *)&src, &slen);
        if (len < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                continue;
            }
            ESP_LOGE(TAG, "recvfrom errno=%d", errno);
            continue;
        }
        rx[len] = '\0';

        if (!disc_is_probe(rx)) {
            ESP_LOGD(TAG, "ignore non-Probe (%d bytes)", len);
            continue;
        }

        /* 定向提取 MessageID（回 RelatesTo）与 Types（宽松过滤）。 */
        char relates[64] = {0};
        char types[128] = {0};
        disc_extract(rx, "MessageID", relates, sizeof(relates));
        bool types_ok = !disc_extract(rx, "Types", types, sizeof(types)) ||
                        strstr(types, "NetworkVideoTransmitter") != NULL ||
                        strstr(types, "Device") != NULL;
        if (!types_ok) {
            ESP_LOGD(TAG, "Probe Types not ours: %.60s", types);
            continue;
        }

        int n = snprintf(tx, DISC_REPLY_BUF, REPL_TMPL, s_uuid,
                         relates[0] != '\0' ? relates : s_uuid, s_uuid, s_ip, DISC_XADDR_PORT);
        if (n <= 0 || n >= DISC_REPLY_BUF) {
            ESP_LOGE(TAG, "reply render failed (%d)", n);
            continue;
        }

        if (sendto(sock, tx, n, 0, (struct sockaddr *)&src, sizeof(src)) < 0) {
            ESP_LOGE(TAG, "sendto errno=%d", errno);
            continue;
        }
        /* 机器可读标记行（SPEC §1）：验收 grep 锚点。 */
        ESP_LOGI(TAG, "$$$ ONVIF LAB01 PROBEMATCH xaddrs=http://%s:%u/onvif/device_service client=%s:%d",
                 s_ip, DISC_XADDR_PORT, inet_ntoa(src.sin_addr), ntohs(src.sin_port));
    }
}

static void disc_got_ip_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    ip_event_got_ip_t *ev = (ip_event_got_ip_t *)data;
    snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&ev->ip_info.ip));
    if (s_task_started) {
        return;
    }
    s_task_started = true;
    if (xTaskCreate(disc_task, "onvif_disc", DISC_TASK_STACK,
                    (void *)(uintptr_t)ev->ip_info.ip.addr, DISC_TASK_PRIO, NULL) != pdPASS) {
        ESP_LOGE(TAG, "disc task create failed");
        s_task_started = false;
    }
}

esp_err_t onvif_disc_init(void)
{
    disc_build_uuid();
    ESP_RETURN_ON_ERROR(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                            disc_got_ip_handler, NULL, NULL),
                        TAG, "register GOT_IP handler failed");
    ESP_LOGI(TAG, "$$$ ONVIF LAB01 DISC READY uuid=%s", s_uuid);
    return ESP_OK;
}
