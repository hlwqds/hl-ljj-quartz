idf_component_register(SRCS "main.c"
                       PRIV_REQUIRES esp_eth esp_netif esp_event lwip
                                     esp_http_server esp_timer freertos
                       INCLUDE_DIRS "")
