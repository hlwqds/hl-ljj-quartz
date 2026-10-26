#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 注册 WS-Discovery 模块：记录设备 UUID（efuse MAC 派生）并挂
 *        GOT_IP 监听；拿到 STA 地址后自动起 UDP 3702 应答任务。
 *
 * 直接用 esp_netif/esp_event（IDF 平台服务），不依赖采集基座；
 * 在 factory_stream_init() 之后调用只是站点的启动顺序约定。
 */
esp_err_t onvif_disc_init(void);

#ifdef __cplusplus
}
#endif
