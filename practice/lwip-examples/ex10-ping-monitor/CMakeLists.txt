cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Trim 构建：只编最小组件集 + main + 其依赖（套件标准形态）
idf_build_set_property(MINIMAL_BUILD ON)
project(ex10_ping_monitor)
