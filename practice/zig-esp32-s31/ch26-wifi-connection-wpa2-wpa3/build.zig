const std = @import("std");

// ch26-wifi-connection-wpa2-wpa3：形态 B 的构建入口。
//
// 没有 CMake、没有 IDF 组件、没有静态库、没有 Wi-Fi blob：Zig 把
// src/start.zig 链接成一个 ELF，段布局完全由 linker/s31.ld 决定。IDF 只负责
// 二级 bootloader 与分区表（见 idf-bootstrap/）。
//
// 本章的交付分两半：
//   1) 主机侧：WPA2 密钥派生/EAPOL 帧（wpa2.zig）、SAE 的字节层
//      （sae.zig）、连接状态机与事件队列（conn.zig），`zig build test`
//      在 x86_64 上跑 20 个用例；
//   2) 板侧：同一批模块在 rv32 + 真实 SRAM 下再跑一遍，13 条判据全部
//      打印 `check:` 行（见 src/selftest.zig 与 ../logs/ch26-boot.log）。
//
// **本章不链接 Wi-Fi/PHY blob**：没有 libnet80211.a / libpp.a / libcore.a，
// 也没有 libphy.a。真实 blob 的链接是 ch25 的边界与后续章节的事；本章
// 只做「能离线断言的那一层」。
//
// 目标与优化级别必须显式给出：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
//
// 产物：zig-out/bin/app.elf → esptool elf2image → app.bin → tools/flash.sh。
//
// 主机侧单测（x86_64，不涉及硬件）：
//   zig build test --summary all
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
    // 被测的三个模块都是纯逻辑：密码学字节层、状态机、环形队列。
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "host-side unit tests (wpa2/sae/conn vectors)");
    test_step.dependOn(&run_tests.step);
}
