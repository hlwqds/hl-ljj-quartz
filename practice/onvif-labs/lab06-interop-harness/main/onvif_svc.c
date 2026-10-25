/*
 * onvif_svc.c — SOAP 控制面 + Media 三操作（含 GetStreamUri）（lab05；契约 = ch16 / SPEC §6 lab05，
 * 自 lab03 移植）。
 *
 * 80 端口同一 httpd 实例三个 URI：POST /onvif/device_service（免鉴权四连 + GetUsers）、
 * POST /onvif/media_service（GetProfiles / GetSnapshotUri，均过 lab03 摘要门）、
 * GET /onvif-http/snapshot（免鉴权直出最新成品 JPEG，明示内网实验边界）。
 * GET /onvif/ 下 SOAP 端点一律 405，未注册路径自然 404。
 *
 * 路由：Body 首子元素（本地名 + 前缀绑定 tds/trt 双命名空间）权威，SOAPAction 尾段兜底
 * （实测 zeep 全程不发该头）。未知 ProfileToken 回 s:Sender + ter:InvalidArgVal——
 * HTTP 按壳映射：1.2 Sender→400，1.1 Fault 一律 500。
 *
 * 信封：双壳（SOAP 1.1 / 1.2），回信信封版本跟随请求。缓冲一律 PSRAM（含 300KB
 * 快照拷贝缓冲），esp_http_server 单线程串行处理，共享缓冲无竞争。
 */

#include "onvif_svc.h"

#include "factory_demo_stream.h"
#include "onvif_auth.h"

#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#define SVC_RECV_BUF 4096
#define SVC_BODY_BUF 2048
#define SVC_TX_BUF   4096
#define SVC_HOST_BUF 96
#define SVC_SNAPSHOT_BUF (300 * 1024) /* 整帧余量：25KB 级成品 ×10，PSRAM */
#define SVC_TASK_STACK 5120
#define SVC_TASK_PRIO 9
#define SVC_HTTPD_WAIT_MS 30000

static const char *TAG = "onvif_svc";

#define TDS_NS "http://www.onvif.org/ver10/device/wsdl"
#define TER_NS "http://www.onvif.org/ver10/error"
#define TRT_NS "http://www.onvif.org/ver10/media/wsdl"

/* 信封壳：Body 由运行期填入；ter 命名空间只在 Fault 路径内联声明，正常应答一行不多。 */
static const char SHELL_11[] =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
    " xmlns:tds=\"" TDS_NS "\""
    " xmlns:tt=\"http://www.onvif.org/ver10/schema\">"
    "<s:Body>%s</s:Body></s:Envelope>";
static const char SHELL_12[] =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\""
    " xmlns:tds=\"" TDS_NS "\""
    " xmlns:tt=\"http://www.onvif.org/ver10/schema\">"
    "<s:Body>%s</s:Body></s:Envelope>";

/* ---- Body 模板（rodata；运行期只换时间/身份/XAddr 字段） ---- */

static const char BODY_DATE_TIME[] =
    "<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>"
    "<tt:DateTimeType>Manual</tt:DateTimeType>"
    "<tt:DaylightSavings>false</tt:DaylightSavings>"
    "<tt:TimeZone><tt:TZ>CST-8</tt:TZ></tt:TimeZone>"
    "<tt:UTCDateTime><tt:Time><tt:Hour>%02d</tt:Hour><tt:Minute>%02d</tt:Minute>"
    "<tt:Second>%02d</tt:Second></tt:Time><tt:Date><tt:Year>%04d</tt:Year>"
    "<tt:Month>%02d</tt:Month><tt:Day>%02d</tt:Day></tt:Date></tt:UTCDateTime>"
    "</tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>";

static const char BODY_DEV_INFO[] =
    "<tds:GetDeviceInformationResponse>"
    "<tds:Manufacturer>Espressif</tds:Manufacturer>"
    "<tds:Model>ESP32-S31-Korvo-1 ONVIF Lab</tds:Model>"
    "<tds:FirmwareVersion>%s</tds:FirmwareVersion>"
    "<tds:SerialNumber>%02x%02x%02x%02x%02x%02x</tds:SerialNumber>"
    "<tds:HardwareId>ESP32-S31</tds:HardwareId>"
    "</tds:GetDeviceInformationResponse>";

