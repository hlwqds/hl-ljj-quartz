idf_component_register(SRCS "lab_main.c"
                       PRIV_REQUIRES esp_eth esp_netif esp_event lwip freertos esp_timer
                       INCLUDE_DIRS "")
