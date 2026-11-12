# ch09-flash-partition-nvs / idf-bootstrap
#
# 这个 IDF 工程只做一件事：产出二级 bootloader、分区表与 flash_args。
# 它不链接本工程的 Zig 代码，也不构建真正的应用（main/app_main.c 是空实现）；
# 应用 ELF 由 ../build.zig 产出，应用镜像由 ../tools/flash.sh 烧到 0x10000。
#
# 分区表来自本目录的 partitions.csv（由 sdkconfig.defaults 的
# CONFIG_PARTITION_TABLE_CUSTOM=y 打开）。改 CSV 后必须让 sdkconfig 重新生成，
# 否则构建仍用旧表：删掉 sdkconfig 再 build，或走一次 menuconfig。
#
# 构建（目标为 IDF v6.1 的 preview target）：
#   idf.py --preview set-target esp32s31
#   idf.py build
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(zig_s31_bootstrap_ch09)