static const char BODY_SERVICES[] =
    "<tds:GetServicesResponse><tds:Service>"
    "<tds:Namespace>" TDS_NS "</tds:Namespace>"
    "<tds:XAddr>http://%s/onvif/device_service</tds:XAddr>"
    "<tds:Version><tt:Major>10</tt:Major><tt:Minor>12</tt:Minor></tds:Version>"
    "</tds:Service><tds:Service>"
    "<tds:Namespace>" TRT_NS "</tds:Namespace>"
    "<tds:XAddr>http://%s/onvif/media_service</tds:XAddr>"
    "<tds:Version><tt:Major>10</tt:Major><tt:Minor>12</tt:Minor></tds:Version>"
    "</tds:Service></tds:GetServicesResponse>";

static const char BODY_CAPABILITIES[] =
    "<tds:GetCapabilitiesResponse><tds:Capabilities>"
    "<tt:Device><tt:XAddr>http://%s/onvif/device_service</tt:XAddr>"
    "<tt:Network><tt:IPFilter>false</tt:IPFilter>"
    "<tt:ZeroConfiguration>false</tt:ZeroConfiguration></tt:Network>"
    "<tt:System><tt:DiscoveryResolve>false</tt:DiscoveryResolve>"
    "<tt:DiscoveryBye>false</tt:DiscoveryBye>"
    "<tt:RemoteDiscovery>false</tt:RemoteDiscovery>"
    "<tt:SystemBackup>false</tt:SystemBackup>"
    "<tt:SystemLogging>false</tt:SystemLogging>"
    "<tt:FirmwareUpgrade>false</tt:FirmwareUpgrade></tt:System>"
    "</tt:Device>"
    "<tt:Media><tt:XAddr>http://%s/onvif/media_service</tt:XAddr>"
    "<tt:StreamingCapabilities/></tt:Media>"
    "</tds:Capabilities></tds:GetCapabilitiesResponse>";

static const char BODY_FAULT_12[] =
    "<s:Fault><s:Code><s:Value>s:Receiver</s:Value>"
    "<s:Subcode><s:Value xmlns:ter=\"" TER_NS "\">ter:ActionNotSupported</s:Value></s:Subcode>"
    "</s:Code><s:Reason><s:Text xml:lang=\"en\">Requested action not supported"
    " (ter:ActionNotSupported)</s:Text></s:Reason></s:Fault>";

static const char BODY_FAULT_11[] =
    "<s:Fault><s:faultcode>s:Receiver</s:faultcode>"
    "<s:faultstring>ter:ActionNotSupported: requested operation not supported</s:faultstring>"
    "</s:Fault>";

/* lab03 靶子 GetUsers：返回花名册单条 admin（Administrator）；用户名取 onvif_secrets。 */
static const char BODY_USERS[] =
    "<tds:GetUsersResponse><tds:User>"
    "<tt:Username>%s</tt:Username>"
    "<tt:UserLevel>Administrator</tt:UserLevel>"
    "</tds:User></tds:GetUsersResponse>";

/* 鉴权失败统一 ter:NotAuthorized（分因只在板端 run.log，ch14 §14.2 判据表） */
static const char BODY_FAULT_AUTH_12[] =
    "<s:Fault><s:Code><s:Value>s:Receiver</s:Value>"
    "<s:Subcode><s:Value xmlns:ter=\"" TER_NS "\">ter:NotAuthorized</s:Value></s:Subcode>"
    "</s:Code><s:Reason><s:Text xml:lang=\"en\">Sender not authorized"
    " (ter:NotAuthorized)</s:Text></s:Reason></s:Fault>";

static const char BODY_FAULT_AUTH_11[] =
    "<s:Fault><s:faultcode>s:Receiver</s:faultcode>"
    "<s:faultstring>ter:NotAuthorized: sender not authorized</s:faultstring>"
    "</s:Fault>";

/* ---- lab04 Media（trt 命名空间；模板声明在应答根元素上，信封壳不动） ---- */

