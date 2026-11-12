//! ch13-heap-stack-caps：内存"能力"（caps）登记表与地址归类。
//!
//! ESP-IDF 的 `heap_caps_malloc(size, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL)`
//! 不是一个 API 糖：它是**内存不能互换**这件事的显式化。S31 上至少有五个
//! 独立的地址空间，同一个指针落在哪个区间决定了它能做什么：
//!
//!   | 区间                  | 能跑代码 | 8/16 位访问 | DMA | 掉电保持 |
//!   | --------------------- | -------- | ----------- | --- | -------- |
//!   | SRAM 0x2F000000       | 是       | 是          | 是  | 否       |
//!   | LP SRAM 0x2E000000    | 是       | 是          | ？  | 是       |
//!   | ROM 0x2F800000        | 是       | 否（只读）  | 否  | —        |
//!   | Flash cache 0x40000000| 是       | 是          | 否  | —        |
//!   | PSRAM cache 0x50000000| 是       | 是          | 是  | 否       |
//!
//! "DMA 能用"这一列不是物理属性，而是**总线可达性**：内部 SRAM 与 PSRAM
//! 都在 AHB/AXI 上，能被 GDMA 直接寻址；被 cache 映射的 flash 不行。
//! "能跑代码"同理：SRAM 与 PSRAM（cache 映射后可执行）能取指，flash 的
//! 数据窗口（DROM）不能。
//!
//! 本文件只做两件事：用一张常量表描述这些区间，以及把任意地址归类。
//! 分配器（heap.zig）用它在分配时检查"这个 caps 有没有对应的 arena"，
//! 诊断输出用它解释"这个指针到底在哪个空间"。

const std = @import("std");

/// 与 `esp_heap_caps.h` 的 `MALLOC_CAP_*` 同名的能力集合（只保留本章用到的）。
///
/// 用 `packed struct` 而不是位掩码：调用点写 `.{ .dma = true, .internal = true }`
/// 比 `MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL` 更难写错，而且编译期就能挡住
/// 拼错的字段名。代价是不能直接与 IDF 的整型掩膜互换——真要与 C 侧对接时
/// 在边界上加一个 `toMask()`。
pub const Caps = packed struct {
    /// 可以取指。
    exec: bool = false,
    /// 支持 8/16 位访问（不只是 32 位对齐访问）。
    bit8: bool = false,
    /// 支持非对齐 32 位访问。
    bit32: bool = false,
    /// 可被 GDMA 直接寻址（不需要 bounce buffer）。
    dma: bool = false,
    /// 内部存储（关掉 flash/PSRAM cache 后仍在）。
    internal: bool = false,
    /// 在 PSRAM 里。
    psram: bool = false,
    /// 深睡后可保持（LP SRAM）。
    retention: bool = false,
};

/// 区间标识。用枚举而不是比较字符串：字符串字面量的地址去重不可靠。
pub const RegionId = enum { sram, lp_sram, rom, flash_cache, psram_cache, mmio };

pub const Region = struct {
    id: RegionId,
    name: []const u8,
    base: usize,
    len: usize,
    caps: Caps,
    /// 一句来源/边界说明，打印预算表时用。
    note: []const u8,
};

/// S31 的五个地址空间。数字全部来自 IDF v6.1 的 esp32s31 头文件，
/// 见本章「事实来源」表。
pub const regions = [_]Region{
    .{
        .id = .sram,
        .name = "sram",
        .base = 0x2F00_0000,
        .len = 0x0008_0000, // 物理 512 KiB
        .caps = .{ .exec = true, .bit8 = true, .bit32 = true, .dma = true, .internal = true },
        .note = "物理 512K；应用可用到 0x2F07AFC0，末尾 0x5040 归 bootloader 的 iram_loader_seg",
    },
    .{
        .id = .lp_sram,
        .name = "lp_sram",
        .base = 0x2E00_0000,
        .len = 0x0000_8000,
        .caps = .{ .exec = true, .bit8 = true, .bit32 = true, .internal = true, .retention = true },
        .note = "LP/统一 32K；深睡保持；本章不使用（DMA 能力未核）",
    },
    .{
        .id = .rom,
        .name = "rom",
        .base = 0x2F80_0000,
        .len = 0x0005_0000,
        .caps = .{ .exec = true, .bit32 = true },
        .note = "掩膜 ROM 320K；只读；esp_rom_printf 在 0x2F800024",
    },
    .{
        .id = .flash_cache,
        .name = "flash_cache",
        .base = 0x4000_0000,
        .len = 0x0400_0000,
        .caps = .{ .exec = true, .bit8 = true, .bit32 = true },
        .note = "MMU 线性窗口 64 MiB（1024 × 64 KiB 页）；本工程 .flash.text 0x40000020 / .flash.rodata 0x40020020",
    },
    .{
        .id = .psram_cache,
        .name = "psram_cache",
        .base = 0x5000_0000,
        .len = 0x0400_0000,
        .caps = .{ .bit8 = true, .bit32 = true, .dma = true, .psram = true },
        .note = "MMU 线性窗口 64 MiB；模组 16 MiB PSRAM；需先初始化 PSRAM 并建映射",
    },
    .{
        .id = .mmio,
        .name = "mmio",
        .base = 0x2000_0000,
        .len = 0x0E00_0000,
        .caps = .{},
        .note = "外设寄存器区（CLIC/矩阵/TIMG/SPI-MEM/bus_monitor 都在这里）；不可分配",
    },
};

