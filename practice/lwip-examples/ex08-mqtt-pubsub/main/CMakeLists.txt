idf_component_register(SRCS "main.c"
                       PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer mqtt
                       INCLUDE_DIRS "")