/* 单 profile 静态模板：字段全部取自基座实测/固件常量（ch15 §15.2 出处表） */
static const char BODY_PROFILES[] =
    "<trt:GetProfilesResponse xmlns:trt=\"" TRT_NS "\">"
    "<trt:Profiles token=\"profile_1\">"
    "<tt:Name>mjpeg_640x480</tt:Name>"
    "<tt:VideoSourceConfiguration token=\"vsc_1\">"
    "<tt:Name>sc101iot_source</tt:Name>"
    "<tt:UseCount>1</tt:UseCount>"
    "<tt:SourceToken>vs_1</tt:SourceToken>"
    "<tt:Bounds x=\"0\" y=\"0\" width=\"640\" height=\"480\"/>"
    "</tt:VideoSourceConfiguration>"
    "<tt:VideoEncoderConfiguration token=\"vec_1\">"
    "<tt:Name>mjpeg_encoder</tt:Name>"
    "<tt:UseCount>1</tt:UseCount>"
    "<tt:Encoding>JPEG</tt:Encoding>"
    "<tt:Resolution><tt:Width>640</tt:Width><tt:Height>480</tt:Height></tt:Resolution>"
    "<tt:Quality>80</tt:Quality>"
    "<tt:RateControl><tt:FrameRateLimit>15</tt:FrameRateLimit>"
    "<tt:EncodingInterval>1</tt:EncodingInterval>"
    "<tt:BitrateLimit>3020</tt:BitrateLimit></tt:RateControl>"
    "</tt:VideoEncoderConfiguration>"
    "</trt:Profiles></trt:GetProfilesResponse>";

/* SnapshotUri：Uri 由请求 Host 头现拼（禁写死 IP）；无会话语义三件套定值 */
static const char BODY_SNAPSHOT_URI[] =
    "<trt:GetSnapshotUriResponse xmlns:trt=\"" TRT_NS "\">"
    "<trt:MediaUri>"
    "<tt:Uri>http://%s/onvif-http/snapshot</tt:Uri>"
    "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>"
    "<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>"
    "<tt:Timeout>PT0S</tt:Timeout>"
    "</trt:MediaUri></trt:GetSnapshotUriResponse>";

/* GetStreamUri（lab05）：RTSP 档，8554 端口（SPEC §5），路径 /mjpeg */
static const char BODY_STREAM_URI[] =
    "<trt:GetStreamUriResponse xmlns:trt=\"" TRT_NS "\">"
    "<trt:MediaUri>"
    "<tt:Uri>rtsp://%s:8554/mjpeg</tt:Uri>"
    "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>"
    "<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>"
    "<tt:Timeout>PT0S</tt:Timeout>"
    "</trt:MediaUri></trt:GetStreamUriResponse>";

/* 未知 ProfileToken：s:Sender + ter:InvalidArgVal（ch03 判据表；1.1 无 Subcode 位） */
static const char BODY_FAULT_TOKEN_12[] =
    "<s:Fault><s:Code><s:Value>s:Sender</s:Value>"
    "<s:Subcode><s:Value xmlns:ter=\"" TER_NS "\">ter:InvalidArgVal</s:Value></s:Subcode>"
    "</s:Code><s:Reason><s:Text xml:lang=\"en\">Unknown ProfileToken"
    " (ter:InvalidArgVal)</s:Text></s:Reason></s:Fault>";

static const char BODY_FAULT_TOKEN_11[] =
    "<s:Fault><s:faultcode>s:Client</s:faultcode>"
    "<s:faultstring>ter:InvalidArgVal: unknown ProfileToken</s:faultstring>"
    "</s:Fault>";

/* ---- 共享 PSRAM 缓冲（esp_http_server 单线程串行处理，无竞争） ---- */

static char *s_rx;   /* 请求原文 */
static char *s_body; /* Body 拼装 */
static char *s_tx;   /* 信封拼装 */
static char *s_snapshot; /* lab04 快照：最新成品 JPEG 的落点（PSRAM） */

/* httpd 的请求处理跑在 httpd 线程；ready 之前 handler 不会注册，无需加锁。 */

typedef enum { SHELL_SOAP11 = 0, SHELL_SOAP12 = 1 } shell_ver_t;

static const char *shell_content_type(shell_ver_t v)
{
    return v == SHELL_SOAP12 ? "application/soap+xml; charset=utf-8"
                             : "text/xml; charset=utf-8";
}

