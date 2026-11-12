//! ch10-context-switch-scheduler：形态 B 的启动代码 + IDF 应用描述。
//!
//! 与 ch04/ch08/ch09 的 start.zig 结构一致，只多了一步：
//!
//!   **安装 mtvec**。本章的让出走 `ecall`（同步异常），必须有一个
//!   可用的 trap 入口。`mtvec` 的 MODE=0（直接模式）就够了：所有异常
//!   都跳到 `trapEntry`，由它保存现场并调用 `trapDispatch`。
//!
//! `_start` 的固定顺序：
//!   1) 关全局中断   —— mstatus.MIE=0、mie=0
//!   2) 设置 sp / gp —— sp = _stack_top；gp = __global_pointer$
//!   3) 清零 .bss    —— [_bss_start, _bss_end)（任务的栈数组在这里被清零）
//!   4) 安装 mtvec   —— mtvec = trapEntry（4 字节对齐，模式 0）
//!   5) 调用 main    —— call main；返回后进 wfi 死循环
//!
//! 中断始终不开：协作式调度不需要异步抢占，`ecall` 也不依赖 `mstatus.MIE`。
//! 第 11 章把 tick 接进来时，才需要在这里打开 `MIE` 并配置 CLIC 输入。

const builtin = @import("builtin");
const app = @import("main.zig");
const context = @import("context.zig");

// ---------------------------------------------------------------------------
// IDF 应用描述（esp_app_desc_t）
//
// 字段顺序与 IDF v6.1 的 components/esp_app_format/include/esp_app_desc.h
// 一致，整个结构在镜像里占 256 字节。bootloader 无条件读它：
//   - process_segment 用 mmu_page_size 决定映射页大小，读不到就报
//     "Failed to fetch app description header!"；
//   - efuse 块版本兼容性检查读 min/max_efuse_blk_rev_full；
//   - process_esp_app_desc_data 里还有一条魔数断言。
// ---------------------------------------------------------------------------
const AppDesc = extern struct {
    magic_word: u32,
    secure_version: u32,
    reserv1: [2]u32,
    version: [32]u8,
    project_name: [32]u8,
    time: [16]u8,
    date: [16]u8,
    idf_ver: [32]u8,
    app_elf_sha256: [32]u8,
    min_efuse_blk_rev_full: u16,
    max_efuse_blk_rev_full: u16,
    /// MMU 页大小的 log2：16 表示 64 KiB。
    mmu_page_size: u8,
    /// SPI flash 模式：2 表示 DIO，必须与 elf2image 的 --flash-mode 一致。
    spi_flash_mode: u8,
    reserv3: u16,
    /// IDF 结构体里这里是 reserv2[18]（18 个 u32，共 72 字节）。
    reserv2: [72]u8,
};

/// 把字符串放进定长、零填充的字段。
fn fixed(comptime text: []const u8, comptime size: usize) [size]u8 {
    var out: [size]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

comptime {
    if (@sizeOf(AppDesc) != 256) {
        @compileError("esp_app_desc_t 在镜像里必须是 256 字节");
    }
    if (@offsetOf(AppDesc, "magic_word") != 0) @compileError("magic_word 必须在偏移 0");
    if (@offsetOf(AppDesc, "idf_ver") != 112) @compileError("idf_ver 必须在偏移 112");
    if (@offsetOf(AppDesc, "app_elf_sha256") != 144) @compileError("sha256 必须在偏移 144");
    if (@offsetOf(AppDesc, "mmu_page_size") != 180) @compileError("mmu_page_size 必须在偏移 180");
    if (@offsetOf(AppDesc, "spi_flash_mode") != 181) @compileError("spi_flash_mode 必须在偏移 181");
}

/// 放在第一个装载段最前面（linker/s31.ld 里 `KEEP(*(.app_desc))`）。
/// `export` 保证它一定被发射，`linksection` 保证它落在 `.app_desc` 里。
export const app_desc: AppDesc linksection(".app_desc") = .{
    .magic_word = 0xABCD5432,
    .secure_version = 0,
    .reserv1 = .{ 0, 0 },
    .version = fixed("ch10-context-switch", 32),
    .project_name = fixed("ch10-context-switch-scheduler", 32),
    .time = fixed("00:00:00", 16),
    .date = fixed("2026-11-25", 16),
    .idf_ver = fixed("v6.1", 32),
    .app_elf_sha256 = @splat(0),
    .min_efuse_blk_rev_full = 0,
    .max_efuse_blk_rev_full = 0,
    .mmu_page_size = 16, // log2(64 KiB)
    .spi_flash_mode = 2, // DIO
    .reserv3 = 0,
    .reserv2 = @splat(0),
};

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch10-context-switch-scheduler 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch10-context-switch-scheduler 需要 eabihf（硬浮点）ABI");
    }

    // 下面汇编里的 `call main` 与 `la t0, trapEntry` 对 Zig 的引用图是不可见的：
    // 它们只是字符串。不显式引用，符号不会出现在目标文件里，链接期表现为
    // `undefined symbol: main` / `undefined symbol: trapEntry`。
    _ = &app.main;
    _ = &context.trapEntry;
}

