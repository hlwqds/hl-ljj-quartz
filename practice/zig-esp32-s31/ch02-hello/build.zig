const std = @import("std");

// 形态 A 的 Zig 侧：只产出一个静态库，不负责链接。
//
// 目标三元组与 CPU 特性由命令行注入（IDF 的 CMake 自定义命令会传）：
//   -Dtarget=riscv32-freestanding-eabihf
//   -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei
//   -Doptimize=ReleaseSmall
//
// `standardTargetOptions` 同时解析 -Dtarget 与 -Dcpu；`installArtifact`
// 把库安装到 `--prefix` 指定的目录，即 <prefix>/lib/libmain_zig.a。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "main_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(lib);
}
