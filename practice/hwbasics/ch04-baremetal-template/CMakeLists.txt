# ch04-baremetal-template -- CMake 等价构建（与 Makefile 二选一）
#
# 配置（无独立 toolchain 文件的最简方式）：
#   cmake -B build -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=arm \
#         -DCMAKE_C_COMPILER=arm-none-eabi-gcc -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
#   cmake --build build

cmake_minimum_required(VERSION 3.20)
project(ch04_baremetal C ASM)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mcpu=cortex-m3 -mthumb -Og -g3 \
-ffreestanding -fno-common -Wall -Wextra -ffunction-sections -fdata-sections")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} \
-mcpu=cortex-m3 -mthumb -nostdlib -T ${CMAKE_CURRENT_SOURCE_DIR}/mps2_an385.ld \
-Wl,--gc-sections -Wl,-Map=${CMAKE_CURRENT_BINARY_DIR}/ch04-baremetal.map")

add_executable(ch04-baremetal startup.S main.c)
