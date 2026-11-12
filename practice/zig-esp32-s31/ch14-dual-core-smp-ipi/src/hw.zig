//! ch14-dual-core-smp-ipi：寄存器、CSR 与内存屏障的一层薄封装。
//!
//! 本章所有“跨核可见性”问题最终都落到这里的三条指令上：
//!
//!   - `fence rw, rw`：把本核之前的普通读写与之后的普通读写隔开。
//!     用途：发布“队列已改好”之后再触发 IPI；取锁之后先看到别人的写。
//!   - `fence.i`     ：让本核的取指看到刚写进内存的指令字节。
//!     用途：本章不用（没有运行时生成代码），但 IPI handler 里如果要做
//!     patch/跳板就必须用它 —— 只对**本核**有效，别的核要各自 fence.i。
//!   - `fence rw, w`（`fenceRwW`）：只保证写对写。本章不用它，列出仅为
//!     说明“屏障的选择是模式问题，不是越多越好”。
//!
//! Zig 0.17 移除了 `@fence` 内建，所以这里全部用内联汇编。

/// 32 位 MMIO 寄存器视图。`volatile` 是必需的：否则编译器可以把
/// “写寄存器 → 读状态位”的循环优化成只读一次。
pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// 本核 hart id。S31 是双核，IDF 的 `rv_utils_get_core_id()` 就是读这一位
/// （components/riscv/include/riscv/rv_utils.h:91）。
pub inline fn hartId() u32 {
    return asm volatile ("csrr %[d], mhartid"
        : [d] "=r" (-> u32),
    );
}

pub inline fn fenceRwRw() void {
    asm volatile ("fence rw, rw" ::: .{});
}

pub inline fn fenceRwW() void {
    asm volatile ("fence rw, w" ::: .{});
}

pub inline fn fenceI() void {
    asm volatile ("fence.i" ::: .{});
}

/// 每核数据的锚点。`mscratch` 是 M 模式下唯一“每个 hart 一份、随便用”的
/// 一个 XLEN 寄存器：启动时写入 `&PerCpu`，之后 trap 入口与 switchRaw
/// 都靠它找“我是谁”。用它而不是全局变量的理由见 src/smp.zig 的注释。
pub inline fn mscratch() usize {
    return asm volatile ("csrr %[d], mscratch"
        : [d] "=r" (-> usize),
    );
}

pub inline fn setMscratch(v: usize) void {
    asm volatile ("csrw mscratch, %[v]"
        :
        : [v] "r" (v),
    );
}

/// 读 mstatus 并清 MIE，返回旧值（供嵌套恢复）。
pub inline fn irqSave() usize {
    const v = asm volatile ("csrr %[d], mstatus"
        : [d] "=r" (-> usize),
    );
    asm volatile ("csrci mstatus, 0x8");
    return v;
}

pub inline fn irqRestore(old: usize) void {
    asm volatile ("csrw mstatus, %[v]"
        :
        : [v] "r" (old),
    );
}

/// 打开 `mie.MEIE`（bit 11）。`_start` 里 `csrw mie, zero` 把整张表清空了；
/// CLIC 的输入 16..47 属“外部中断”类，只置 CLICINTIE 而不打开 MEIE 时
/// 中断不会投递（真机现象：配置打印完一片安静）。
/// `csrs` 的立即数只有 5 位，bit 11 必须走寄存器。
pub inline fn meieEnable() void {
    const bit: usize = 1 << 11;
    asm volatile ("csrs mie, %[v]"
        :
        : [v] "r" (bit),
    );
}

pub inline fn wfi() void {
    asm volatile ("wfi");
}

/// 纯整数忙等：`asm volatile ("nop")` 保证循环不会被优化掉，也不引入浮点。
pub fn burn(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        asm volatile ("nop");
    }
}
