//! ch07-interrupts-clic：CLIC（每核 48 输入 / 8 优先级）与中断矩阵的最小驱动。
//!
//! 这一层只做四件事，顺序也是本章推荐的初始化顺序：
//!   1. 把外设中断**源**路由到某个 CPU 通道（中断矩阵，`INTERRUPT_CORE0`）；
//!   2. 给对应的 CLIC 输入设**优先级**并打开它的 `IE` 位；
//!   3. 设**阈值**（0 = 什么都不屏蔽）；
//!   4. 装 `mtvec`（本章用 MODE=0 直接模式；MODE=3 的 CLIC 向量模式只给出入口）。
//!
//! 所有寄存器名、位域与地址都来自 ESP-IDF v6.1 的 `esp32s31` 头文件，逐条注明：
//!   - `components/soc/esp32s31/include/soc/clic_reg.h`
//!       DR_REG_CLIC_BASE      = 0x10800000   （CLIC 的控制/状态寄存器，内存映射）
//!       DR_REG_CLIC_CTRL_BASE = 0x10801000   （每个输入 4 字节：IP/IE/ATTR/CTL）
//!       CLIC_INT_CONFIG (+0x0)：NVBITS[0]、MNLBITS[4:1]、NMBITS[6:5]
//!       CLIC_INT_INFO   (+0x4)：NUM_INT[12:0]、VERSION[20:13]、CTLBITS[24:21]
//!       CLIC_INT_THRESH (+0x8)：阈值在 [31:24]
//!       CLIC_INT_CTRL(i) = CTRL_BASE + 4i：CTL[31:24] 优先级、IE bit8、IP bit0、
//!                                          SHV bit16、TRIG[18:17]、ATTR_MODE[23:22]
//!   - `components/riscv/include/riscv/csr_clic.h`
//!       MTVT_CSR = 0x307、MTVEC_MODE_CSR = 3、RV_EXTERNAL_INT_COUNT = 32、
//!       RV_EXTERNAL_INT_OFFSET = 16、NLBITS（S31 为 3）、
//!       CLIC_INT_THRESH(level) = (level << (8-NLBITS)) | ((1 << (8-NLBITS)) - 1)
//!   - `components/riscv/include/esp_private/interrupt_clic.h`
//!       rv_utils_set_mtvt() 写 0x307；非标准阈值的写后必须读一次寄存器让新阈值生效
//!   - `components/soc/esp32s31/register/soc/interrupt_core0_reg.h`
//!       每个源一个 32 位映射寄存器，`..._MAP`[5:0] = 目标中断号，
//!       `..._PASS_LEVEL`[9:8] = 0 关闭 remap、2/3 走 M 级
//!   - `components/hal/include/hal/interrupt_clic_ll.h`
//!       `interrupt_clic_ll_route()` 用 `REG_SET_BITS(..., intr_num, 63)` 写这 6 位，
//!       而 `components/riscv/interrupt_clic.c` 的 `intr_matrix_route()` 传进来的
//!       `intr_num` 已经加过 `RV_EXTERNAL_INT_OFFSET`：**寄存器里存的是 CLIC 输入号
//!       16..47，不是外部中断号 0..31**。这是本章最容易写错的一处，见 `route()`。
//!   - `components/soc/esp32s31/include/soc/interrupts.h`
//!       源编号枚举（本章只取用到的几个，见 `Source`）
//!   - `components/soc/esp32s31/include/soc/clic_reg.h` 的 CLIC_EXT_INTR_NUM_OFFSET = 16：
//!       CLIC 输入 16..47 与“外部中断号 0..31”一一对应，`channel + 16` 才是 CLIC 输入号。
//!
//! 「待真机验证」：本仓没有在 S31 上跑过这些写操作。CLIC 的 IE/优先级/阈值语义按
//! 上面的头文件与 CLIC 规范实现，但真正的仲裁、嵌套与 `mcause` 里的输入号必须上板
//! 用示波器和串口计数确认。MODE=3 的向量模式本章**不启用**（见 installVectored）。

// ---------------------------------------------------------------------------
// 地址与位域
// ---------------------------------------------------------------------------

/// CLIC 寄存器块（不是 CSR）：配置、信息、阈值。
const clic_base: usize = 0x1080_0000;
/// 每个 CLIC 输入 4 字节：+0 IP、+1 IE、+2 ATTR、+3 CTL。
const clic_ctrl_base: usize = 0x1080_1000;

