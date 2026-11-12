# ch18-ipv4-icmp-arp-routing / idf-bootstrap：main 组件只有空 app_main.c。
#
# 这里不调用 zig、不链接任何 Zig 产物。构建的目的是让 IDF 顺带生成：
#   build/bootloader/bootloader.bin
#   build/partition_table/partition-table.bin
#   build/flash_args
# 应用镜像由 ../zig-out/bin/app.bin 顶替，偏移由 flash_args 决定。
idf_component_register(SRCS "app_main.c" INCLUDE_DIRS ".")
