//! ch07-interrupts-clic：trap 入口、ISR 分发表、UART0 接收中断与环形缓冲。
//!
//! 这个文件是本章的“契约层”，它同时承担三件互相牵连的事：
//!
//!   1. **trap 入口**（`trapVector`）。naked 函数，只做“保存易失寄存器 → 读
//!      `mcause`/`mepc` → 调 C 调用约定的普通函数 → 恢复 → `mret`”。
//!      异常与中断共用同一个入口（`mtvec` MODE=0），靠 `mcause` 最高位分流。
//!
//!   2. **分发表**（`attach` / `dispatch`）。CLIC 的输入号就是 `mcause` 的低位，
//!      所以一张 48 项的表就是完整的向量表。未登记的输入会被**关掉**并计数，
//!      否则一个没人应答的电平中断会把 CPU 钉死在 ISR 里。
//!
//!   3. **UART0 RX 中断 + 环形缓冲**。ISR 只搬字节、清标志，绝不打印：
//!      本章的 TX 走 ROM 的阻塞式 `printf`，在 ISR 里调用它等于把中断延迟
//!      从微秒级推到毫秒级。打印永远在主循环里做。
//!
//! 「待真机验证」：本仓没有在 S31 上跑过这段代码。保存/恢复的寄存器集合、
//! `mret` 的返回行为、UART 标志的清除时序都要上板确认。

const clic = @import("clic.zig");

// ---------------------------------------------------------------------------
// UART0 接收侧寄存器（RX 侧只在这里出现一次；TX 侧在 main.zig 走 ROM printf）
// ---------------------------------------------------------------------------

/// UART0 基址：IDF v6.1 `esp32s31.peripherals.ld` 的 `UART0 = 0x2038A000`。
const uart0_base: usize = 0x2038_A000;
/// `UART_FIFO_REG(i)` = 基址 + 0x00：读出的低 8 位就是接收字节。
const uart_fifo: usize = uart0_base + 0x00;
/// `UART_STATUS_REG(i)` = +0x1c：`RXFIFO_CNT` 在 [7:0]。
const uart_status: usize = uart0_base + 0x1c;
/// `UART_INT_CLR_REG(i)` = +0x10：写 1 清除对应标志（WT）。
const uart_int_clr: usize = uart0_base + 0x10;

/// 本章打开的接收类中断：`RXFIFO_FULL`（bit0）与 `RXFIFO_TOUT`（bit8）。
/// 位号来自 `uart_reg.h` 的 INT_ENA/INT_CLR 段。
///
/// 两个都要：FULL 负责“攒够阈值”，TOUT 负责“线上静默一小会儿”，
/// 后者才是单键输入能立刻回显的原因（`RXFIFO_FULL_THRHD` 的复位值是 96）。
pub const rx_int_bits: u32 = (1 << 0) | (1 << 8);

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

// ---------------------------------------------------------------------------
// 可易失访问的整数：ISR 与主循环共享同一份内存
// ---------------------------------------------------------------------------

/// 读一个“可能被 ISR 改写”的 u32。
/// 用 `@ptrFromInt` 绕一圈是为了拿到 `*volatile u32`：`*u32` 显式转 volatile
/// 指针在 Zig 里最稳的写法就是这个（`@volatileCast` 只做反向去除）。
inline fn vload(p: *const u32) u32 {
    const vp: *const volatile u32 = @ptrFromInt(@intFromPtr(p));
    return vp.*;
}

inline fn vstore(p: *u32, v: u32) void {
    const vp: *volatile u32 = @ptrFromInt(@intFromPtr(p));
    vp.* = v;
}

// ---------------------------------------------------------------------------
// 分发表
// ---------------------------------------------------------------------------

/// ISR 签名：无参数、无返回值。需要传信息就用模块级变量。
pub const Handler = *const fn () void;

