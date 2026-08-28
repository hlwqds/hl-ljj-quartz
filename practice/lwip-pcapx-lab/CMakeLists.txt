# The following lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.22)

# 引入 pcapx 组件（S1+S2 交付物，见 ../pcapx/README.md 集成一节）
set(EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_LIST_DIR}/../pcapx")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# "Trim" the build. Include the minimal set of components, main, and anything it depends on.
idf_build_set_property(MINIMAL_BUILD ON)
project(lwip_pcapx_lab)
