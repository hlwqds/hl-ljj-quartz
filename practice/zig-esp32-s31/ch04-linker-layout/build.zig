const std = @import("std");

// ch04-linker-layout：形态 B 的构建入口。
//
// 与 ch02 的形态 A 相比，这里没有 CMake、没有 IDF 组件、没有静态库：
// Zig 直接把 src/start.zig 链接成一个 ELF，段的摆放完全由 linker/s31.ld 决定。
// IDF 在这条链里只负责二级 bootloader 与分区表（见 idf-bootstrap/）。
//
// 目标与优化级别必须显式给出：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
//
// 产物：zig-out/bin/app.elf
// 之后由 esptool elf2image 转成 app.bin，再由 tools/flash.sh 烧录。
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

    // 链接脚本是形态 B 的核心：ENTRY(_start)、MEMORY 区间、段顺序、栈顶与
    // .bss 边界符号全在里面。没有它，Zig 会按默认布局链接，入口也不是 _start。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    // 默认名是 zig-out/bin/app（无扩展名），不便于区分 ELF 与 .bin。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}