/// 48 项 = CLIC 的 48 个输入（0..15 内部，16..47 来自中断矩阵）。
const table_size: usize = 48;
var table: [table_size]?Handler = [_]?Handler{null} ** table_size;

/// 观测计数：中断总次数、未登记输入次数、最后一次未登记的输入号。
pub var irq_total: u32 = 0;
pub var unhandled: u32 = 0;
pub var last_unhandled: u32 = 0xFF;

/// 登记一个输入（`id` 就是 `clic.route()` 的返回值）。
/// 覆盖已有登记时会返回旧值，方便调用者断言“没被别人占着”。
pub fn attach(id: clic.Input, h: Handler) ?Handler {
    if (@as(usize, id) >= table_size) return null;
    const old = table[@as(usize, id)];
    table[@as(usize, id)] = h;
    return old;
}

pub fn detach(id: clic.Input) void {
    if (@as(usize, id) >= table_size) return;
    table[@as(usize, id)] = null;
}

pub fn handlerFor(id: clic.Input) ?Handler {
    if (@as(usize, id) >= table_size) return null;
    return table[@as(usize, id)];
}

/// 分发一次中断。`id` 来自 `mcause & 0x3F`（CLIC 把输入号直接放进 `mcause`）。
///
/// 未登记的输入不只是“计数然后返回”：它的 `IE` 位会被关掉。原因是电平触发的
/// 外设中断在源侧没被清之前会一直挂起，`mret` 之后立刻再次进 trap，
/// 主循环一步都走不了。关掉 `IE` 是最小、最可诊断的处置（串口还能告诉你
/// 是哪一个输入惹的祸）。
pub fn dispatch(id: clic.Input) void {
    irq_total +%= 1;
    if (handlerFor(id)) |h| {
        h();
        return;
    }
    unhandled +%= 1;
    last_unhandled = @as(u32, id);
    clic.disableInput(id);
}

// ---------------------------------------------------------------------------
// trap 入口
// ---------------------------------------------------------------------------

/// trap 向量：`mtvec` MODE=0（直接模式）的目标，异常与中断都从这里进。
///
/// 现场保存只做**易失寄存器**（ABI 里的 caller-saved）：`ra`、`t0`..`t6`、
/// `a0`..`a7`，共 16 个 32 位字 = 64 字节；再加上“原始 sp”一个槽位，
/// 帧长 80 字节（16 的倍数，保持 ABI 的栈对齐）。
///
/// 不保存 `s0`..`s11`：它们是 callee-saved，被调用的 Zig 函数自己会保存。
/// 不保存浮点寄存器：本工程全整数（见 README 的“F 寄存器边界”），
/// 一旦 ISR 里出现 `f` 指令或主循环依赖 `f0`..`f31` 跨中断存活，
/// 就必须把 32 个 F 寄存器一起存（128 字节）——那是 ch10 上下文切换的主题。
export fn trapVector() linksection(".text.entry") callconv(.naked) noreturn {
    asm volatile (
        \\        addi    sp, sp, -80
        \\        sw      ra, 0(sp)
        \\        sw      t0, 4(sp)
        \\        sw      t1, 8(sp)
        \\        sw      t2, 12(sp)
        \\        sw      t3, 16(sp)
        \\        sw      t4, 20(sp)
        \\        sw      t5, 24(sp)
        \\        sw      t6, 28(sp)
        \\        sw      a0, 32(sp)
        \\        sw      a1, 36(sp)
        \\        sw      a2, 40(sp)
        \\        sw      a3, 44(sp)
        \\        sw      a4, 48(sp)
        \\        sw      a5, 52(sp)
        \\        sw      a6, 56(sp)
        \\        sw      a7, 60(sp)
        \\        addi    t0, sp, 80           # 原始 sp
        \\        sw      t0, 64(sp)
        \\
        \\        csrr    a0, mcause           # bit31=1 → 中断，低位是 CLIC 输入号
        \\        csrr    a1, mepc             # 被中断/出错指令的地址
        \\        mv      a2, t0               # 原始 sp（报告用）
        \\        call    trapDispatch
        \\
        \\        lw      ra, 0(sp)
        \\        lw      t0, 4(sp)
        \\        lw      t1, 8(sp)
        \\        lw      t2, 12(sp)
        \\        lw      t3, 16(sp)
        \\        lw      t4, 20(sp)
        \\        lw      t5, 24(sp)
        \\        lw      t6, 28(sp)
        \\        lw      a0, 32(sp)
        \\        lw      a1, 36(sp)
        \\        lw      a2, 40(sp)
        \\        lw      a3, 44(sp)
        \\        lw      a4, 48(sp)
        \\        lw      a5, 52(sp)
        \\        lw      a6, 56(sp)
        \\        lw      a7, 60(sp)
        \\        addi    sp, sp, 80
        \\        mret
    );
}

