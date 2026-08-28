idf_component_register(SRCS "lab_main.c"
                       PRIV_REQUIRES esp_wifi esp_eth esp_netif esp_event lwip
                       INCLUDE_DIRS ".")
