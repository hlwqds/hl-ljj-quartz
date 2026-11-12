const std = @import("std");

// ch16-stack-architecture-zero-copy：形态 B 的构建入口。
//
// 没有 CMake、没有 IDF 组件、没有静态库：Zig 把 src/start.zig 链接成一个
// ELF，段布局完全由 linker/s31.ld 决定。IDF 只负责二级 bootloader 与分区表
// （见 idf-bootstrap/）。
//
// 和 ch15 不同，本章的**主要交付是主机侧**：协议栈的纯逻辑（pbuf 链/引用计数、
// 校验和、首部编解码、netif 输出路径、timer wheel）全部不碰硬件，
// `zig build test` 在 x86_64 上就能跑完。板侧只保留一只自检：
// 构造一帧以太网/IPv4/UDP，经 loopback netif 走一圈，打印判读行。
//
// 目标与优化级别必须显式给出：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
//
// 产物：zig-out/bin/app.elf，之后由 esptool elf2image 转成 app.bin，
// 再由 tools/flash.sh 烧到 factory 应用槽（偏移来自 flash_args）。
//
// 主机侧单测（x86_64，不涉及硬件）：
//   zig build test
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

    // 链接脚本是形态 B 的核心：ENTRY(_start)、两个 flash 装载段、.trap_ram。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);

    // 主机侧单测：独立模块、宿主目标，不碰 start.zig/hw.zig/trap.zig。
    // 被测试的五个模块都是纯逻辑（只有 netif 接收一个字节缓冲指针，仍不碰 MMIO）。
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "host-side unit tests (pbuf + checksum + headers + netif + timer wheel)");
    test_step.dependOn(&run_tests.step);
}