/// trap 分流：中断 → 查表分发后返回；异常 → 打印现场后停机。
///
/// `export` 不是装饰：上面的汇编里 `call trapDispatch` 只是一个字符串，
/// 编译器看不到引用关系，不 export 就会被当成死代码丢掉，链接期报
/// `undefined symbol: trapDispatch`。
export fn trapDispatch(cause: u32, mepc: u32, sp: u32) void {
    if ((cause & 0x8000_0000) != 0) {
        // CLIC 的中断异常码就是输入号；S31 的 mcause 低位宽度是 6 位。
        const id: clic.Input = @truncate(cause & 0x3F);
        dispatch(id);
        return;
    }
    reportException(cause, mepc, sp);
    halt();
}

/// 软件侧的统一停机点：`wfi` + 跳回，直到复位。
pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

// ---------------------------------------------------------------------------
// 异常报告（只在异常路径上，不进 ISR 热路径）
// ---------------------------------------------------------------------------

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

fn puts(s: [*:0]const u8) void {
    _ = esp_rom_printf("%s", s);
}

fn putHex(v: u32) void {
    puts("0x");
    var shift: u5 = 28;
    while (true) {
        const nibble: u8 = @intCast((v >> shift) & 0xF);
        _ = esp_rom_printf("%c", @as(c_int, if (nibble < 10) '0' + nibble else 'a' + (nibble - 10)));
        if (shift == 0) break;
        shift -= 4;
    }
}

fn causeName(cause: u32) [*:0]const u8 {
    return switch (cause & 0x3F) {
        0 => "instruction address misaligned",
        1 => "instruction access fault",
        2 => "illegal instruction",
        3 => "breakpoint",
        4 => "load address misaligned",
        5 => "load access fault",
        6 => "store/AMO address misaligned",
        7 => "store/AMO access fault",
        11 => "environment call from M-mode",
        else => "reserved / vendor-specific",
    };
}

fn reportException(cause: u32, mepc: u32, sp: u32) void {
    const mtval: u32 = asm volatile ("csrr %[d], mtval"
        : [d] "=r" (-> u32),
    );
    puts("\n[E] ---- exception ----\n");
    puts("cause: ");
    puts(causeName(cause));
    puts("\n");
    puts("mcause=");
    putHex(cause);
    puts(" mepc=");
    putHex(mepc);
    puts(" mtval=");
    putHex(mtval);
    puts(" sp=");
    putHex(sp);
    puts("\n[E] halted: 需要复位（EN）或重新烧录\n");
}

// ---------------------------------------------------------------------------
// 环形缓冲（SPSC：ISR 生产、主循环消费）
// ---------------------------------------------------------------------------

