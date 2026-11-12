//! ch06-gpio-uart-log：GPIO 的最小抽象（IO_MUX 引脚复用 + GPIO 外设）。
//!
//! 这一层刻意只做“普通 GPIO 输入/输出”，不做矩阵路由、不做中断、不碰 RMT。
//! 原因见 README 与章节的“WS2812/RMT 边界”一节：GPIO60 上的可寻址 RGB LED
//! 不是普通 GPIO 能驱动的，本章不声称它能亮。
//!
//! 三个寄存器块，各有出处（IDF v6.1）：
//!   - IO_MUX：`components/soc/esp32s31/register/soc/io_mux_reg.h`
//!     基址 `DR_REG_IO_MUX_BASE = 0x20582000`（`register/soc/reg_base.h`）；
//!     每个引脚一个 32 位寄存器，`PERIPHS_IO_MUX_U_*` 的偏移是 **pin × 4**：
//!     GPIO2 → 0x8、GPIO5 → 0x14、GPIO58 → 0xe8、GPIO62 → 0xf8，全部吻合。
//!     GPIO0/1 的寄存器在 0x0/0x4，名字是 XTAL32K 的引脚（同一张表）。
//!   - GPIO：`register/soc/gpio_reg.h`，基址 `DR_REG_GPIO_BASE = 0x20583000`；
//!     引脚号范围 0..62，但本章只实现 bank0（0..31）；bank1 的 OUT1/ENABLE1/
//!     IN1 寄存器留到后续章节。
//!   - GPIO 输出选择：`GPIO_FUNCn_OUT_SEL_CFG_REG = 0xaf4 + 4n`，
//!     `OUT_SEL` 是 bitpos [8:0]，复位值 256 = `SIG_GPIO_OUT_IDX`
//!     （`include/soc/gpio_sig_map.h`），即“由 GPIO_OUT/GPIO_ENABLE 的第 n 位驱动”。
//!
//! 硬件动作已于 2026-11-13 上板验证（日志见 ../logs/ch06-trap.log）；
//! 引脚波形未测，仍按「待真机验证」对待。

const gpio_base: usize = 0x2058_3000;
const io_mux_base: usize = 0x2058_2000;

/// GPIO_OUT_REG = +0x4：输出电平的当前值（整端口）。
const reg_out: usize = gpio_base + 0x04;
/// GPIO_OUT_W1TS_REG = +0x8：写 1 置位对应位（write-1-to-set）。
const reg_out_w1ts: usize = gpio_base + 0x08;
/// GPIO_OUT_W1TC_REG = +0xc：写 1 清位（write-1-to-clear）。
const reg_out_w1tc: usize = gpio_base + 0x0c;
/// GPIO_ENABLE_W1TS_REG = +0x38：写 1 打开对应位的输出使能。
const reg_enable_w1ts: usize = gpio_base + 0x38;
/// GPIO_ENABLE_W1TC_REG = +0x3c：写 1 关闭对应位的输出使能。
const reg_enable_w1tc: usize = gpio_base + 0x3c;
/// GPIO_IN_REG = +0x64：引脚的当前输入电平（整端口）。
const reg_in: usize = gpio_base + 0x64;
/// GPIO_FUNCn_OUT_SEL_CFG_REG 的基址与步长：0xaf4 + 4 * pin。
const reg_func_out_sel_base: usize = gpio_base + 0xaf4;

/// `SIG_GPIO_OUT_IDX = 256`：让该引脚由 GPIO 外设的 OUT/ENABLE 位驱动。
/// 这就是 IDF 里 `gpio_matrix_out(pin, SIG_GPIO_OUT_IDX, false, false)` 的常量。
const sig_gpio_out_idx: u32 = 256;

// IO_MUX 位域（io_mux_reg.h）：
/// FUN_PD = bit 7：下拉使能。
const fun_pd: u32 = 1 << 7;
/// FUN_PU = bit 8：上拉使能。
const fun_pu: u32 = 1 << 8;
/// FUN_IE = bit 9：输入使能。
const fun_ie: u32 = 1 << 9;
/// MCU_SEL = bitpos [14:12]：功能选择；`PIN_FUNC_GPIO = 1` 表示接到 GPIO 外设。
const mcu_sel_shift: u5 = 12;
const mcu_sel_mask: u32 = 0x7 << mcu_sel_shift;
const pin_func_gpio: u32 = 1;

/// S31 的 GPIO 编号是 0..62，但本章只实现 bank0（GPIO0..31）：
/// `GPIO_OUT/ENABLE/IN` 每 32 位一组，GPIO32..62 需要 OUT1/ENABLE1/IN1
/// 以及 W1TS/W1TC 的 1 号寄存器。演示引脚 GPIO5 在 bank0 内。
/// 用 u5 表达 pin，编译器就能挡掉 ≥32 的越界值；bank1 留到后续章节。
pub const Pin = u5;
pub const pin_count: u6 = 32;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

