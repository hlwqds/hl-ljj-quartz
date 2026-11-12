# ch02-hello：IDF 工程入口。
#
# 这个文件只负责“这是一个 ESP-IDF 工程”，真正的 Zig/CMake 集成交给
# main/CMakeLists.txt。构建前必须先 source IDF 的导出脚本（export.sh /
# export.ps1），否则 project.cmake 找不到。
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(zig_s31_hello)