const reg_config: usize = clic_base + 0x0;
const reg_info: usize = clic_base + 0x4;
const reg_thresh: usize = clic_base + 0x8;

/// CLIC_INT_CTRL(i) 的位域。
const bit_ip: u32 = 1 << 0;
const bit_shv: u32 = 1 << 16;
const bit_ie: u32 = 1 << 8;

/// CLIC 输入总数（INFO.NUM_INT 复位值 48）。用 u6 表达 0..47。
pub const Input = u6;
pub const input_max: Input = 47;

/// CLIC 输入 16..47 对应 CPU 外部中断号 0..31（`CLIC_EXT_INTR_NUM_OFFSET = 16`）。
pub const ext_int_offset: Input = 16;
/// 可路由的外部中断号数量（`RV_EXTERNAL_INT_COUNT = 32`）。
pub const ext_int_count: u6 = 32;

/// CLIC 的优先级位数（`csr_clic.h` 的 NLBITS）。8 级 = 0..7，用 u3 表达。
pub const nlbis: u3 = 3;
/// `8 - NLBITS`：优先级/阈值在字节里的左移量。写成常量而不是每次算，
/// 是因为 `8` 是 comptime_int、`nlbis` 是 u3，直接写 `8 - nlbis` 在 Zig 里
/// 会因为 8 装不进 u3 而编译失败。
pub const level_shift: u3 = 5;

comptime {
    if (@as(u4, level_shift) + @as(u4, nlbis) != 8) {
        @compileError("level_shift 必须等于 8 - nlbis");
    }
}

/// 一个优先级在 CTL 字节里的编码：左移到高 NLBITS 位。
/// 例：NLBITS=3 时 level=1 → 0b0010_0000。
pub fn encodeLevel(level: u3) u8 {
    return @as(u8, level) << level_shift;
}

/// 阈值编码：与优先级同一位置，低位补 1。
/// 例：level=0 → 0x1f，level=1 → 0x3f，level=7 → 0xff。
pub fn encodeThreshold(level: u3) u8 {
    return encodeLevel(level) | ((@as(u8, 1) << level_shift) - 1);
}

/// 从阈值字节反解优先级（`CLIC_THRESH_TO_INT`）。
pub fn decodeThreshold(byte: u8) u3 {
    return @truncate(byte >> level_shift);
}

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

inline fn ctrl(id: Input) *volatile u32 {
    return @ptrFromInt(clic_ctrl_base + @as(usize, id) * 4);
}

// ---------------------------------------------------------------------------
// 中断矩阵：源 → CPU 通道
// ---------------------------------------------------------------------------

/// `INTERRUPT_CORE0` 的基址（`reg_base.h` 的 `DR_REG_INTERRUPT_CORE0_BASE`）。
/// 同文件里 `DR_REG_INTERRUPT_CORE1_BASE = DR_REG_INTR0_BASE + 0x800`，
/// 所以第二核的矩阵就是“同一个布局、偏移 +0x800”。本章只用 core0。
pub const matrix_core0_base: usize = 0x2058_5000;
pub const matrix_core1_offset: usize = 0x800;

/// 本章用到的中断源编号，取自 `soc/interrupts.h` 的 `periph_interrupt_t`。
/// 完整表是 169 项（`ETS_MAX_INTR_SOURCE`），这里只抄有用的几个，避免一张死表。
pub const Source = enum(u8) {
    /// ETS_SYS_ICM_INTR_SOURCE = 0
    sys_icm = 0,
    /// ETS_UART0_INTR_SOURCE = 9
    uart0 = 9,
    /// ETS_TIMERGRP0_T0_INTR_SOURCE = 25（TIMG0 的 T0）
    timer_group0_t0 = 25,
    /// ETS_SYSTIMER_TARGET0_INTR_SOURCE = 33
    systimer_target0 = 33,
    /// ETS_GPIO_INTR0_SOURCE = 61
    gpio0 = 61,
    /// ETS_CPU_INTR_FROM_CPU_0_SOURCE = 65（IPI 预览用）
    cpu_int_from_cpu_0 = 65,
};

/// 某个源的映射寄存器地址：矩阵基址 + 4 × 源编号（矩阵里每个源一个 32 位寄存器）。
pub fn mapReg(source: Source, core: u1) usize {
    return matrix_core0_base + @as(usize, core) * matrix_core1_offset + @as(usize, @intFromEnum(source)) * 4;
}

