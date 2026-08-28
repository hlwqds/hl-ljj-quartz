idf_component_register(SRCS "src/pcapx_core.c"
                            "src/pcapx_sink_semihost.c"   # S2: 半托管 sink（含 -semihosting 提示行）
                            "src/pcapx_sink_ram.c"        # S2: RAM 暂存 sink
                            "src/pcapx_sink_uart.c"       # S2: UART 帧 sink
                            "src/pcapx_console.c"         # S2: esp_console 导出子命令
                       INCLUDE_DIRS "include"
                       # REQUIRES：pcapx.h 公共头自身依赖（lwip/netif.h、esp_err.h、esp_timer 无公共头依赖）
                       REQUIRES lwip esp_timer
                       # PRIV_REQUIRES：仅实现文件需要的组件——
                       # console=esp_console.h(组件根目录)、esp_driver_uart=driver/uart.h、
                       # vfs=esp_vfs_semihost.h、xtensa=xtensa/semihosting.h、heap=esp_heap_caps.h、log=esp_log.h
                       PRIV_REQUIRES console esp_driver_uart vfs xtensa heap log)
