idf_component_register(SRCS "state_lab.c"
                       PRIV_REQUIRES esp_eth esp_netif esp_event esp_timer lwip
                       INCLUDE_DIRS ".")

# 注意：hook 的注入在根 CMakeLists.txt 用 add_compile_options 全局完成
# （MINIMAL_BUILD 下组件 target 在组件级 CMakeLists 中不可见）。

