#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 注册 WS-Discovery 模块：记录设备 UUID（efuse MAC 派生）并挂
 *        GOT_IP 监听；拿到 STA 地址后自动起 UDP 3702 应答任务。
 *
 * 必须在 factory_stream_init() 之后调用（依赖其 netif/事件基础设施）。
 */
esp_err_t onvif_disc_init(void);

#ifdef __cplusplus
}
#endif
