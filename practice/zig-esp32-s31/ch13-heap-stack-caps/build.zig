const std = @import("std");

// ch13-heap-stack-caps：形态 B 的构建入口（与 ch11 同一骨架）。
//
// 没有 CMake、没有 IDF 组件、没有静态库：Zig 把 src/start.zig 链接成一个 ELF，
// 段布局完全由 linker/s31.ld 决定。IDF 只负责二级 bootloader 与分区表
// （见 idf-bootstrap/）。
//
// 目标与优化级别必须显式给出：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
//
// 产物：zig-out/bin/app.elf，之后由 esptool elf2image 转成 app.bin，
// 再由 tools/flash.sh 烧到 factory 应用槽（偏移来自 flash_args）。
//
// 本章的模块全部由根文件 start.zig 展开的 import 图带进来：
//   src/{start,trap,log,main,caps,heap,stack_guard,psram}.zig
//   src/alloc/{tlsf,slab}.zig
// 不需要在 build.zig 里逐个登记。
//
// 主机侧单测（x86_64，不涉及硬件）：
//   zig test src/alloc/tlsf.zig
//   zig test src/alloc/slab.zig    （顺带跑 tlsf 的测试）
//   zig test src/caps.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/start.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 链接脚本是形态 B 的核心：ENTRY(_start)、两个 flash 装载段、.trap_ram、
    // 以及本章新增的 _heap_start/_heap_end/_stack_bottom/_stack_top 边界符号。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}
