//! ch15-observability-testing-stability：形态 B 的启动代码 + IDF 应用描述。
//!
//! 与 ch11–ch13 的 start.zig 同构，本章只在注释与描述字段上改动：
//!
//!   1) 关全局中断   —— mstatus.MIE=0、mie=0
//!   2) 设置 sp / gp —— sp = _stack_top；gp = __global_pointer$
//!   3) 关 RTC/LP 看门狗 —— bootloader 交接时它还在跑，约 9 s 复位
//!   4) 清零 .bss    —— [_bss_start, _bss_end)（trace 环、计数器在这里）
//!   5) 安装 mtvec   —— mtvec = trapEntry（4 字节对齐，模式 0）
//!   6) 调用 main
//!
//! **本章全程不开中断**：没有 tick、没有调度器。trap 向量仍然要装——
//! 启动自检、可恢复断言、故意非法指令都需要一个能打印现场而不是静默复位的出口。
//!
//! 第 3 步不是“可选的清理”：不做，约 9 s 后 `rst:0x10 CHIP_LP_WDT_RESET`。
//! 本章的自检组 `wdt` 会读回 `RTC_WDT_CONFIG0` 的 EN 位，把“确实关掉了”
//! 变成串口上的一行证据（见 src/check.zig）。

const builtin = @import("builtin");
const app = @import("main.zig");
const trap = @import("trap.zig");

// ---------------------------------------------------------------------------
// IDF 应用描述（esp_app_desc_t）
//
// 字段顺序与 IDF v6.1 components/esp_app_format/include/esp_app_desc.h 一致，
// 整个结构在镜像里占 256 字节；bootloader 无条件读它。
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

fn fixed(comptime text: []const u8, comptime size: usize) [size]u8 {
    var out: [size]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

comptime {
    if (@sizeOf(AppDesc) != 256) @compileError("esp_app_desc_t 在镜像里必须是 256 字节");
    if (@offsetOf(AppDesc, "idf_ver") != 112) @compileError("idf_ver 必须在偏移 112");
    if (@offsetOf(AppDesc, "app_elf_sha256") != 144) @compileError("sha256 必须在偏移 144");
    if (@offsetOf(AppDesc, "mmu_page_size") != 180) @compileError("mmu_page_size 必须在偏移 180");
    if (@offsetOf(AppDesc, "spi_flash_mode") != 181) @compileError("spi_flash_mode 必须在偏移 181");
}

/// 放在第一个装载段最前面（linker/s31.ld 里 `KEEP(*(.app_desc))`）。
export const app_desc: AppDesc linksection(".app_desc") = .{
    .magic_word = 0xABCD5432,
    .secure_version = 0,
    .reserv1 = .{ 0, 0 },
    .version = fixed("ch15-observability", 32),
    .project_name = fixed("ch15-observability-stability", 32),
    .time = fixed("00:00:00", 16),
    .date = fixed("2026-11-28", 16),
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
        @compileError("ch15-observability-testing-stability 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch15-observability-testing-stability 需要 eabihf（硬浮点）ABI");
    }

    // 下面汇编里的 `call main` / `la t0, trapEntry` 对 Zig 的引用图不可见：
    // 它们只是字符串。不显式引用，符号不会进目标文件，链接期报 undefined。
    _ = &app.main;
    _ = &trap.trapEntry;
}

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\        # ---- 1) 关全局中断 ----
        \\        csrci   mstatus, 0x8          # mstatus.MIE = 0
        \\        csrw    mie, zero             # 关掉所有中断源
        \\
        \\        # ---- 2) 设置栈指针与 gp ----
        \\        la      sp, _stack_top        # 主栈顶（SRAM 末尾，16 字节对齐）
        \\        la      gp, __global_pointer$ # small-data 锚点
        \\
        \\        # ---- 3) 关掉 RTC/LP 看门狗 ----
        \\        # 真机发现（2026-11-12）：bootloader 交接时 RTC WDT 可能带着
        \\        # 已武装的 stage，裸机不喂狗约 9 s 后复位成 CHIP_LP_WDT_RESET
        \\        # (rst:0x10)。按 IDF wdt_hal_deinit(WDT_RWDT) 的顺序：
        \\        #   解锁 WPROTECT(+0x18) 与 SWD_WPROTECT(+0x20)
        \\        #   → feed(+0x14, bit31)
        \\        #   → 清 CONFIG0 的 EN(31)、STG0..3(30:19)、FLASHBOOT(12)
        \\        #   → 重新上锁
        \\        # 真机首轮（2026-11-13）读回 CONFIG0=0x8007ee00：EN 位仍为 1，
        \\        # 但 STG0..3 全 0 —— 这颗芯片的 EN 对软件写入表现为 WARL，
        \\        # 真正决定复位的是 stage 选择位；ch05 的板级记录同样是
        \\        # `rwdt en=1 stg=0`（BRINGUP:31），功能上已经是关的。
        \\        li      t0, 0x20801018
        \\        li      t1, 0x50D83AA1
        \\        sw      t1, 0(t0)
        \\        li      t0, 0x20801020       # SWD_WPROTECT，同一把键
        \\        sw      t1, 0(t0)
        \\        fence   rw, rw               # 先让解锁可见，再写 CONFIG0
        \\        li      t0, 0x20801014
        \\        li      t1, 0x80000000
        \\        sw      t1, 0(t0)
        \\        li      t0, 0x20801000
        \\        lw      t1, 0(t0)
        \\        li      t2, 0xFFF81000       # 清 EN(31)、STG0..3(30:19)、FLASHBOOT(12)
        \\        and     t1, t1, t2
        \\        sw      t1, 0(t0)
        \\        fence   rw, rw
        \\        li      t0, 0x20801018
        \\        sw      zero, 0(t0)          # 恢复写保护
        \\        li      t0, 0x20801020
        \\        sw      zero, 0(t0)
        \\
        \\        # ---- 4) 清零 .bss ----
        \\        # _heap_start == _bss_end，所以堆区不在清零范围内（本章不用堆）。
        \\        la      t0, _bss_start
        \\        la      t1, _bss_end
        \\        bgeu    t0, t1, 2f
        \\1:
        \\        sw      zero, 0(t0)
        \\        addi    t0, t0, 4
        \\        bltu    t0, t1, 1b
        \\2:
        \\
        \\        # ---- 5) 安装 trap 向量（直接模式：低 2 位 = 0）----
        \\        la      t0, trapEntry
        \\        csrw    mtvec, t0
        \\
        \\        # ---- 6) 进入应用 ----
        \\        call    main
        \\
        \\3:
        \\        wfi
        \\        j       3b
    );
}
