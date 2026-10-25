#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 创建 onvif_svc 装载任务：等基座 80 端口 httpd 起来后，注册
 *        POST /onvif/device_service（SOAP 控制面最小集，契约见 ch13/SPEC §6 lab02）。
 *
 * 必须在 factory_stream_init() 之后调用；GOT_IP → httpd start 由基座负责。
 */
esp_err_t onvif_svc_init(void);

#ifdef __cplusplus
}
#endif
