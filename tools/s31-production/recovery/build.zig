const std = @import("std");

// recovery：S31 生产化第二增量的故障恢复切片构建入口。
//
// 与 netmgr/ota 一致，这里不产出固件、不引用 IDF、不做交叉编译：
//   - `addModule` 把 src/recovery.zig 暴露成纯逻辑模块，供板侧工程或将来的
//     启动策略层引用；
//   - `zig build test` 只跑主机侧单测（`b.graph.host`），没有 riscv32 工具链
//     也能跑。
//
// 本次交付**未执行** `zig build test`。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 纯逻辑库模块：无分配、无 IO、无时钟、无持久化。
    _ = b.addModule("recovery", .{
        .root_source_file = b.path("src/recovery.zig"),
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

    const test_step = b.step("test", "host-side unit tests (recovery policy)");
    test_step.dependOn(&run_tests.step);
}
