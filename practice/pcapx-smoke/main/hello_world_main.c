/*
 * pcapx 组件集成冒烟：编译期覆盖全部源文件的编译，运行期只做无网卡的
 * API 面（attach 前的 stats/is_attached + 一次预期失败的 attach 调用）。
 */
#include <inttypes.h>
#include "esp_log.h"
#include "pcapx.h"

static const char *SMOKE_TAG = "smoke";

void app_main(void)
{
    pcapx_stats_t st = { 0 };
    pcapx_get_stats(&st);
    ESP_LOGI(SMOKE_TAG, "attached=%d rx=%" PRIu32 " tx=%" PRIu32,
             pcapx_is_attached(), st.rx, st.tx);

    /* netif=NULL 走 ATTACH_FAIL reason=arg 的错误路径，验证日志契约 */
    pcapx_config_t cfg = {
        .netif = NULL,
        .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
        .snaplen = 128,
        .sink = NULL,
    };
    esp_err_t err = pcapx_attach(&cfg);
    printf("pcapx smoke: attach(null) -> %s\n", esp_err_to_name(err));
}
