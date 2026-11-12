const std = @import("std");

pub fn build(b: *std.Build) void {
    // 主机侧工具：默认构建宿主目标（不需要 riscv32 交叉编译）。
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "s31-image-inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // zig build run -- <file>
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the image/partition inspector on a local file");
    run_step.dependOn(&run_cmd.step);
}
