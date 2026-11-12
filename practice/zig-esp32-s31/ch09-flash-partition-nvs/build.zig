const std = @import("std");

// ch09-flash-partition-nvs：形态 B 的构建入口（与 ch04/ch08 同一骨架）。
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
// 本章新增的模块（flash/partition/kv）都是 src/main.zig 用 @import 拉进来的，
// 不需要在 build.zig 里逐个登记：编译从根文件 start.zig 开始，模块图自动展开。
//
// 关键前提：本章所有段都在 SRAM（见 linker/s31.ld）。写/擦 flash 期间 CPU
// 不从 flash 取指，因此不需要显式挂起 cache；如果将来把 .text 放回 flash，
// 这个前提就被打破，必须在 flash.zig 的临界窗口里补 cache 挂起/恢复。
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
    // 栈顶与 .bss 边界符号全在里面。本章沿用 ch04 的 SRAM-only 布局，
    // .data 的 LMA == VMA，因此 _start 里没有搬运步骤。
    //
    // 本章额外在脚本里 PROVIDE 了三个 ROM 符号：
    //   esp_rom_spiflash_read / _write / _erase_sector
    // 地址来自 IDF v6.1 的 esp32s31.rom.ld。代码里也可以用 @ptrFromInt
    // 直接调用；这里给符号是为了让反汇编与 nm 能看出“这是一次 ROM 调用”。
    app.setLinkerScript(b.path("linker/s31.ld"));

    // 安装成 zig-out/bin/app.elf：elf2image 与 tools/flash.sh 都按这个名字取文件。
    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}
