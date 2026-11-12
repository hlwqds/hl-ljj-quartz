//! ch06-gpio-uart-log：UART0 的最小驱动（TX 走 ROM，RX 走轮询 FIFO）。
//!
//! 设计取舍先说清楚，因为它决定了本章能证明什么：
//!
//!   - **TX 不做初始化**。ROM 的 `esp_rom_printf` 已经把 UART0 配成 115200 8N1
//!     并输出到 GPIO58（U0TXD_GPIO_NUM = 58，见 IDF v6.1 的
//!     `components/soc/esp32s31/include/soc/uart_pins.h`）。应用再自己写一遍
//!     分频只会引入“谁最后写”的竞争，而本章不需要改波特率。
//!
//!   - **RX 用轮询，不用中断**。原因不是“省事”，而是边界：中断需要
//!     (a) mtvec 指向 CLIC 模式的向量表、(b) 中断矩阵把 UART0 的源号路由到
//!     某个 CPU 通道、(c) 打开 mie/mstatus.MIE。这三件事属于后续章节的
//!     主题；在它们没配好之前打开 UART 中断，只会得到一个“永远不进中断”
//!     或者“进了中断但向量是 bootloader 留下的”的现场。
//!     所以本章采用**轮询 FIFO + 环形缓冲**：数据结构的形状与中断版本完全
//!     一致，后续把“生产者”从 `drainFromFifo()` 换成 ISR 即可。
//!
//!   - **寄存器地址全部有出处**。UART0 基址 0x2038A000 来自 IDF v6.1
//!     `components/soc/esp32s31/ld/esp32s31.peripherals.ld` 的
//!     `PROVIDE ( UART0 = 0x2038A000 )`；寄存器偏移来自
//!     `components/soc/esp32s31/register/soc/uart_reg.h` 的
//!     `UART_XXX_REG(i) = REG_UART_BASE(i) + off`，其中
//!     `REG_UART_BASE(i) = DR_REG_UART_BASE + i*0x1000`（同目录 `soc.h`）。
//!     本文件只抄四个偏移。
//!
//! 一句话：本章的 UART 驱动是“ROM 负责发、我们负责收”。

// ---------------------------------------------------------------------------
// UART0 寄存器（偏移取自 IDF v6.1 components/soc/esp32s31/register/soc/uart_reg.h）
// ---------------------------------------------------------------------------
const uart0_base: usize = 0x2038_A000;

/// UART_FIFO_REG(i) = REG_UART_BASE(i) + 0x0。
/// 写：推一个字节进 TX FIFO；读：从 RX FIFO 取一个字节（低 8 位是数据）。
const reg_fifo: usize = uart0_base + 0x00;

/// UART_STATUS_REG(i) = +0x1c：RXFIFO_CNT = bitpos [7:0]，TXFIFO_CNT = [23:16]。
const reg_status: usize = uart0_base + 0x1c;

/// UART_INT_RAW_REG(i) = +0x4：未屏蔽的原始中断标志。本章只读不清。
const reg_int_raw: usize = uart0_base + 0x04;

const rxfifo_cnt_mask: u32 = 0xFF;
const txfifo_cnt_shift: u5 = 16;

/// UART_FRM_ERR_INT_RAW = bitpos [3]（uart_reg.h 的 INT_RAW 段）。
/// 置位表示接收侧解析到过帧错误：波特率不匹配、TX/RX 接反、或线上干扰。
const frm_err_bit: u32 = 1 << 3;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

// ---------------------------------------------------------------------------
// TX：全部经过掩膜 ROM 的 printf（链接脚本 PROVIDE 到 0x2f800024）
// ---------------------------------------------------------------------------
extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

/// 输出一个字节。`%c` 的实参按 C 的默认提升传 `int`。
/// ROM 的 printf 是阻塞式的：TX FIFO 满时它会等，所以这里不需要查 TXFIFO_CNT。
pub fn putc(c: u8) void {
    _ = esp_rom_printf("%c", @as(c_int, c));
}

/// 输出一个以 NUL 结尾的字符串。必须是 `[*:0]const u8`：
/// Zig 的切片（`[]const u8`）是“指针 + 长度”，传给 C 变参会丢长度，
/// printf 会一路读到内存里第一个 0 为止。
pub fn puts(s: [*:0]const u8) void {
    _ = esp_rom_printf("%s", s);
}

