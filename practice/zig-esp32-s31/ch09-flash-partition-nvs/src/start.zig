//! ch09-flash-partition-nvs：形态 B 的启动代码 + IDF 应用描述。
//!
//! 与 ch04/ch06 的 start.zig 结构一致，只有应用描述里的版本字符串与注释变化：
//! 本章的“新东西”全在 main.zig 拉进来的模块里（flash/partition/kv），
//! 启动顺序刻意不动。
//!
//! 二级 bootloader 按镜像头的 entry 字段跳到 `_start`，这里是应用的第一条指令。
//! 函数是 naked 的：编译器不生成序言/收尾，栈与寄存器完全由汇编接管。
//!
//! `_start` 的五步固定顺序：
//!   1) 关全局中断   —— mstatus.MIE=0、mie=0
//!   2) 设置 sp / gp —— sp = _stack_top；gp = __global_pointer$
//!   3) 清零 .bss    —— [_bss_start, _bss_end)
//!   4) 搬运 .data   —— 本布局 LMA == VMA，无搬运
//!   5) 调用 main    —— call main；返回后进 wfi 死循环
//!
//! 本章不打开中断：flash 的读/写/擦都是同步轮询，临界窗口只是短暂
//! 清掉 mstatus.MIE 再恢复。中断的安装需要 mtvec 的 CLIC 模式、中断矩阵
//! 路由与 mie/mstatus，这些是 ch07 的主题；把它们混进“写 flash 失败”
//! 这类故障里，会分不清是 cache 窗口的问题还是 ISR 的问题。
//! 所以这里的 `_start` 与 ch06 逐字相同：先把“ROM 例程能按偏移读写”
//! 证明清楚。

const builtin = @import("builtin");
const app = @import("main.zig");

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
/// `export` 保证它一定被发射，`linksection` 保证它落在 `.app_desc` 里。
export const app_desc: AppDesc linksection(".app_desc") = .{
    .magic_word = 0xABCD5432,
    .secure_version = 0,
    .reserv1 = .{ 0, 0 },
    .version = fixed("ch09-flash-partition-nvs", 32),
    .project_name = fixed("ch09-flash-partition-nvs", 32),
    .time = fixed("00:00:00", 16),
    .date = fixed("2026-11-18", 16),
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
        @compileError("ch09-flash-partition-nvs 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch09-flash-partition-nvs 需要 eabihf（硬浮点）ABI");
    }

    // 下面汇编里的 `call main` 对 Zig 的引用图是不可见的：它只是一个字符串。
    // 不显式引用，main.zig 就不会被分析，符号 `main` 也不会出现在目标文件里，
    // 链接期表现为 `undefined symbol: main`。
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
        \\        # 所以没有搬运。flash 布局时换成从 _data_load_start 到 _data_start
        \\        # 的逐字拷贝。
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
