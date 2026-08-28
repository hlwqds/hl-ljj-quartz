# The following lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# "Trim" the build. Include the minimal set of components, main, and anything it depends on.
idf_build_set_property(MINIMAL_BUILD ON)
# 编译期注入：把 LWIP_HOOK_IP4_INPUT 宏与原型强制包含进所有组件编译单元，
# 使 lwIP core 的 ip4.c 调用 ch11_ip4_input_hook()（零上游源码改动，见 main/ch11_ip4_hook.h）。
add_compile_options(-include "${CMAKE_CURRENT_SOURCE_DIR}/main/ch11_ip4_hook.h")
project(lwip_ch11_tcp_state_machine)
