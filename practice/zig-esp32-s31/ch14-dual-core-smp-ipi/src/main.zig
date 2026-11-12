//! ch14-dual-core-smp-ipi：core0 的启动序列。
//!
//! `main` 只做“把两个核带起来、把第一个任务挂进队列、交出控制权”：
//!
//!   1. 打印 banner / 每核时钟与中断拓扑；
//!   2. `smp.init()`        —— PerCpu[2] + mscratch（本核 = core0）；
//!   3. `systimer.init()`   —— 跨核共享时间轴（先开时钟门，约束 6）；
//!   4. `tick.initSharedGates()` —— TIMG 的 T0/T1 时钟门与 INT_ENA 只写一次；
//!   5. core0 的 CLIC/矩阵：源 65 → 输入 19，tick 源 25 → 输入 16；
//!   6. `demo.setup()`      —— 建任务（supervisor/worker/4×job），
//!                              supervisor 用 `enqueueLocal` 挂到 core0；
//!   7. `smp.startCore1()`  —— 时钟 → 引导地址 → 复位 → 解 stall；
//!   8. 等 core1 的 ready 标志（自旋，不依赖 IPI —— 那时它还没有队列）；
//!   9. `sched.start(0)`    —— 换到 core0 的 idle 栈，打开 MIE，开始轮转。
//!
//! 顺序上的两个硬约束：
//!   - 共享寄存器（TIMG 时钟门、INT_ENA）必须在 core1 起来**之前**写一次，
//!     否则两个核读改写同一只寄存器会丢位；
//!   - core0 的 MIE 必须在所有 CLIC/矩阵配置之后才打开，且由 idle 在
//!     自己的栈上打开（见 src/sched.zig 的 start）。

const hw = @import("hw.zig");
const smp = @import("smp.zig");
const clic = @import("clic.zig");
const tick = @import("tick.zig");
const systimer = @import("systimer.zig");
const sched = @import("sched.zig");
const context = @import("context.zig");
const console = @import("console.zig");
const demo = @import("demo.zig");
const core1 = @import("core1.zig");

fn readMtvec() usize {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> usize),
    );
}

pub export fn main() noreturn {
    const mtvec = readMtvec();

    console.line("ch14-dual-core-smp-ipi | form B (Zig ELF + IDF 2nd-stage bootloader)", .{});
    console.line("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default, shared lock)", .{});
    console.line("mtvec: base=0x{x} mode={d} (0 = direct, same entry on both harts)", .{
        mtvec & ~@as(usize, 3),
        mtvec & 3,
    });
    console.line("frames: trap={d} switch={d} bytes (integer only)", .{
        context.trap_frame_bytes,
        context.switch_frame_bytes,
    });
    console.line("cpu: hart={d} mhartid, cores=2, per-cpu state via mscratch", .{hw.hartId()});
    console.line("ipi: clic input {d}->core0 / {d}->core1 via src {d}/{d}", .{
        clic.ipi_input_core0,
        clic.ipi_input_core1,
        clic.source_from_cpu_0,
        clic.source_from_cpu_1,
    });
    console.line("tick: core0=TIMG0_T0 src {d} / core1=TIMG0_T1 src {d} -> input {d} each", .{
        clic.source_timg0_t0,
        clic.source_timg0_t1,
        clic.tick_input,
    });

    smp.init();
    systimer.init();
    tick.initSharedGates();

    // core0 的中断拓扑：IPI 源 65 → 本核输入 19；tick 在 tick.init(0) 里配。
    clic.route(0, clic.source_from_cpu_0, clic.ipi_input_core0);
    clic.setupIpiInput(0);
    hw.meieEnable();
    tick.init(0);
    clic.setThreshold(0);

    demo.setup();
    console.line("sched: {d} tasks created, 1 queued on core0 (+1 idle per core)", .{
        sched.taskCount(),
    });

    // core1：时钟 → 引导地址 → 释放复位 → 解 stall。
    smp.startCore1(@intFromPtr(&core1.core1Entry));
    if (smp.waitReady()) {
        console.line("core1: ready flag observed by core0 (release/acquire)", .{});
    } else {
        console.line("core1: ready flag TIMEOUT - continuing with core0 only", .{});
    }

    console.line("sched: core0 handing over to idle (MIE opens on idle stack), mscratch=0x{x}", .{
        hw.mscratch(),
    });
    sched.start(0);
}
