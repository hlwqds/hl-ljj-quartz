# ch07-nvic-exti -- CMake 等价构建（与 Makefile 二选一）
#
# 配置：
#   cmake -B build -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=arm \
#         -DCMAKE_C_COMPILER=arm-none-eabi-gcc -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
#   cmake --build build

cmake_minimum_required(VERSION 3.20)
project(ch07_nvic_exti C ASM)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mcpu=cortex-m3 -mthumb -Og -g3 \
-ffreestanding -fno-common -Wall -Wextra -ffunction-sections -fdata-sections")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} \
-mcpu=cortex-m3 -mthumb -nostdlib -T ${CMAKE_CURRENT_SOURCE_DIR}/mps2_an385.ld \
-Wl,--gc-sections -Wl,-Map=${CMAKE_CURRENT_BINARY_DIR}/ch07-nvic-exti.map")

add_executable(ch07-nvic-exti startup.S main.c)