/// 地址归类。区间互不重叠，顺序扫表即可（6 项，比二分更可读）。
pub fn regionOf(addr: usize) ?*const Region {
    for (&regions) |*r| {
        if (addr >= r.base and addr - r.base < r.len) return r;
    }
    return null;
}

pub fn nameOf(addr: usize) []const u8 {
    return if (regionOf(addr)) |r| r.name else "unmapped";
}

/// 找一个满足全部要求的能力区间。分配器用它决定"能不能做"。
pub fn find(want: Caps) ?*const Region {
    for (&regions) |*r| {
        if (satisfies(r.caps, want)) return r;
    }
    return null;
}

/// `have` 是否满足 `want`：want 里为 true 的位，have 必须也为 true。
fn satisfies(have: Caps, want: Caps) bool {
    if (want.exec and !have.exec) return false;
    if (want.bit8 and !have.bit8) return false;
    if (want.bit32 and !have.bit32) return false;
    if (want.dma and !have.dma) return false;
    if (want.internal and !have.internal) return false;
    if (want.psram and !have.psram) return false;
    if (want.retention and !have.retention) return false;
    return true;
}

/// 把 caps 打成 7 个字符的短标记（打印用）。顺序固定，缺省用 '-':
///   e=exec 8=bit8 3=bit32 d=dma i=internal p=psram r=retention
pub fn tag(caps: Caps) [7]u8 {
    return .{
        if (caps.exec) 'e' else '-',
        if (caps.bit8) '8' else '-',
        if (caps.bit32) '3' else '-',
        if (caps.dma) 'd' else '-',
        if (caps.internal) 'i' else '-',
        if (caps.psram) 'p' else '-',
        if (caps.retention) 'r' else '-',
    };
}

comptime {
    // 区间必须互不重叠，否则 classify 的结果依赖扫表顺序——那是隐患不是特性。
    for (regions, 0..) |a, i| {
        for (regions, 0..) |b, j| {
            if (i >= j) continue;
            const overlap = a.base < b.base + b.len and b.base < a.base + a.len;
            if (overlap) @compileError("caps 区间重叠: " ++ a.name ++ " / " ++ b.name);
        }
    }
    // ROM 不在应用可用的 SRAM 区间里（0x2F800000 > 0x2F080000）。
    if (regions[2].base < regions[0].base + regions[0].len) {
        @compileError("rom 区间必须落在 sram 之外");
    }
}

// 区间归类自测（`zig test src/caps.zig`）。
test "地址归类" {
    const t = std.testing;
    try t.expect(std.mem.eql(u8, nameOf(0x2F00_0000), "sram"));
    try t.expect(std.mem.eql(u8, nameOf(0x2F07_AFC0), "sram"));
    // 0x2F07AFC0 之上仍属于物理 SRAM（bootloader 的 iram_loader_seg 占着），
    // caps 表按物理空间归类；"应用能用多少"由链接脚本的 _heap_end 决定。
    try t.expect(std.mem.eql(u8, nameOf(0x2F07_AFC1), "sram"));
    try t.expect(std.mem.eql(u8, nameOf(0x2F08_0000), "unmapped"));
    try t.expect(std.mem.eql(u8, nameOf(0x2F80_0024), "rom"));
    try t.expect(std.mem.eql(u8, nameOf(0x4000_0020), "flash_cache"));
    try t.expect(std.mem.eql(u8, nameOf(0x5000_0000), "psram_cache"));
    try t.expect(std.mem.eql(u8, nameOf(0x2E00_0000), "lp_sram"));
    try t.expect(std.mem.eql(u8, nameOf(0x2050_2000), "mmio"));

    // 能力查询：只有 SRAM 同时满足 exec + bit8 + dma
    const r = find(.{ .exec = true, .bit8 = true, .dma = true, .internal = true }) orelse unreachable;
    try t.expect(std.mem.eql(u8, r.name, "sram"));
    // 要 PSRAM 就必须落到 psram 区间，SRAM 不能满足
    const p = find(.{ .bit8 = true, .psram = true }) orelse unreachable;
    try t.expect(std.mem.eql(u8, p.name, "psram_cache"));
    // 要 retention + exec
    const l = find(.{ .exec = true, .retention = true }) orelse unreachable;
    try t.expect(std.mem.eql(u8, l.name, "lp_sram"));
}
