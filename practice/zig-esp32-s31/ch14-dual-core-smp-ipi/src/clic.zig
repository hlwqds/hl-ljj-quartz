//! ch14-dual-core-smp-ipi：每核 CLIC 的配置与 IPI 路由。
//!
//! S31 的中断控制是 **CLIC**（`SOC_INT_CLIC_SUPPORTED=1`），而且 CLIC 的
//! 寄存器组是**每核一份**：
//!
//!   IDF_PATH/components/soc/esp32s31/include/soc/interrupt_reg.h:14
//!     "The memory map for interrupt registers is on a per-core basis,
//!      CLIC_INT_THRESH_REG points to the current core interrupt register,
//!      whereas CLIC_INT_THRESH_REG + DUALCORE_CLIC_CTRL_OFF points to the
//!      other core registers, regardless of the core we are currently running on."
//!
//! `DUALCORE_CLIC_CTRL_OFF = 0x10000`（clic_reg.h:15）。所以：
//!
//!   0x1080_0000 + 4*i   →  **本核** 输入 i 的控制字（IP/IE/ATTR/CTL）
//!   0x1090_0000 + 4*i   →  **另一核** 输入 i 的控制字
//!
//! 这个别名关系是本章跨核 IPI 的硬件基础：core0 直接写 0x1090_1000+4*20
//! 就能置起 core1 的输入 20。但本章**没有**用“直接写对方的 IP”这条捷径，
//! 而是用 IDF 自己也在用的路由链路：
//!
//!   HP_SYSTEM_CPU_INT_FROM_CPU_n（0x20586000+0x10/+0x14）
//!     → 源 65/66（ETS_CPU_INTR_FROM_CPU_0/1_SOURCE）
//!     → 目标核的中断矩阵 INTERRUPT_COREn[源]（MAP[5:0] = CLIC 输入号）
//!     → 目标核 CLIC 输入 19（core0）/ 20（core1）
//!
//! 理由：源是可清、可屏蔽、有确定 pending 语义的寄存器（`crosscore_int_ll.h`
//! 的 trigger/clear 就是写这两只寄存器），而直接写另一个核的 CLICIP 要求
//! 该输入在 ATTR 里不被外设驱动、且清 pending 的责任全在软件。本章把前者
//! 作为主线，把后者写在正文里当作对照。
//!
//! 控制字布局（clic_reg.h）：
//!   byte0 IP   → bit0（写 1 置 pending、写 0 清 pending）
//!   byte1 IE   → bit8
//!   byte2 ATTR → SHV bit16、TRIG[2:1]
//!   byte3 CTL  → 优先级 bits[31:29]（NLBITS=3，8 级）
//!
//! ## 阈值：S31 走 CSR，不走内存映射
//!
//! `soc/esp32s31/include/soc/interrupt_reg.h:28` 定义了 `INTTHRESH_STANDARD 1`，
//! 也就是这颗芯片的阈值是**标准 CLIC CSR** `mintthresh`(0x347)
//! （components/riscv/include/riscv/csr_clic.h:42）。IDF 的
//! `rv_utils_restore_intlevel_regval()`（esp_private/interrupt_clic.h:131）
//! 在 `INTTHRESH_STANDARD=1` 时只写 CSR，只有 =0 时才写
//! `CLIC_INT_THRESH_REG`（0x1080_0008）并补一次回读。
//!
//! 编码（csr_clic.h:87，NLBITS=3）：`(level << 5) | 0x1F`，
//! 所以“放行全部”= level 0 → `0x1F`。语义是**包含**的：
//! 优先级 ≤ 阈值的中断被屏蔽，因此 0x1F 只挡住 0 级。
//!
//! 这条是本章的硬结论之一：只写 0x1080_0008 在 S31 上属于“写错了寄存器”，
//! 现象是中断源配置齐全却完全不投递（ch07 的 tick 计数为 0、软件中断不触发
//! 很可能就是这个原因，**待真机复核**）。下面的 `setThreshold_legacy_mmio`
//! 保留旧写法只作对照，本工程不调用。

const hw = @import("hw.zig");

/// 本核 CLIC 的基址（别名，两个核都用这个常量指向自己）。
pub const current_base: usize = 0x1080_0000;

/// 另一核的偏移（DUALCORE_CLIC_CTRL_OFF）。
pub const peer_offset: usize = 0x10000;

/// 外部中断的起点：通道号 + 16（CLIC_EXT_INTR_NUM_OFFSET）。
pub const ext_offset: u6 = 16;

/// tick 用输入 16（两个核都用 16，但路由到各自的矩阵）。
pub const tick_input: u6 = 16;

