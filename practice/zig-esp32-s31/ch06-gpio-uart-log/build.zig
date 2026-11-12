const std = @import("std");

// ch06-gpio-uart-log：形态 B 的构建入口（与 ch04 同一骨架）。
//
// 这里没有 CMake、没有 IDF 组件、没有静态库：Zig 直接把 src/start.zig 链接成
// 一个 ELF，段的摆放完全由 linker/s31.ld 决定。IDF 在这条链里只负责二级
// bootloader 与分区表（见 idf-bootstrap/）。
//
// 目标与优化级别必须显式给出：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
//
// 产物：zig-out/bin/app.elf，之后由 esptool elf2image 转成 app.bin，
// 再由 tools/flash.sh 烧录到 factory 应用槽（偏移来自 flash_args）。
//
// 本章新增的模块（uart/gpio/log/panic）都是 src/main.zig 用 @import 拉进来的，
// 不需要在 build.zig 里逐个登记：Zig 的“引用图”从根文件开始，main.zig 通过
// start.zig 的 @import 进入编译，模块图自动展开。
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
    // .bss 边界符号全在里面。本章额外依赖它把 .text.entry（trap 向量）放在
    // 第一个装载段的最前面，便于 mtvec 直接指向一个稳定的 4 字节对齐地址。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}