/* 请求 Envelope 命名空间 → 壳版本；默认 1.1（存量兼容基线）。 */
static shell_ver_t detect_shell(const char *rx)
{
    return strstr(rx, "http://www.w3.org/2003/05/soap-envelope") != NULL ? SHELL_SOAP12
                                                                         : SHELL_SOAP11;
}

/* XAddr 的 host 段：优先请求 Host 头（禁写死 IP，SPEC §5）；缺失回落板端 netif 地址。 */
static void svc_host_of(httpd_req_t *req, char *out, size_t out_max)
{
    if (httpd_req_get_hdr_value_str(req, "Host", out, out_max) != ESP_OK ||
        out[0] == '\0') {
        factory_stream_status_t st = {0};
        factory_stream_get_status(&st);
        snprintf(out, out_max, "%s", st.ip[0] != '\0' ? st.ip : "0.0.0.0");
    }
}

static esp_err_t send_soap(httpd_req_t *req, shell_ver_t shell, const char *body,
                           const char *status)
{
    /* status：NULL=200；SOAP 1.1 Fault 一律 500；1.2 的 s:Sender 语义映射 400、
     * s:Receiver 映射 500（坑 6 表的 HTTP 映射，设备端第一次自己用）。 */
    int n = snprintf(s_tx, SVC_TX_BUF,
                     shell == SHELL_SOAP12 ? SHELL_12 : SHELL_11, body);
    if (n <= 0 || n >= SVC_TX_BUF) {
        return ESP_FAIL;
    }
    httpd_resp_set_type(req, shell_content_type(shell));
    if (status != NULL) {
        httpd_resp_set_status(req, status);
    }
    httpd_resp_send(req, s_tx, n);
    return ESP_OK;
}

/* ---- 四操作应答体 ---- */

static esp_err_t serve_date_time(httpd_req_t *req, char *body, size_t body_max)
{
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    snprintf(body, body_max, BODY_DATE_TIME, utc.tm_hour, utc.tm_min, utc.tm_sec,
             utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday);
    return ESP_OK;
}