/// IPI：core0 收 19，core1 收 20。
pub const ipi_input_core0: u6 = 19;
pub const ipi_input_core1: u6 = 20;

/// CLIC 优先级（0..7，越大越优先）。IPI 高于 tick：
/// 唤醒延迟不该被 1 ms 的 tick 排队。
pub const prio_tick: u3 = 3;
pub const prio_ipi: u3 = 5;

pub fn ipiInput(core: u32) u6 {
    return if (core == 0) ipi_input_core0 else ipi_input_core1;
}

/// 本核输入 i 的控制字。
pub fn ctrl(id: u6) *volatile u32 {
    return hw.reg(current_base + 0x1000 + @as(usize, id) * 4);
}

/// 指定基址（本核=current_base，对核=current_base+peer_offset）的输入 i。
pub fn ctrlAt(base: usize, id: u6) *volatile u32 {
    return hw.reg(base + 0x1000 + @as(usize, id) * 4);
}

/// 只改优先级，保留 IP/IE/ATTR 的其它位。
pub fn setPriority(id: u6, level: u3) void {
    const p = ctrl(id);
    const v = p.*;
    p.* = (v & 0x1FFF_FFFF) | (@as(u32, level) << 29);
}

pub fn enableInput(id: u6) void {
    const p = ctrl(id);
    p.* = p.* | (@as(u32, 1) << 8);
}

pub fn disableInput(id: u6) void {
    const p = ctrl(id);
    p.* = p.* & ~(@as(u32, 1) << 8);
}

pub fn clearPending(id: u6) void {
    const p = ctrl(id);
    p.* = p.* & ~(@as(u32, 1));
}

pub fn setPending(id: u6) void {
    const p = ctrl(id);
    p.* = p.* | @as(u32, 1);
}

/// 标准 CLIC 的阈值 CSR（S31：INTTHRESH_STANDARD = 1）。
pub const mintthresh_csr: u12 = 0x347;

/// 绝对电平 → mintthresh 字段（NLBITS=3 时 `(level<<5)|0x1F`）。
pub fn thresholdBits(level: u3) u32 {
    return (@as(u32, level) << 5) | 0x1F;
}

/// 设置本核阈值：优先级 ≤ level 的输入被屏蔽。0 → 只挡 0 级，等于放行。
///
/// 这是 S31 的正确路径（CSR），不是内存映射。
pub fn setThreshold(level: u3) void {
    const bits = thresholdBits(level);
    asm volatile ("csrw 0x347, %[v]"
        :
        : [v] "r" (bits),
    );
}

pub fn getThreshold() u32 {
    return asm volatile ("csrr %[d], 0x347"
        : [d] "=r" (-> u32),
    );
}

/// 对照用的旧写法：写 0x1080_0008 的 byte3。
/// 只在 `INTTHRESH_STANDARD=0` 的芯片（C6 等）上是正确路径；
/// S31 上它不生效 —— 本工程不调用，保留它是为了让正文的对比可编译。
pub fn setThreshold_legacy_mmio(level: u3) void {
    const p = hw.reg(current_base + 0x8);
    const byte: u32 = (@as(u32, level) << 5) | 0x1F;
    p.* = (p.* & 0x00FF_FFFF) | (byte << 24);
    _ = p.*; // 写后读一次，让新阈值生效（非标准 CLIC 的要求）
}

/// 每核的中断矩阵基址：core0 = 0x20585000，core1 = +0x800
/// （reg_base.h:77/137/138）。
pub const matrix_base: [2]usize = .{ 0x2058_5000, 0x2058_5800 };

/// 源编号（interrupts.h 的枚举值，按声明顺序数出来）。
pub const source_timg0_t0: usize = 25;
pub const source_timg0_t1: usize = 26;
pub const source_from_cpu_0: usize = 65;
pub const source_from_cpu_1: usize = 66;

/// 把某个源路由到**该核自己的**某个 CLIC 输入。
/// 必须由目标核自己调用（矩阵寄存器也按核分开）。
pub fn route(core: u32, source: usize, input: u6) void {
    const map = hw.reg(matrix_base[core] + source * 4);
    // [5:0] = 输入号；[9:8] = PASS_LEVEL（中断重映射），保留原值。
    map.* = (map.* & 0x300) | @as(u32, input);
}

/// 本核的 IPI 输入：优先级、使能、清残留 pending。
pub fn setupIpiInput(core: u32) void {
    const id = ipiInput(core);
    setPriority(id, prio_ipi);
    enableInput(id);
    clearPending(id);
}

/// 本核的 tick 输入。
pub fn setupTickInput() void {
    setPriority(tick_input, prio_tick);
    enableInput(tick_input);
    clearPending(tick_input);
}
