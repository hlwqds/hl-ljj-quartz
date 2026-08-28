idf_component_register(SRCS "main.c" "zc_common.c" "zc_casea.c" "zc_caseb.c"
                             "zc_casec.c" "zc_cased.c" "zc_casee.c"
                       PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer
                                     freertos
                       INCLUDE_DIRS "")
