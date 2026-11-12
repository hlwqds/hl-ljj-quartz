const std = @import("std");

// ch15-observability-testing-stability：形态 B 的构建入口。
//
// 没有 CMake、没有 IDF 组件、没有静态库：Zig 把 src/start.zig 链接成一个 ELF，
// 段布局完全由 linker/s31.ld 决定。IDF 只负责二级 bootloader 与分区表
// （见 idf-bootstrap/）。
//
// 目标与优化级别必须显式给出：
//   zig build -Dtarget=riscv32-freestanding-eabihf \
//     -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
//
// 产物：zig-out/bin/app.elf，之后由 esptool elf2image 转成 app.bin，
// 再由 tools/flash.sh 烧到 factory 应用槽（偏移来自 flash_args）。
//
// 两个构建选项（默认值让“演示一次 panic”成立）：
//   -Dstress=true       在 panic 演示前跑 30 s 压测
//   -Dpanic-demo=false  不执行非法指令，跑完自检与心跳后停在 wfi
//
// 主机侧单测（x86_64，不涉及硬件）：
//   zig build test
// 只测试 src/trace.zig 与 src/watchdog.zig 两个纯逻辑模块。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stress = b.option(bool, "stress", "run the 30 s soak before the panic demo") orelse false;
    const panic_demo = b.option(bool, "panic-demo", "end the run with a deliberately illegal instruction") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "stress", stress);
    options.addOption(bool, "panic_demo", panic_demo);

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/start.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    app.root_module.addOptions("build_options", options);

    // 链接脚本是形态 B 的核心：ENTRY(_start)、两个 flash 装载段、.trap_ram，
    // 以及自检要读的全部边界符号（_image_start/_text_*/_rodata_*/_bss_* …）。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);

    // 主机侧单测：独立模块、宿主目标，不碰 hw.zig/trap.zig。
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "host-side unit tests (trace ring + soft watchdog)");
    test_step.dependOn(&run_tests.step);
}