/// 读回某个源的映射值（`MAP`[5:0] 是 CLIC 输入号 + `PASS_LEVEL`[9:8]）。
pub fn mapValue(source: Source, core: u1) u32 {
    return reg(mapReg(source, core)).*;
}

/// 把源路由到 CLIC 输入 `channel + 16`，返回该输入号。
///
/// 关键细节：MAP[5:0] 里写的是 **CLIC 输入号**（16..47），不是 0..31 的外部号。
/// 依据是 IDF 自己的调用链：`intr_matrix_route(intr_src, intr_num)` 先校验
/// `intr_num < 32`，再把 `intr_num + RV_EXTERNAL_INT_OFFSET` 交给
/// `interrupt_clic_ll_route()`，后者用掩码 63 写进这 6 位。反过来说，
/// 若把 0..31 直接写进去，中断会落到 CLIC 的内部输入上，**永远进不了 ISR**。
///
/// `channel` 是编译期常量：越界在这里就是编译错误，不把错误留到运行期。
/// 只改低 6 位，`PASS_LEVEL` 保持 0（不走 remap、直接投递到 M 级）。
pub fn route(source: Source, comptime channel: u6) Input {
    comptime {
        if (channel >= ext_int_count) {
            @compileError("channel 必须 < 32（RV_EXTERNAL_INT_COUNT）");
        }
    }
    const id = channel + ext_int_offset;
    const p = reg(mapReg(source, 0));
    const pass = p.* & 0x300; // 保留 PASS_LEVEL[9:8]
    p.* = pass | @as(u32, id);
    return id;
}

// ---------------------------------------------------------------------------
// CLIC 输入：优先级、使能、挂起
// ---------------------------------------------------------------------------

/// 设优先级（0..7）。编码进 CTL 字节的高 NLBITS 位，低 `8-NLBITS` 位保持原样
/// （复位值 0x1f，与 IDF 的 `NLBITS_TO_BYTE` 约定一致；硬件比较时看的是高位）。
pub fn setPriority(id: Input, level: u3) void {
    const p = ctrl(id);
    const v = p.*;
    const byte: u32 = (v >> 24) & 0xFF;
    const low_mask: u32 = (@as(u32, 1) << level_shift) - 1;
    const new_byte = (byte & low_mask) | @as(u32, encodeLevel(level));
    p.* = (v & 0x00FF_FFFF) | (new_byte << 24);
}

/// 读回当前优先级（只看 CTL[31:24] 的高 NLBITS 位）。
pub fn priority(id: Input) u3 {
    return decodeThreshold(@truncate(ctrl(id).* >> 24));
}

/// 打开该输入的 `IE` 位（CLIC 的“中断使能”在内存映射寄存器里，不在 `mie`）。
pub fn enableInput(id: Input) void {
    const p = ctrl(id);
    p.* = p.* | bit_ie;
}

pub fn disableInput(id: Input) void {
    const p = ctrl(id);
    p.* = p.* & ~bit_ie;
}

pub fn isEnabled(id: Input) bool {
    return (ctrl(id).* & bit_ie) != 0;
}

pub fn isPending(id: Input) bool {
    return (ctrl(id).* & bit_ip) != 0;
}

/// 置挂起位（IP）。对电平中断等于“等外设撤销”，对边沿/软件中断就是触发。
///
/// 这同时是 IDF `rv_utils_intr_edge_ack()` 的实现：边沿中断在这种硬件上
/// **靠写 1 到 IP 来应答**，没有 PLIC 那种 claim/complete 寄存器。
pub fn raise(id: Input) void {
    const p = ctrl(id);
    p.* = p.* | bit_ip;
}

pub fn clearPending(id: Input) void {
    const p = ctrl(id);
    p.* = p.* & ~bit_ip;
}

/// 硬件向量中断能力（CONFIG.NVBITS，复位值 1）。
pub fn hasHardwareVector() bool {
    return (reg(reg_config).* & 0x1) != 0;
}

/// CONFIG.MNLBITS[4:1] 的原始值：硬件实现的优先级位数。仅用于打印核对，
/// 编码固定按 IDF 的 NLBITS=3（8 级）实现。
pub fn priorityBitsRaw() u4 {
    return @truncate((reg(reg_config).* >> 1) & 0xF);
}

