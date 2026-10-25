set(COFFEE_UI_DIR "${CMAKE_CURRENT_LIST_DIR}/../ui")

idf_component_register(
    SRCS
        "main.c"
        "factory_console.c"
        "factory_demo_camera.c"
        "factory_demo_stream.c"
        "onvif_disc.c"
        "onvif_svc.c"
        "onvif_auth.c"
    INCLUDE_DIRS "."
    REQUIRES esp32_s31_korvo esp_timer heap esp_driver_ppa esp_mm esp_lvgl_adapter esp_wifi nvs_flash esp_netif esp_event esp_http_server esp_driver_jpeg console esp_app_format mbedtls lwip
)