/// 单生产者/单消费者环形缓冲，容量必须是 2 的幂。
///
/// 与 ch06 的轮询版**结构完全一致**，只多了两样东西：
///   - `head`/`tail` 的读写走 volatile（值可能被 ISR 改）；
///   - 生产/消费之间插入 `fence`（单核上主要是挡住编译器重排，
///     多核/乱序的 SoC 上才是真屏障；本章先把语义写对）。
///
/// 满时丢新字节并计数，不覆盖旧数据：串口命令行里丢一个字符比悄悄丢半条命令
/// 更容易被发现。
pub const RxRing = struct {
    pub const capacity: usize = 256;
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("capacity 必须是 2 的幂");
        }
    }

    buf: [capacity]u8 = undefined,
    head: u32 = 0,
    tail: u32 = 0,
    drops: u32 = 0,

    pub fn len(self: *const RxRing) u32 {
        return vload(&self.head) -% vload(&self.tail);
    }

    pub fn dropped(self: *const RxRing) u32 {
        return vload(&self.drops);
    }

    pub fn clearDrops(self: *RxRing) void {
        vstore(&self.drops, 0);
    }

    /// 生产者：放一个字节。返回 false 表示缓冲满、本次丢弃。
    pub fn push(self: *RxRing, b: u8) bool {
        const head = vload(&self.head);
        const tail = vload(&self.tail);
        if (head -% tail >= capacity) {
            vstore(&self.drops, vload(&self.drops) +% 1);
            return false;
        }
        self.buf[@as(usize, head & (capacity - 1))] = b;
        @fence(.seq_cst);
        vstore(&self.head, head +% 1);
        return true;
    }

    /// 消费者：取一个字节；空时返回 null。
    pub fn pop(self: *RxRing) ?u8 {
        @fence(.seq_cst);
        const tail = vload(&self.tail);
        const head = vload(&self.head);
        if (head == tail) return null;
        @fence(.seq_cst);
        const b = self.buf[@as(usize, tail & (capacity - 1))];
        vstore(&self.tail, tail +% 1);
        return b;
    }
};

/// 全局唯一的接收缓冲。ISR 是唯一生产者，`main` 是唯一消费者。
pub var rx: RxRing = .{};

/// 接收字节总数（含被丢弃的）：用来区分“没收到”和“收到了但放不下”。
pub var rx_bytes: u32 = 0;

/// UART0 的 RX 中断服务程序。
///
/// 三件事，顺序不能乱：
///   1. 按 `RXFIFO_CNT` 读出所有已到达的字节（读 FIFO 本身就是出队）；
///   2. 放进环形缓冲（满了就计丢弃，不阻塞、不等待）；
///   3. 写 `INT_CLR` 应答 `RXFIFO_FULL` 与 `RXFIFO_TOUT`。
///
/// 第 3 步必须在第 1 步之后：先清标志再读 FIFO，中间到达的字节要等下一次
/// 阈值/超时才被看到，表现为“偶发丢一两个字符”。
fn uart0Isr() void {
    var pending: u8 = @truncate(reg(uart_status).* & 0xFF);
    while (pending != 0) {
        const b: u8 = @truncate(reg(uart_fifo).* & 0xFF);
        rx_bytes +%= 1;
        _ = rx.push(b);
        pending -= 1;
    }
    reg(uart_int_clr).* = rx_int_bits;
}

/// 把 UART0 的 RX ISR 挂到分发表上。返回登记时被覆盖的旧处理函数（应为 null）。
pub fn attachUart0(id: clic.Input) ?Handler {
    return attach(id, &uart0Isr);
}

// ---------------------------------------------------------------------------
// 供主循环读取的观测点
//
// 这些变量被 ISR 写、被主循环读，所以读取必须是 volatile 的：非 volatile 读
// 会被编译器提到循环外（“这个变量循环里没被写”），表现为“计数永远停在第一秒”。
// ---------------------------------------------------------------------------

pub fn totalIrqs() u32 {
    return vload(&irq_total);
}

pub fn unhandledCount() u32 {
    return vload(&unhandled);
}

pub fn lastUnhandledId() u32 {
    return vload(&last_unhandled);
}

pub fn rxBytesSeen() u32 {
    return vload(&rx_bytes);
}
