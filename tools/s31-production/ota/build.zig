const std = @import("std");

// S31 生产化切片 B：OTA 规划器的主机构建入口。
//
// 本切片没有可执行文件、没有烧录产物、没有 IDF 依赖：所有交付都是
// 纯逻辑 + 主机侧测试。唯一的步骤是：
//
//   zig build test
//
// 它用宿主目标编译两个测试根并运行：
//
//   src/host_tests.zig      # otadata / 选槽 / 状态机
//   src/manifest_tests.zig  # 生产清单校验（结构 → 版本 → 注入式 Verifier）
//
// 不碰 flash、串口或网络。主线已于 2026-11-13 执行：8/8 通过（见 README 的
// “未验证边界”）。
pub fn build(b: *std.Build) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/manifest_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_manifest_tests = b.addRunArtifact(manifest_tests);
    const test_step = b.step("test", "主机侧纯逻辑测试（otadata / 选槽 / 状态机 / 清单）");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_manifest_tests.step);
}