inline fn bit(pin: u5) u32 {
    return @as(u32, 1) << pin;
}

/// 本章只接受 bank0（0..31）；越界时不做任何寄存器写。
inline fn inRange(pin: Pin) bool {
    return @as(u6, pin) < pin_count;
}

/// 某个引脚的 IO_MUX 寄存器地址：偏移 = pin × 4。
/// 本章代码只对**一个**演示引脚做配置，这个线性关系让“引脚号 → 寄存器”
/// 不需要一张手抄表（表里的例外只有 GPIO0/1 的命名，偏移仍符合 pin × 4）。
pub inline fn ioMuxReg(pin: Pin) usize {
    return io_mux_base + @as(usize, pin) * 4;
}

/// 把引脚切到“普通 GPIO”功能：MCU_SEL = 1，并打开输入使能以允许回读。
/// 不改驱动强度与上下拉：复位值通常已够用，改了反而多一个变量。
pub fn selectGpioFunction(pin: Pin) void {
    if (!inRange(pin)) return;
    const addr = ioMuxReg(pin);
    var v = reg(addr).*;
    v &= ~mcu_sel_mask;
    v |= pin_func_gpio << mcu_sel_shift;
    v |= fun_ie;
    reg(addr).* = v;
}

/// 配置为推挽输出，初始电平为低。
///
/// 顺序有讲究，不是随便排的：
///   1. 先 IO_MUX 选 GPIO 功能（否则矩阵/外设仍握着这个引脚）；
///   2. 再写 OUT_SEL = 256，让输出值来自 GPIO_OUT 的对应位；
///   3. 最后打开输出使能 —— 前两步都还没驱动引脚，此时引脚是高阻，
///      避免“先使能、后设电平”产生一个毛刺。
pub fn configureOutput(pin: Pin) void {
    if (!inRange(pin)) return;
    selectGpioFunction(pin);

    // OUT_SEL = 256 是复位值，但 bootloader/ROM 可能改过矩阵，这里显式写回。
    // 整个寄存器写 256 同时清掉了 OUT_INV_SEL/OE_SEL/OE_INV_SEL 等位。
    reg(reg_func_out_sel_base + @as(usize, pin) * 4).* = sig_gpio_out_idx;

    // 先把输出值清 0，再使能：见上面的顺序说明。
    reg(reg_out_w1tc).* = bit(@intCast(pin));
    reg(reg_enable_w1ts).* = bit(@intCast(pin));
}

/// 关闭该引脚的输出使能（引脚回到高阻），输入功能保留。
pub fn releaseOutput(pin: Pin) void {
    if (!inRange(pin)) return;
    reg(reg_enable_w1tc).* = bit(@intCast(pin));
}

/// 配置为输入。`pull_up` 决定是否打开内部上拉（按键到地的接法需要它）。
pub fn configureInput(pin: Pin, pull_up: bool) void {
    if (!inRange(pin)) return;
    selectGpioFunction(pin);
    // 引脚既然只做输入，就不该让 GPIO 外设去驱动它。
    reg(reg_enable_w1tc).* = bit(@intCast(pin));

    const addr = ioMuxReg(pin);
    var v = reg(addr).*;
    v &= ~(fun_pu | fun_pd);
    if (pull_up) v |= fun_pu;
    // 上拉与下拉互斥：两者同时打开会得到分压而不是确定的电平。
    reg(addr).* = v;
}

/// 读引脚电平。读的是 GPIO_IN（引脚上的实际电平），不是 GPIO_OUT（我们写的值）——
/// 输出被外部拉低、或引脚配成输入时，两者会不同。
pub fn get(pin: Pin) bool {
    if (!inRange(pin)) return false;
    return (reg(reg_in).* & bit(@intCast(pin))) != 0;
}

/// 写引脚电平（只在已 configureOutput 的引脚上有效）。
pub fn set(pin: Pin, high: bool) void {
    if (!inRange(pin)) return;
    const b = bit(@intCast(pin));
    if (high) {
        reg(reg_out_w1ts).* = b;
    } else {
        reg(reg_out_w1tc).* = b;
    }
}

/// 翻转引脚电平：先读回 OUT 寄存器的当前值再反向写。
/// 用 W1TS/W1TC 而不是“读-改-写整个 OUT”，这样不会碰到别的引脚。
pub fn toggle(pin: Pin) void {
    if (!inRange(pin)) return;
    const high = (reg(reg_out).* & bit(@intCast(pin))) != 0;
    set(pin, !high);
}
