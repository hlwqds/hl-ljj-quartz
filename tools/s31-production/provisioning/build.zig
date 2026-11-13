const std = @import("std");

// provisioning：S31 生产化配网切片的主机构建入口。
//
// 这里不产出固件、不引用 IDF、不做交叉编译：
//   - `addModule` 把 src/provisioning.zig 暴露成纯逻辑模块，供板侧工程或
//     将来的配网服务适配层引用；
//   - `zig build test` 只跑主机侧单测（宿主目标），没有 riscv32 工具链也能跑。
//
// 本切片交付时**未执行**上述命令（见 README 的「未验证边界」）。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 纯逻辑库模块：无分配、无 IO、无时钟。
    _ = b.addModule("provisioning", .{
        .root_source_file = b.path("src/provisioning.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 主机侧单测：强制宿主目标，与交叉编译选项无关。
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "host-side unit tests (provisioning state machine)");
    test_step.dependOn(&run_tests.step);
}
