//! ch05-clock-reset-wdt：形态 B 的启动代码 + IDF 应用描述（沿用 ch04）。
//!
//! 二级 bootloader 按镜像头的 entry 字段跳到 `_start`，这里是应用的第一条指令。
//! 函数是 naked 的：编译器不生成序言/收尾，栈与寄存器完全由汇编接管。
//!
//! 文件里有两块东西，顺序即布局顺序：
//!   - `app_desc`：256 字节的 esp_app_desc_t，必须位于第一个装载段的最前面；
//!   - `_start`：五步启动代码。
//!
//! `_start` 的五步固定顺序（与 ch04 完全一致，本章不改启动顺序）：
//!   1) 关全局中断   —— mstatus.MIE=0、mie=0
//!   2) 设置 sp / gp —— sp = _stack_top；gp = __global_pointer$（small data 锚点）
//!   3) 清零 .bss    —— [_bss_start, _bss_end)
//!   4) 搬运 .data   —— 本布局 LMA == VMA，无搬运
//!   5) 调用 main    —— call main；返回后进 wfi 死循环
//!
//! 本章把“bootloader 已经把 CPU 推到目标频率”这件事当成**待测量的事实**：
//! `_start` 不写任何 PLL 寄存器，`main` 里用 mcycle 与 SYSTIMER 把实际频率量出来。
//! 复位原因在 `main` 里由 ROM 函数 `rtc_get_reset_reason` 读出；看门狗由
//! `src/wdt.zig` 显式喂/关，不依赖 bootloader 留下的状态。

const builtin = @import("builtin");
const app = @import("main.zig");

// ---------------------------------------------------------------------------
// IDF 应用描述（esp_app_desc_t）
//
// IDF 的二级 bootloader 即使加载的不是 IDF 构建出来的应用，也要求第一个装载段
// 以这份结构开头：
//   - 段处理路径（process_segment）在 SOC_MMU_PAGE_SIZE_CONFIGURABLE 时会读
//     魔数与 mmu_page_size 来决定映射页大小，读不到就报
//     "Failed to fetch app description header!"；
//   - bootloader_common_check_efuse_blk_validity 会读同一份描述里的
//     min/max_efuse_blk_rev_full 判断 eFuse 块版本是否兼容；
//   - process_esp_app_desc_data 里的魔数断言是另一条（防回滚）路径。
//
// 字段顺序与 IDF v6.1 的 components/esp_app_format/include/esp_app_desc.h
// 一致，整个结构在镜像里占 256 字节。
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
    /// IDF 结构体里这里是 reserv2[18]（18 个 u32，共 72 字节，偏移 184..256）。
    reserv2: [72]u8,
};

fn fixed(comptime text: []const u8, comptime size: usize) [size]u8 {
    var out = [_]u8{0} ** size;
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
/// app_elf_sha256 暂填零：本章不启用安全启动与回滚，真机验证时按需回填。
export const app_desc: AppDesc linksection(".app_desc") = .{
    .magic_word = 0xABCD5432,
    .secure_version = 0,
    .reserv1 = .{ 0, 0 },
    .version = fixed("ch05-clock-reset-wdt", 32),
    .project_name = fixed("ch05-clock-reset-wdt", 32),
    .time = fixed("00:00:00", 16),
    .date = fixed("2026-11-14", 16),
    .idf_ver = fixed("v6.1", 32),
    .app_elf_sha256 = [_]u8{0} ** 32,
    .min_efuse_blk_rev_full = 0,
    .max_efuse_blk_rev_full = 0,
    .mmu_page_size = 16, // log2(64 KiB)
    .spi_flash_mode = 2, // DIO
    .reserv3 = 0,
    .reserv2 = [_]u8{0} ** 72,
};

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch05-clock-reset-wdt 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch05-clock-reset-wdt 需要 eabihf（硬浮点）ABI");
    }

    // 下面汇编里的 `call main` 对 Zig 的引用图是不可见的：它只是一个字符串。
    // 不显式引用，main.zig 就不会被分析，链接期表现为 `undefined symbol: main`。
    _ = &app.main;
}

/// 应用入口。符号名由链接脚本的 ENTRY(_start) 指定，也是 elf2image 写进
/// 镜像头 entry 字段的地址。
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\        # ---- 1) 关全局中断 ----
        \\        csrci   mstatus, 0x8          # mstatus.MIE = 0
        \\        csrw    mie, zero             # 关掉所有中断源
        \\
        \\        # ---- 2) 设置栈指针与 gp ----
        \\        la      sp, _stack_top        # 向下增长；_stack_top 16 字节对齐
        \\        la      gp, __global_pointer$ # 链接器 relaxation 的 small-data 锚点
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
        \\        # ---- 4) 搬运 .data ----
        \\        # 本布局把 .data 也放在 SRAM，LOADADDR(.data) == _data_start，
        \\        # 所以没有搬运。
        \\
        \\        # ---- 5) 进入应用 ----
        \\        call    main
        \\
        \\        # main 不应返回；万一返回就停在这里等中断。
        \\3:
        \\        wfi
        \\        j       3b
    );
}