/// 输出 `label=0xXXXXXXXX`（小写十六进制、固定 8 位，便于对齐阅读）。
pub fn putHex32(label: [*:0]const u8, v: u32) void {
    puts(label);
    puts("=0x");
    var shift: u5 = 28;
    while (true) {
        const nibble: u8 = @intCast((v >> shift) & 0xF);
        putc(if (nibble < 10) '0' + nibble else 'a' + (nibble - 10));
        if (shift == 0) break;
        shift -= 4;
    }
}

/// 输出 `label=<十进制>`。自己算十进制而不是用 `%d`：ROM 的 printf 是 C 变参，
/// 32 位无符号与 `%d`（int）在符号语义上不同，写错一次就会打印出负数；
/// 自己转换只有十几行，且与 ABI 无关。
pub fn putDec32(label: [*:0]const u8, v: u32) void {
    puts(label);
    putc('=');
    if (v == 0) {
        putc('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x != 0) {
        buf[n] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        n += 1;
    }
    while (n != 0) {
        n -= 1;
        putc(buf[n]);
    }
}

// ---------------------------------------------------------------------------
// RX：轮询 FIFO
// ---------------------------------------------------------------------------

/// RX FIFO 里当前可读的字节数（UART_STATUS.RXFIFO_CNT）。
pub fn rxFifoCount() u8 {
    return @intCast(reg(reg_status).* & rxfifo_cnt_mask);
}

/// TX FIFO 里待发的字节数（UART_STATUS.TXFIFO_CNT）。
pub fn txFifoCount() u8 {
    return @intCast((reg(reg_status).* >> txfifo_cnt_shift) & rxfifo_cnt_mask);
}

/// 从 RX FIFO 取一个字节；FIFO 空时返回 null。
/// 读 FIFO 寄存器的低 8 位就是数据字节（其余位是帧错误/溢出等状态位）。
pub fn readByte() ?u8 {
    if (rxFifoCount() == 0) return null;
    return @intCast(reg(reg_fifo).* & 0xFF);
}

/// 硬件是否报告过帧错误（粘滞标志，本章不清）。
pub fn sawFrameError() bool {
    return (reg(reg_int_raw).* & frm_err_bit) != 0;
}

// ---------------------------------------------------------------------------
// 环形缓冲
// ---------------------------------------------------------------------------

/// 单生产者/单消费者（SPSC）环形缓冲，容量必须是 2 的幂。
///
///   - `head` 由生产者推进（这里是轮询 `drainFromFifo`，将来是 ISR）；
///   - `tail` 由消费者推进（主循环里的 `pop`）；
///   - 两者都是单调递增的 u32，取模用 `& (capacity - 1)`，所以不需要
///     “留一个空位”的经典技巧，`len()` 直接是 `head -% tail`。
///     u32 回绕在模 2^32 减法下仍然正确。
///
/// 满时**丢弃新字节并计数**，而不是覆盖旧数据：命令行场景里丢一个字符比
/// 悄悄丢掉半条命令更容易被发现，`drops` 也会出现在心跳行里。
pub const RingBuffer = struct {
    pub const capacity: usize = 128;
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("capacity 必须是 2 的幂");
        }
    }

    buf: [capacity]u8 = undefined,
    head: u32 = 0,
    tail: u32 = 0,
    drops: u32 = 0,

    pub fn len(self: *const RingBuffer) u32 {
        return self.head -% self.tail;
    }

    pub fn isFull(self: *const RingBuffer) bool {
        return self.len() == capacity;
    }

    /// 生产者：放一个字节。返回 false 表示缓冲满、本次丢弃。
    pub fn push(self: *RingBuffer, b: u8) bool {
        if (self.isFull()) {
            self.drops +%= 1;
            return false;
        }
        self.buf[@as(usize, self.head & (capacity - 1))] = b;
        self.head +%= 1;
        return true;
    }

    /// 消费者：取一个字节；空时返回 null。
    pub fn pop(self: *RingBuffer) ?u8 {
        if (self.len() == 0) return null;
        const b = self.buf[@as(usize, self.tail & (capacity - 1))];
        self.tail +%= 1;
        return b;
    }

    /// 把硬件 FIFO 里现有的字节全部搬进环形缓冲，返回搬入的字节数。
    /// 这就是“中断版本里 ISR 要做的事”，只是现在由主循环按固定节奏调用：
    /// 每次循环只搬当时的存量，不做等待，因此不会把主循环卡在串口上。
    pub fn drainFromFifo(self: *RingBuffer) u32 {
        var moved: u32 = 0;
        while (readByte()) |b| {
            _ = self.push(b);
            moved += 1;
        }
        return moved;
    }
};
