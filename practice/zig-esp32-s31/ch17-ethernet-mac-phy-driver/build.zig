const std = @import("std");

// ch17-ethernet-mac-phy-driver：形态 B 的构建入口。
//
// 没有 CMake、没有 IDF 组件、没有静态库：Zig 把 src/start.zig 链接成一个
// ELF，段布局完全由 linker/s31.ld 决定。IDF 只负责二级 bootloader 与
// 分区表（见 idf-bootstrap/）。
//
// 构建：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
// 产物：zig-out/bin/app.elf → esptool elf2image → zig-out/bin/app.bin。
//
// 构建选项：
//   -Dskip-mdio=true   跳过 MDIO 扫描（PHY 还没接线时先验证“不会卡在忙等”）
//
// 主机侧单测（x86_64，不碰硬件）：
//   zig build test
// 覆盖 src/descs.zig、src/regs.zig、src/phy.zig、src/pins.zig 与
// src/emac.zig 里的纯逻辑（描述符布局、位域编码、PHY ID 解码、环索引）。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skip_mdio = b.option(bool, "skip-mdio", "skip the MDIO/PHY scan stage") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "skip_mdio", skip_mdio);

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/start.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    app.root_module.addOptions("build_options", options);

    // 链接脚本是形态 B 的核心：ENTRY(_start)、两个 flash 装载段、.trap_ram。
    app.setLinkerScript(b.path("linker/s31.ld"));

    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "host-side unit tests (descriptors, register fields, PHY decode)");
    test_step.dependOn(&run_tests.step);
}
