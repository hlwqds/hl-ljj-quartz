//! ch13-heap-stack-caps：PSRAM 映射窗口与（只读）MMU 探针。
//!
//! S31 的 PSRAM 不在 CPU 的物理地址空间里，而在 **MMU 线性窗口**后面：
//!
//!   虚拟 0x5000_0000 .. 0x5400_0000   ← 64 MiB 线性窗口（1024 项 × 64 KiB 页）
//!      │ 每一项把一页映射到 PSRAM 的某个物理页
//!      └→ 物理 PSRAM：模组 16 MiB
//!
//! 关键事实：**窗口存在 ≠ 能访问**。MMU 表项没建、或者 PSRAM 控制器没初始化，
//! 读 0x50000000 会进异常（load/store access fault），而不是读到随机值。
//!
//! 本章的 bootloader（ch03 起一路用的 `idf-bootstrap`）**没有**开启
//! `CONFIG_SPIRAM`，因此 PSRAM 大概率没有初始化、MMU 表项为空。所以本文件：
//!
//!   1. 只**读** PSRAM 侧 MMU 的页大小与表项有效位（纯 MMIO 读，安全）；
//!   2. 只有确认"至少一页有效"之后，才对窗口做读写校验；
//!   3. 否则明确打印 `mapped=no` 并说明原因——绝不假装读写成功。
//!
//! 寄存器（IDF v6.1, components/soc/esp32s31/register/soc/spi_mem_s_reg.h）：
//!   SPI_MEM_S_MMU_ITEM_CONTENT_REG  = DR_REG_PSRAM_MSPI0_BASE + 0x37C
//!   SPI_MEM_S_MMU_ITEM_INDEX_REG    = DR_REG_PSRAM_MSPI0_BASE + 0x380
//!   SPI_MEM_S_MMU_POWER_CTRL_REG    = DR_REG_PSRAM_MSPI0_BASE + 0x384
//!   DR_REG_PSRAM_MSPI0_BASE         = 0x20502000
//! 页大小字段 `SPI_MMU_PAGE_SIZE[4:3]`：PSRAM 侧 0=64K / 1=32K / 2=16K / 3=8K；
//! 表项有效位 = BIT(11)（`SOC_MMU_PSRAM_VALID`）。

const log = @import("log.zig");

/// PSRAM 侧的 MMU（SPI_MEM_S / PSRAM_MSPI0）。
const mmu_base: usize = 0x2050_2000;
const reg_item_content: usize = mmu_base + 0x37C;
const reg_item_index: usize = mmu_base + 0x380;
const reg_power_ctrl: usize = mmu_base + 0x384;

/// 线性窗口与表项数（SOC_MMU_ENTRY_NUM = 1024，页 64 KiB → 64 MiB）。
pub const window_base: usize = 0x5000_0000;
pub const window_len: usize = 0x0400_0000;
pub const entry_count: usize = 1024;

/// 模组上的物理容量（N16R16V：16 MiB）。
pub const chip_bytes: usize = 16 * 1024 * 1024;

const valid_bit: u32 = 1 << 11;

fn rd(addr: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(addr)).*;
}

fn wr(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

/// 读第 i 项 MMU 表项（先写索引，再读内容）。
fn readEntry(i: usize) u32 {
    wr(reg_item_index, @intCast(i));
    return rd(reg_item_content);
}

/// 页大小（字节）。字段编码见文件头。
fn pageBytes() usize {
    const code = (rd(reg_power_ctrl) >> 3) & 0x3;
    return switch (code) {
        0 => 64 * 1024,
        1 => 32 * 1024,
        2 => 16 * 1024,
        else => 8 * 1024,
    };
}

/// 统计有效表项数。
fn countValid() usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        if (readEntry(i) & valid_bit != 0) n += 1;
    }
    return n;
}

/// 只有确认映射存在才走的读写校验：写 4 个字、读回比对。
fn rwCheck() bool {
    const addrs = [_]usize{ window_base, window_base + 0x1000, window_base + 0x8000, window_base + 0x3FFF0 };
    for (addrs, 0..) |a, i| {
        const v: u32 = 0x5A5A_0000 | @as(u32, @intCast(i));
        wr(a, v);
    }
    for (addrs, 0..) |a, i| {
        const want: u32 = 0x5A5A_0000 | @as(u32, @intCast(i));
        if (rd(a) != want) return false;
    }
    return true;
}

/// 一行结论式的报告。
pub fn report() void {
    const page = pageBytes();
    const valid = countValid();
    log.line("psram: window=0x{x}..0x{x} entry={d} page={d}B chip={d}B", .{
        window_base, window_base + window_len, entry_count, page, chip_bytes,
    });
    log.line("psram: mmu_valid_entries={d}/{d} mapped={s}", .{
        valid, entry_count, if (valid > 0) "yes" else "no",
    });
    if (valid == 0) {
        // 这是本章的**预期**分支：bootloader 没开 CONFIG_SPIRAM。
        log.raw("psram: no mapping programmed by bootloader -> skip rw (initialise PSRAM first)\n");
        return;
    }
    const ok = rwCheck();
    log.line("psram: rw_probe={s} (4 words over first {d} KiB)", .{
        if (ok) "ok" else "FAIL", page / 1024,
    });
}
