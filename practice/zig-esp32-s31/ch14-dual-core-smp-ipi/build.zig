const std = @import("std");

// ch14-dual-core-smp-ipi：形态 B 的构建入口（与 ch04/ch08/ch10–ch13 同一骨架）。
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
// 本章新增三个模块，全部由 src/start.zig 的模块图自动展开，不需要在
// build.zig 里登记：
//   - src/smp.zig      ：PerCpu（每核数据）、core1 启动、IPI 收发
//   - src/clic.zig     ：每核 CLIC（本核 0x10800000、对核 +0x10000）
//   - src/tick.zig     ：core0 用 TIMG0 T0，core1 用 TIMG0 T1
//
// 注意：本章仍是纯整数上下文（64 字节 switch 帧、80 字节 trap 帧）。
// `-Dcpu` 里的 `f` 只影响指令集与 eabihf ABI，不会自动保存 f 寄存器；
// 两个核共用同一份代码，FP 帧（208 字节）与本章无关。
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

    // 链接脚本是形态 B 的核心：ENTRY(_start)、MEMORY 区间、段顺序、
    // 每个任务的栈顶与 .bss 边界符号全在里面。
    //
    // 本章的两条硬约束：
    //   1) 镜像必须正好两个 flash 段（bootloader 断言 rom_index == 2）；
    //   2) trap 向量必须落在 SRAM 的 `.trap_ram` 里 —— 两个核共用同一个
    //      trapEntry，各自 csrw mtvec 指向它，放 flash 会 CPU_LOCKUP_RESET。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}