static esp_err_t serve_dev_info(httpd_req_t *req, char *body, size_t body_max)
{
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(body, body_max, BODY_DEV_INFO, esp_app_get_description()->version,
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    return ESP_OK;
}

static esp_err_t serve_services(httpd_req_t *req, char *body, size_t body_max)
{
    char host[SVC_HOST_BUF];
    svc_host_of(req, host, sizeof(host));
    snprintf(body, body_max, BODY_SERVICES, host, host); /* Device 与 Media 各一份 XAddr */
    return ESP_OK;
}

static esp_err_t serve_capabilities(httpd_req_t *req, char *body, size_t body_max)
{
    char host[SVC_HOST_BUF];
    svc_host_of(req, host, sizeof(host));
    snprintf(body, body_max, BODY_CAPABILITIES, host, host); /* Device 与 Media 各一份 XAddr */
    return ESP_OK;
}

/* ---- lab03 靶子：GetUsers（需鉴权）——花名册单条 admin ---- */

static esp_err_t serve_users(httpd_req_t *req, char *body, size_t body_max)
{
    snprintf(body, body_max, BODY_USERS, onvif_auth_username());
    return ESP_OK;
}

/* ---- lab04 media：GetProfiles（静态模板）与 GetSnapshotUri（Host 现拼） ---- */

static esp_err_t serve_profiles(httpd_req_t *req, char *body, size_t body_max)
{
    (void)req;
    snprintf(body, body_max, BODY_PROFILES);
    return ESP_OK;
}

static esp_err_t serve_snapshot_uri(httpd_req_t *req, char *body, size_t body_max)
{
    char host[SVC_HOST_BUF];
    svc_host_of(req, host, sizeof(host));
    snprintf(body, body_max, BODY_SNAPSHOT_URI, host);
    return ESP_OK;
}

static esp_err_t serve_stream_uri(httpd_req_t *req, char *body, size_t body_max)
{
    char host[SVC_HOST_BUF];
    svc_host_of(req, host, sizeof(host));
    snprintf(body, body_max, BODY_STREAM_URI, host);
    return ESP_OK;
}

/* ---- 路由表（免鉴权四连 + 鉴权靶子 GetUsers + media 双操作；lab05 RTSP 在此追加） ---- */

typedef esp_err_t (*serve_fn)(httpd_req_t *req, char *body, size_t body_max);

static const struct {
    const char *local;       /* Body 首子元素本地名 */
    const char *ns;          /* 前缀须绑定的命名空间 URI（tds=设备服务，trt=媒体服务） */
    const char *action_tail; /* SOAPAction 尾段：仅 Body 解析失败时兜底 */
    serve_fn serve;          /* 模板拼装进 body 缓冲 */
    bool needs_auth;         /* true = 先过 onvif_auth_verify 五环判据链 */
} kOps[] = {
    { "GetSystemDateAndTime", TDS_NS, "GetSystemDateAndTime", serve_date_time,    false },
    { "GetDeviceInformation", TDS_NS, "GetDeviceInformation", serve_dev_info,     false },
    { "GetServices",          TDS_NS, "GetServices",          serve_services,     false },
    { "GetCapabilities",      TDS_NS, "GetCapabilities",      serve_capabilities, false },
    { "GetUsers",             TDS_NS, "GetUsers",             serve_users,        true  },
    { "GetProfiles",          TRT_NS, "GetProfiles",          serve_profiles,     true  },
    { "GetSnapshotUri",       TRT_NS, "GetSnapshotUri",       serve_snapshot_uri, true  },
    { "GetStreamUri",         TRT_NS, "GetStreamUri",         serve_stream_uri,   true  },
};

/* Body 首子元素权威路由：定位 ":Body>" 后的首个元素，取本地名；
 * 其 xmlns 前缀必须绑定到 kOps 支持的命名空间（tds 或 trt）——定向提取，不做 DOM。
 * 命中返回 kOps 下标，解析失败返回 -1。 */
static int svc_route_by_body(const char *rx)
{
    const char *p = strstr(rx, ":Body>");
    if (p == NULL) {
        return -1;
    }
    p += strlen(":Body>");
    while (*p != '\0' && *p != '<') {
        p++;
    }
    if (*p != '<') {
        return -1;
    }
    p++;
    char prefix[16] = {0};
    char local[48] = {0};
    int n = 0;
    while ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
           (*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-') {
        if (n < (int)sizeof(local) - 1) {
            local[n++] = *p;
        }
        p++;
    }
    local[n] = '\0';
    /* 本地名与前缀拆分（Prefix:Local 形态；无前缀 → 默认命名空间，非 tds/trt） */
    char *colon = strchr(local, ':');
    if (colon != NULL) {
        snprintf(prefix, sizeof(prefix), "%.*s", (int)(colon - local), local);
        memmove(local, colon + 1, strlen(colon + 1) + 1);
    } else {
        return -1;
    }
    /* 前缀绑定校验：xmlns:<prefix> 必须绑定到受支持的命名空间 */
    char decl[80];
    const char *ns = NULL;
    snprintf(decl, sizeof(decl), "xmlns:%s=\"%s\"", prefix, TDS_NS);
    if (strstr(rx, decl) != NULL) {
        ns = TDS_NS;
    } else {
        snprintf(decl, sizeof(decl), "xmlns:%s=\"%s\"", prefix, TRT_NS);
        if (strstr(rx, decl) != NULL) {
            ns = TRT_NS;
        }
    }
    if (ns == NULL) {
        return -1;
    }
    for (size_t i = 0; i < sizeof(kOps) / sizeof(kOps[0]); i++) {
        if (strcmp(local, kOps[i].local) == 0 && strcmp(ns, kOps[i].ns) == 0) {
            return (int)i;
        }
    }
    return -1;
}

/* SOAPAction 尾段快路径在 onvif_svc_handler 内联实现（仅提示，Body 为权威）。 */
static void svc_log_op(const char *local, bool ok)
{
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 OP %s %s", local, ok ? "ok" : "fail");
}

static esp_err_t onvif_svc_handler(httpd_req_t *req)
{
    int64_t content_len = (int64_t)req->content_len;
    if (content_len <= 0 || content_len >= SVC_RECV_BUF) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "soap body size out of range");
        return ESP_OK;
    }
    int rx_len = httpd_req_recv(req, s_rx, (size_t)content_len);
    if (rx_len <= 0) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "soap body read failed");
        return ESP_OK;
    }
    s_rx[rx_len] = '\0';

    shell_ver_t shell = detect_shell(s_rx);

    /* 权威路由：Body 首子元素（tds/trt 双命名空间）；SOAPAction 尾段兜底
     * （实测 zeep 4.3.3 不发该头，见 ch13 §13.3）。 */
    int op_idx = svc_route_by_body(s_rx);
    if (op_idx < 0) {
        char action[96] = {0};
        if (httpd_req_get_hdr_value_str(req, "SOAPAction", action, sizeof(action)) == ESP_OK) {
            for (size_t i = 0; i < sizeof(kOps) / sizeof(kOps[0]); i++) {
                if (strstr(action, kOps[i].action_tail) != NULL) {
                    op_idx = (int)i; /* 兜底仅提示：ns 归属由 Body 为准，此处尽量匹配 */
                    break;
                }
            }
        }
    }

    if (op_idx < 0) {
        /* 白名单之外无特例：env:Receiver + ter:ActionNotSupported（HTTP 500） */
        send_soap(req, shell, shell == SHELL_SOAP12 ? BODY_FAULT_12 : BODY_FAULT_11,
                  "500 Internal Server Error");
        ESP_LOGI(TAG, "$$$ ONVIF LAB05 OP (unlisted) fault action-not-supported");
        return ESP_OK;
    }

    const char *local = kOps[op_idx].local;
    if (kOps[op_idx].needs_auth) {
        auth_rc_t rc = onvif_auth_verify(s_rx); /* 五环判据链，分因落 run.log */
        if (rc != AUTH_OK) {
            send_soap(req, shell,
                      shell == SHELL_SOAP12 ? BODY_FAULT_AUTH_12 : BODY_FAULT_AUTH_11,
                      "500 Internal Server Error");
            return ESP_OK;
        }
    }
    if ((kOps[op_idx].serve == serve_snapshot_uri ||
         kOps[op_idx].serve == serve_stream_uri) &&
        strstr(s_rx, ">profile_1<") == NULL) {
        /* 未知 ProfileToken：s:Sender + ter:InvalidArgVal（ch03 判据表；
         * HTTP 映射按壳分——1.2 Sender→400，1.1 Fault 一律 500） */
        send_soap(req, shell, shell == SHELL_SOAP12 ? BODY_FAULT_TOKEN_12 : BODY_FAULT_TOKEN_11,
                  shell == SHELL_SOAP12 ? "400 Bad Request" : "500 Internal Server Error");
        ESP_LOGI(TAG, "$$$ ONVIF LAB05 OP GetSnapshotUri fault invalid-arg-val");
        return ESP_OK;
    }

    esp_err_t ret = kOps[op_idx].serve(req, s_body, SVC_BODY_BUF);
    if (ret != ESP_OK) {
        svc_log_op(local, false);
        return ret;
    }
    ret = send_soap(req, shell, s_body, NULL);
    svc_log_op(local, ret == ESP_OK);
    return ret;
}

