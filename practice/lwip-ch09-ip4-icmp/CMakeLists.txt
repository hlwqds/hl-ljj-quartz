# The following lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.22)

# ch9 实验注入：打开 SNMP MIB2 统计（ipreasmreqds/ipreasmoks/ipreasmfails），
# IDF 的 Kconfig 没有暴露 MIB2_STATS，只能编译期全局定义。
add_compile_definitions(MIB2_STATS=1)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# "Trim" the build. Include the minimal set of components, main, and anything it depends on.
idf_build_set_property(MINIMAL_BUILD ON)
project(lwip_ch09_ip4_icmp)