/// 应用入口。符号名由链接脚本的 ENTRY(_start) 指定，也是 elf2image 写进
/// 镜像头 entry 字段的地址。
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\        # ---- 1) 关全局中断 ----
        \\        csrci   mstatus, 0x8          # mstatus.MIE = 0
        \\        csrw    mie, zero             # 关掉所有中断源
        \\
        \\        # ---- 2) 设置栈指针与 gp ----
        \\        la      sp, _stack_top        # 向下增长；_stack_top 16 字节对齐
        \\        la      gp, __global_pointer$ # 链接器 relaxation 的 small-data 锚点
        \\
        \\        # ---- 2.5) 关掉 RTC/LP 看门狗 ----
        \\        # 真机发现（2026-11-12）：二级 bootloader 交接时 RTC WDT 仍在跑，
        \\        # 裸机应用不喂狗，约 9 s 后复位成 CHIP_LP_WDT_RESET：
        \\        #   rst:0x10 (CHIP_LP_WDT_RESET),boot:0x58 (SPI_FAST_FLASH_BOOT)
        \\        # IDF 应用在 cpu_start 里关它，这里自己关；后续章节用到 WDT 再打开。
        \\        # RTC_WDT 基址 0x20801000：WPROTECT(+0x18, 键 0x50D83AA1)、
        \\        # FEED(+0x14, bit31)、CONFIG0(+0x0, EN bit31 / STG0[30:28])。
        \\        li      t0, 0x20801018
        \\        li      t1, 0x50D83AA1
        \\        sw      t1, 0(t0)
        \\        li      t0, 0x20801014
        \\        li      t1, 0x80000000
        \\        sw      t1, 0(t0)
        \\        li      t0, 0x20801000
        \\        lw      t1, 0(t0)
        \\        li      t2, 0x8FFFFFFF       # 清 EN(31) 与 STG0(30:28)
        \\        and     t1, t1, t2
        \\        sw      t1, 0(t0)
        \\        li      t0, 0x20801018
        \\        sw      zero, 0(t0)          # 恢复写保护
        \\
        \\        # ---- 3) 清零 .bss ----
        \\        la      t0, _bss_start
        \\        la      t1, _bss_end
        \\        bgeu    t0, t1, 2f
        \\1:
        \\        sw      zero, 0(t0)
        \\        addi    t0, t0, 4
        \\        bltu    t0, t1, 1b
        \\2:
        \\
        \\        # ---- 4) 安装 trap 向量 ----
        \\        # 直接模式（低 2 位 = 0）：所有异常都跳到 trapEntry。
        \\        # 必须在任何 ecall 之前完成；链接脚本已保证 4 字节对齐。
        \\        la      t0, trapEntry
        \\        csrw    mtvec, t0
        \\
        \\        # ---- 5) 进入应用 ----
        \\        call    main
        \\
        \\        # main 声明为 noreturn；万一返回就停在这里等中断。
        \\3:
        \\        wfi
        \\        j       3b
    );
}
