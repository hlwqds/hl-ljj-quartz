idf_component_register(SRCS "lab_main.c"
                       PRIV_REQUIRES esp_eth esp_netif esp_event lwip freertos
                       INCLUDE_DIRS "")

# 实验参数可在命令行覆盖：idf.py -DCH19_APP_PRIO=21 build
set(CH19_APP_PRIO 5 CACHE STRING "echo server task priority")
add_compile_definitions(APP_ECHO_PRIO=${CH19_APP_PRIO})
