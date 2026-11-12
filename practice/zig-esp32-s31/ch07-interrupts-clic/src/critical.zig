//! ch07-interrupts-clic：临界区（保存/恢复中断状态）。
//!
//! 裸机上的“关中断”有三种写法，代价与用途完全不同：
//!
//!   1. `csrci mstatus, 8` 直接关、再 `csrsi mstatus, 8` 直接开。
//!      最短，但**不可嵌套**：内层退出时会把外层“本来关着”的中断打开，
//!      于是外层以为自己还处在临界区，实际已经被打断。
//!   2. 保存 `mstatus` 再原样写回（本文件的 `enter`/`exit`）。
//!      多一次 CSR 读和一次 CSR 写，换来可嵌套与“恢复到调用前的状态”，
//!      这是本章采用的方案，也是所有 RTOS 端口的标准做法。
//!   3. CLIC 的阈值（`enterLevel`/`exitLevel`）。
//!      不开/关 `MIE`，而是把“优先级 ≤ 阈值”的中断屏蔽掉，于是**高优先级
//!      中断仍然能打断临界区**。这是 CLIC 相对“一把关掉”的结构性优势，
//!      也是中断嵌套的入口；本章只提供原语并在 `c` 命令里演示阈值，
//!      真正的嵌套调度留到 RTOS 章节。
//!
//! 事实来源（IDF v6.1）：
//!   - `mstatus.MIE` 是 bit 3（RISC-V 特权级规范，第六章已用过 `csrci mstatus, 8`）；
//!   - `components/soc/esp32s31/include/soc/clic_reg.h`：`CLIC_INT_THRESH_REG`
//!     （基址 0x10800000 + 0x8）的阈值在 [31:24]；
//!   - `components/riscv/include/riscv/csr_clic.h`：`CLIC_INT_THRESH(level)` 的编码
//!     `(level << (8-NLBITS)) | ((1 << (8-NLBITS)) - 1)`，NLBITS=3；
//!   - `components/riscv/include/esp_private/interrupt_clic.h`：
//!     写阈值后需要读一次寄存器（或 ~8 条 nop）新阈值才生效。
//!
//! 「待真机验证」：阈值的实际屏蔽边界（是否包含等于）按 IDF 注释“mask all
//! interrupts between 0 and restoreval”实现，需要上板用计数确认。

const clic = @import("clic.zig");

const mstatus_mie: u32 = 1 << 3;

/// `CLIC_INT_THRESH_REG` 的地址：CLIC 基址 + 0x8。
const reg_thresh: usize = 0x1080_0008;

inline fn threshReg() *volatile u32 {
    return @ptrFromInt(reg_thresh);
}

/// 读 `mstatus` 原值。
pub fn mstatus() u32 {
    return asm volatile ("csrr %[d], mstatus"
        : [d] "=r" (-> u32),
    );
}

/// 当前是否允许中断（`mstatus.MIE`）。
pub fn enabled() bool {
    return (mstatus() & mstatus_mie) != 0;
}

/// 进临界区：返回进入前的 `mstatus`，并关掉 `MIE`。
///
/// 返回值必须原样交给 `exit()`；丢掉它、或者跨函数传递后忘记恢复，
/// 症状是“某段代码之后所有中断都不来了”——比崩溃更难查。
pub fn enter() u32 {
    const old = mstatus();
    asm volatile ("csrci mstatus, 8");
    return old;
}

/// 出临界区：把 `mstatus` 整体写回。
///
/// 为什么不是“无条件打开 MIE”：`enter()` 可能是在已经关中断的上下文里被调用的
/// （嵌套），无条件打开会破坏外层假设。整体写回同时还恢复了 MPIE/MPP 等位，
/// 这些在异常返回路径上有意义。
pub fn exit(saved: u32) void {
    asm volatile ("csrw mstatus, %[v]"
        :
        : [v] "r" (saved),
    );
}

/// 无条件允许中断（只在初始化的最后一步用）。
pub fn enable() void {
    asm volatile ("csrsi mstatus, 8");
}

/// 无条件禁止中断（panic 路径、最后手段）。
pub fn disable() void {
    asm volatile ("csrci mstatus, 8");
}

// ---------------------------------------------------------------------------
// CLIC 阈值版临界区
// ---------------------------------------------------------------------------

/// 读原始阈值字节（不解码，保存/恢复时用它才不会丢低位）。
pub fn thresholdRaw() u8 {
    return @truncate(threshReg().* >> 24);
}

fn writeThresholdRaw(byte: u8) void {
    const p = threshReg();
    const v = p.*;
    p.* = (v & 0x00FF_FFFF) | (@as(u32, byte) << 24);
    // 写后必须读一次：IDF 的注释写明新阈值不会立刻被 CPU 看到。
    _ = p.*;
}

/// 抬高阈值到 `level`，返回旧的原始阈值字节。
///
/// 语义是“屏蔽优先级 ≤ level 的中断”。所以 `enterLevel(0)` 等于什么都不屏蔽，
/// `enterLevel(7)` 等于屏蔽全部（但 `MIE` 仍为 1，硬件上仍会采样）。
pub fn enterLevel(lvl: u3) u8 {
    const old = thresholdRaw();
    writeThresholdRaw(clic.encodeThreshold(lvl));
    return old;
}

/// 恢复阈值（原样写回，不解码）。
pub fn exitLevel(saved: u8) void {
    writeThresholdRaw(saved);
}

/// 当前阈值对应的级别。
pub fn level() u3 {
    return clic.decodeThreshold(thresholdRaw());
}

comptime {
    if (mstatus_mie != 8) @compileError("mstatus.MIE 是 bit 3");
}
