const std = @import("std");

// ch23-tls-http：形态 B 的构建入口。
//
// 没有 CMake、没有 IDF 组件、没有静态库：Zig 把 src/start.zig 链接成一个
// ELF，段布局完全由 linker/s31.ld 决定。IDF 只负责二级 bootloader 与分区表
// （见 idf-bootstrap/）。
//
// 本章的主要交付在主机侧：TLS 记录层（tls_record.zig）、TLS 1.3 密钥派生
// （tls_keyschedule.zig）、X25519/AES-GCM 的已知答案（x25519.zig / aead.zig）、
// DER 证书解析（cert.zig）、HTTP/1.1 解析（http.zig）都不碰硬件，
// `zig build test` 在 x86_64 上就能跑完。板侧只保留一只自检：用同一份模块
// 把十二条判据各走一遍，打印判读行。
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
//
// 证书 fixture 生成（只在证书字段/密钥 seed 变化时需要重跑）：
//   zig build gen-fixture      -> src/testdata/sample-cert.der
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
    // 被测试的六个模块都是纯逻辑：记录层分片、HKDF、X25519、AES-GCM、
    // DER 证书、HTTP/1.1 解析。
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "host-side unit tests (TLS record/keyschedule/AEAD/DER/HTTP)");
    test_step.dependOn(&run_tests.step);

    // 生成证书 fixture。工具本身不联网、不用随机数：密钥来自固定 seed，
    // ECDSA 的 k 来自固定 noise，所以同一份源码永远产出同一串字节。
    const gen = b.addExecutable(.{
        .name = "gen-cert-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_cert_fixture.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_gen = b.addRunArtifact(gen);
    run_gen.setCwd(b.path("."));
    run_gen.expectExitCode(0);
    const gen_step = b.step("gen-fixture", "regenerate src/testdata/sample-cert.der");
    gen_step.dependOn(&run_gen.step);
}
