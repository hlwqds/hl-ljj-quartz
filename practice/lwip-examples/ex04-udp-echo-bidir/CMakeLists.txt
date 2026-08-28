cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Trim 构建：只编最小组件集（套件标准形态，见 ../SPEC.md §3）
idf_build_set_property(MINIMAL_BUILD ON)
project(ex04_udp_echo_bidir)