/* GET 一律 405：ONVIF 契约随规范发布，设备端点不吐 WSDL（ch03 §3.3 纪律）。 */
static esp_err_t onvif_svc_get_handler(httpd_req_t *req)
{
    httpd_resp_set_status(req, "405 Method Not Allowed");
    httpd_resp_set_type(req, "text/plain");
    httpd_resp_sendstr(req, "device_service accepts SOAP POST only\n");
    return ESP_OK;
}

/* lab04 快照：GET 即快门——锁内拷贝 /stream 同源的最新成品 JPEG，零额外编码。
 * 免鉴权直出为明示的内网实验形态边界（HTTP Digest/TLS 列为后续增强，ch15 §15.3）。 */
static esp_err_t onvif_snapshot_handler(httpd_req_t *req)
{
    const ssize_t n = factory_stream_copy_latest((uint8_t *)s_snapshot, SVC_SNAPSHOT_BUF);
    if (n <= 0) { /* 启动初期编码环还没交出第一帧 */
        /* IDF 6.1 esp_http_server 无 503 错误码枚举，手工置状态行 */
        httpd_resp_set_status(req, "503 Service Unavailable");
        httpd_resp_set_type(req, "text/plain");
        httpd_resp_sendstr(req, "no frame yet");
        return ESP_OK;
    }
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 SNAPSHOT bytes=%zd", n);
    httpd_resp_set_type(req, "image/jpeg");
    return httpd_resp_send(req, s_snapshot, (size_t)n);
}

