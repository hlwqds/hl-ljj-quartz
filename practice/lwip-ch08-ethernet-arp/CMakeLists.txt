# lwIP 深度解析（八）实验工程：以太网与 ARP
#
# 故障注入说明：
#   ARP_TABLE_SIZE 没有对应 Kconfig（上游 opt.h 默认 10，IDF 亦未覆盖），
#   本章用全局编译期 -D 注入覆盖（lwIP 所有宏都是 #ifndef 保护，编译器
#   预定义优先于 opt.h 的默认值）。
#
#   默认构建（表大小 10）:      idf.py build
#   表满故障注入（表大小 2）:   idf.py -DCH08_ARP_TABLE_SIZE=2 build
cmake_minimum_required(VERSION 3.22)

set(CH08_ARP_TABLE_SIZE "10" CACHE STRING "ARP_TABLE_SIZE override (ch8 fault injection)")
add_compile_definitions(ARP_TABLE_SIZE=${CH08_ARP_TABLE_SIZE})

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
idf_build_set_property(MINIMAL_BUILD ON)
project(lwip_ch08_ethernet_arp)
