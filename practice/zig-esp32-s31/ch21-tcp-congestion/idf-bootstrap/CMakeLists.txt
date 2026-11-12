# ch21-tcp-congestion / idf-bootstrap
#
# 这个 IDF 工程只做一件事：产出二级 bootloader、分区表与 flash_args。
# 它不链接本工程的 Zig 代码，也不构建真正的应用（main/app_main.c 是空实现）；
# 应用 ELF 由 ../build.zig 产出，应用镜像由 ../tools/flash.sh 烧到 0x10000。
#
# 构建（目标为 IDF v6.1 的 preview target）：
#   idf.py --preview set-target esp32s31
#   idf.py build
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(zig_s31_bootstrap_ch21)
