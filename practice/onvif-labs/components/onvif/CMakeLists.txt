idf_component_register(
    SRCS
        "src/onvif_disc.c"
        "src/onvif_auth.c"
        "src/onvif_svc.c"
        "src/onvif_rtsp.c"
        "src/onvif_stats.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_http_server esp_timer heap mbedtls lwip esp_wifi nvs_flash esp_netif esp_event esp_app_format
)