static void onvif_svc_task(void *arg)
{
    /* 基座在 GOT_IP 处理器里 start httpd；等它就绪再注册。 */
    httpd_handle_t httpd = NULL;
    int waited = 0;
    while (httpd == NULL && waited < SVC_HTTPD_WAIT_MS) {
        httpd = factory_stream_httpd();
        if (httpd == NULL) {
            vTaskDelay(pdMS_TO_TICKS(200));
            waited += 200;
        }
    }
    if (httpd == NULL) {
        ESP_LOGE(TAG, "base httpd not up after %d ms, give up", SVC_HTTPD_WAIT_MS);
        vTaskDelete(NULL);
        return;
    }

    const httpd_uri_t post_uri = {
        .uri = "/onvif/device_service",
        .method = HTTP_POST,
        .handler = onvif_svc_handler,
    };
    const httpd_uri_t get_uri = {
        .uri = "/onvif/device_service",
        .method = HTTP_GET,
        .handler = onvif_svc_get_handler,
    };
    esp_err_t reg = httpd_register_uri_handler(httpd, &post_uri);
    if (reg == ESP_OK) {
        reg = httpd_register_uri_handler(httpd, &get_uri);
    }
    if (reg != ESP_OK) {
        ESP_LOGE(TAG, "register /onvif/device_service failed (%s)", esp_err_to_name(reg));
        vTaskDelete(NULL);
        return;
    }
    const httpd_uri_t media_post = {
        .uri = "/onvif/media_service",
        .method = HTTP_POST,
        .handler = onvif_svc_handler, /* 路由由 Body 命名空间+本地名决定，与 URI 无关 */
    };
    const httpd_uri_t media_get = {
        .uri = "/onvif/media_service",
        .method = HTTP_GET,
        .handler = onvif_svc_get_handler,
    };
    reg = httpd_register_uri_handler(httpd, &media_post);
    if (reg == ESP_OK) {
        reg = httpd_register_uri_handler(httpd, &media_get);
    }
    if (reg != ESP_OK) {
        ESP_LOGE(TAG, "register /onvif/media_service failed (%s)", esp_err_to_name(reg));
        vTaskDelete(NULL);
        return;
    }
    const httpd_uri_t snapshot_uri = {
        .uri = "/onvif-http/snapshot",
        .method = HTTP_GET,
        .handler = onvif_snapshot_handler,
    };
    reg = httpd_register_uri_handler(httpd, &snapshot_uri);
    if (reg != ESP_OK) {
        ESP_LOGE(TAG, "register /onvif-http/snapshot failed (%s)", esp_err_to_name(reg));
        vTaskDelete(NULL);
        return;
    }

    factory_stream_status_t st = {0};
    factory_stream_get_status(&st);
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 SVC READY http=%s:80/onvif/device_service",
             st.ip[0] != '\0' ? st.ip : "0.0.0.0");
    vTaskDelete(NULL);
}

esp_err_t onvif_svc_init(void)
{
    s_rx = heap_caps_malloc(SVC_RECV_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_body = heap_caps_malloc(SVC_BODY_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_tx = heap_caps_malloc(SVC_TX_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    s_snapshot = heap_caps_malloc(SVC_SNAPSHOT_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_rx == NULL || s_body == NULL || s_tx == NULL || s_snapshot == NULL) {
        heap_caps_free(s_rx);
        heap_caps_free(s_body);
        heap_caps_free(s_tx);
        heap_caps_free(s_snapshot);
        s_rx = s_body = s_tx = s_snapshot = NULL;
        return ESP_ERR_NO_MEM;
    }
    if (xTaskCreate(onvif_svc_task, "onvif_svc", SVC_TASK_STACK, NULL,
                    SVC_TASK_PRIO, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
