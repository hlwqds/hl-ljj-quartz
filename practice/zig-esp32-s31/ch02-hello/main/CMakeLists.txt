# ch02：Zig 静态库 + IDF 组件的集成点。
#
# 数据流：
#   main/main.zig --(zig build)--> <build>/main/zig-out/lib/libmain_zig.a
#                                     |
#   main/idf_anchor.c --(IDF)--> libmain.a --(最终链接)--> zig_s31_hello.elf
#
# 关键约束：
#   - zig build 必须在工程根目录执行（build.zig 在那里）；
#   - 静态库先产出，组件再链接，所以用 custom target 建立顺序依赖；
#   - .a 通过 INTERFACE 挂到 main 组件上，最终链接才能看到 app_main。

find_program(ZIG_EXECUTABLE zig REQUIRED)

set(ZIG_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/zig-out")
set(ZIG_LIB "${ZIG_OUT_DIR}/lib/libmain_zig.a")

idf_component_register(SRCS "idf_anchor.c" INCLUDE_DIRS ".")

add_custom_command(
    OUTPUT "${ZIG_LIB}"
    COMMAND "${ZIG_EXECUTABLE}" build
            -Dtarget=riscv32-freestanding-eabihf
            -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei
            -Doptimize=ReleaseSmall
            --prefix "${ZIG_OUT_DIR}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/../build.zig"
        "${CMAKE_CURRENT_SOURCE_DIR}/main.zig"
    COMMENT "zig build: libmain_zig.a (riscv32-freestanding-eabihf)"
    VERBATIM
)

add_custom_target(zig_main ALL DEPENDS "${ZIG_LIB}")

add_dependencies(${COMPONENT_LIB} zig_main)

target_link_libraries(${COMPONENT_LIB} INTERFACE "${ZIG_LIB}")
