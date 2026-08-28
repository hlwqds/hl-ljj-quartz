idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS ""
    PRIV_REQUIRES esp_eth esp_netif esp_event esp_timer lwip
)