/// INFO.NUM_INT[12:0]：实现的输入数量（复位值 48）。
pub fn inputCount() u32 {
    return reg(reg_info).* & 0x1FFF;
}

/// INFO.VERSION[20:13] 的低 4 位是硬件实现版本，高 4 位是 CLIC 架构版本。
pub fn versionRaw() u8 {
    return @truncate((reg(reg_info).* >> 13) & 0xFF);
}

// ---------------------------------------------------------------------------
// 阈值
// ---------------------------------------------------------------------------

/// 设阈值：**优先级 ≤ 阈值的中断被屏蔽**（包含边界，这是与“只屏蔽更低级”最容易
/// 搞混的一点）。0 表示什么都不屏蔽。
///
/// 写完之后必须读一次这个寄存器：IDF 的 `rv_utils_restore_intlevel_regval()` 里
/// 明确写了“写阈值后新的阈值不会立刻被 CPU 看到，要执行约 8 条 nop 或做一次
/// 内存读”，本函数用一次读来完成这个强制。
pub fn setThreshold(level: u3) void {
    const p = reg(reg_thresh);
    const v = p.*;
    p.* = (v & 0x00FF_FFFF) | (@as(u32, encodeThreshold(level)) << 24);
    _ = p.*;
}

/// 读当前阈值（解成优先级级别 0..7）。
pub fn threshold() u3 {
    return decodeThreshold(@truncate(reg(reg_thresh).* >> 24));
}

/// 读原样的阈值字节（临界区保存/恢复用，避免来回编解码丢低位）。
pub fn thresholdRaw() u8 {
    return @truncate(reg(reg_thresh).* >> 24);
}

pub fn setThresholdRaw(byte: u8) void {
    const p = reg(reg_thresh);
    const v = p.*;
    p.* = (v & 0x00FF_FFFF) | (@as(u32, byte) << 24);
    _ = p.*;
}

// ---------------------------------------------------------------------------
// mtvec / mtvt
// ---------------------------------------------------------------------------

/// 装 `mtvec`：MODE=0（直接模式），所有异常与中断都跳 `addr`。
/// BASE 必须 4 字节对齐，否则硬件会把它当成另一种模式解释。
pub fn installDirect(addr: usize) error{Misaligned}!void {
    if (addr & 0x3 != 0) return error.Misaligned;
    asm volatile ("csrw mtvec, %[v]"
        :
        : [v] "r" (@as(u32, @intCast(addr))),
    );
}

/// 装 CLIC 向量模式：`mtvec = (exception_base & ~3) | 3`，`mtvt = table`。
///
/// 依据：`csr_clic.h` 的 `MTVEC_MODE_CSR = 3`，注释写明“MODE=3 时
/// `MTVT + 4 * interrupt_id` 是硬件向量中断的服务入口地址”；`MTVT_CSR = 0x307`。
/// CLIC 向量表要求 64 字节对齐，条目本身是 4 字节指令（通常是一条 `j handler`）。
///
/// **本章不用这条路**：向量表要在链接期生成、每条必须是 ±1 MB 内的 `j`，
/// 而本仓没有在真机上确认过 S31 的 `mcause` 输入号与表项对齐细节。
/// 函数留着是为了把“两条路”的差别固定成代码，而不是让读者以为只有一条。
pub fn installVectored(exception_base: usize, table: usize) error{Misaligned}!void {
    if (table & 0x3F != 0) return error.Misaligned;
    asm volatile ("csrw 0x307, %[v]"
        :
        : [v] "r" (@as(u32, @intCast(table))),
    );
    asm volatile ("csrw mtvec, %[v]"
        :
        : [v] "r" (@as(u32, @intCast((exception_base & ~@as(usize, 0x3)) | 0x3))),
    );
}

/// 读 `mtvec` 原值（低 2 位是模式）。
pub fn mtvec() u32 {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> u32),
    );
}

/// 读 `mtvt`（CSR 0x307）。MODE=0 时它没有意义，只用于核对。
pub fn mtvt() u32 {
    return asm volatile ("csrr %[d], 0x307"
        : [d] "=r" (-> u32),
    );
}

/// 该输入是否被配置成硬件向量中断（ATTR.SHV）。向量模式下才相关。
pub fn isHardwareVector(id: Input) bool {
    return (ctrl(id).* & bit_shv) != 0;
}
