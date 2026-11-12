//! ch14-dual-core-smp-ipi：每核数据（PerCpu）、core1 启动、IPI 收发。
//!
//! ## 为什么需要 PerCpu
//!
//! 两个核跑的是同一份代码、同一份 .data/.bss。任何“当前任务是谁”“下一个
//! 该跑谁”“我收到过几次 IPI”这类状态都必须是每核一份，否则两个核会互相
//! 覆盖对方的调度决定。把它们塞进一个 `PerCpu` 结构体、每核一份，再用
//! `mscratch` 指向自己那份：
//!
//!   smp.attach()  →  csrw mscratch, &cpus[hartid]
//!   smp.me()      →  csrr mscratch
//!
//! `mscratch` 比“全局数组 + 每次读 mhartid”好在两点：trap 入口与 switchRaw
//! 里只要一条 CSR 读，且不占通用寄存器；代价是它是 M 模式专用，S/U 模式
//! 需要换成 `sscratch` 或 per-hart TLS。
//!
//! ## PerCpu 的前两个字段是汇编契约
//!
//! src/context.zig 的 switchRaw：
//!
//!        csrr t0, mscratch
//!        lw   t1, 0(t0)     # save_slot
//!        sw   sp, 0(t1)
//!        lw   sp, 4(t0)     # target_sp
//!
//! 所以 `save_slot` 必须在偏移 0、`target_sp` 在偏移 4（RV32 指针 4 字节）。
//! 下面的 comptime 断言把这件事钉死 —— 改字段顺序会直接编译失败。
//!
//! ## core1 是怎么起来的
//!
//! IDF 的顺序（components/esp_system/port/cpu_start.c:308 `start_other_core`）：
//!   1. 查芯片核数（单核型号直接 abort）；
//!   2. `esp_cpu_unstall(1)` —— 写 PMU 的 stall code 并等 CORESTALLED_ST 清零；
//!   3. `cpu_utility_ll_enable_clock_and_reset_app_cpu()` —— HP_SYS_CLKRST 的
//!      CORE1_CLIC_CLK_EN(bit0) / CORE1_CPU_CLK_EN(bit1) 置 1、
//!      CORE1_GLOBAL_RST_EN(bit2) 清 0；
//!   4. `ets_set_appcpu_boot_addr(call_start_cpu1)` —— 写 ROM 的引导地址；
//!   5. 自旋等 `s_cpu_up[1]`。
//!
//! 本工程用同一组寄存器，但把“写引导地址”提到“释放复位”之前：
//! 时钟一开、复位一松，核就会从引导地址取指；顺序反过来会有一段
//! “核在跑、引导地址还是旧值”的窗口。
//!
//! 本章不调用 IDF，引导地址寄存器通过 ROM 的 `ets_set_appcpu_boot_addr`
//! （0x2f8000a8，esp32s31.rom.ld:57）写入 —— 这是 ROM 保证的 ABI，
//! 比猜 HP_SYSTEM 里的寄存器偏移稳。

const hw = @import("hw.zig");
const clic = @import("clic.zig");
const sched = @import("sched.zig");

pub const hart_count: usize = 2;

/// 与 sched.zig 的优先级级数一致；队列头/尾数组按这个长度零初始化。
pub const prio_levels: usize = 8;

/// 每核状态。extern struct 的字段顺序是汇编契约（见文件头）。
pub const PerCpu = extern struct {
    /// 偏移 0：switchRaw 把旧 sp 写到这里（指向旧任务的 sp 字段）。
    save_slot: *usize,
    /// 偏移 4：switchRaw 从这里 load 新任务的 sp。
    target_sp: usize,

    /// 当前在跑的任务（含 idle）。
    current: ?*sched.Task,
    /// 本核的 idle 任务（不参与优先级队列）。
    idle: ?*sched.Task,

    hart: u32,
    /// 1 = 返回 trap 之前需要检查一次是否换栈。
    need_resched: u32,

    // ---- 观测量（只在最后打印，不在 ISR 里打印）----
    ticks: u32,
    ipis_in: u32,
    ipis_out: u32,
    wakeups: u32,
    /// ping-pong 中真正被 IPI 唤醒的次数（与 job 无关，单列一项）。
    pings: u32,
    migrated: u32,
    jobs: u32,
    switches: u32,

    /// 本核就绪队列的自旋锁（0 = 空闲）。跨核入队也用它。
    lock: u32,

    /// 每优先级一条环形链（与 ch11/ch12 同构，但每核一份）。
    head: [prio_levels]?*sched.Task,
    tail: [prio_levels]?*sched.Task,

    // ---- 跨核往返延迟（supervisor 测，core0 侧）----
    rt_min: u64,
    rt_max: u64,
    rt_sum: u64,
    rt_n: u32,

    // ---- ISR → 任务 的唤醒延迟（各自核测）----
    isr_ts: u64,
    wk_min: u64,
    wk_max: u64,
    wk_sum: u64,
    wk_n: u32,
};

comptime {
    if (@offsetOf(PerCpu, "save_slot") != 0) @compileError("save_slot 必须在偏移 0");
    if (@offsetOf(PerCpu, "target_sp") != 4) @compileError("target_sp 必须在偏移 4（switchRaw 契约）");
}

var dummy_sp: usize = 0;

/// 两个核的 PerCpu。 .bss，由 core0 的 _start 清零。
pub var cpus: [hart_count]PerCpu = undefined;

/// core1 是否已经完成自己的初始化（atomic，0/1）。
var core1_ready: u32 = 0;

pub fn init() void {
    var i: usize = 0;
    while (i < hart_count) : (i += 1) {
        cpus[i] = .{
            .save_slot = &dummy_sp,
            .target_sp = 0,
            .current = null,
            .idle = null,
            .hart = @intCast(i),
            .need_resched = 0,
            .ticks = 0,
            .ipis_in = 0,
            .ipis_out = 0,
            .wakeups = 0,
            .pings = 0,
            .migrated = 0,
            .jobs = 0,
            .switches = 0,
            .lock = 0,
            .head = @splat(null),
            .tail = @splat(null),
            .rt_min = ~@as(u64, 0),
            .rt_max = 0,
            .rt_sum = 0,
            .rt_n = 0,
            .isr_ts = 0,
            .wk_min = ~@as(u64, 0),
            .wk_max = 0,
            .wk_sum = 0,
            .wk_n = 0,
        };
    }
    attach();
}

/// 把本核的 mscratch 指向自己的 PerCpu。必须在任何 trap 之前调用。
pub fn attach() void {
    const id = hw.hartId();
    hw.setMscratch(@intFromPtr(&cpus[id]));
}

/// 本核的 PerCpu。trap 入口、调度器、IPI 都经这里。
pub fn me() *PerCpu {
    return @ptrFromInt(hw.mscratch());
}

/// mscratch 还没装好时的安全读法（仅供 trap 早期诊断）。
pub fn meOrNull() ?*PerCpu {
    const p = hw.mscratch();
    if (p == 0) return null;
    return @ptrFromInt(p);
}

/// switchRaw 的入参通道：写本核 PerCpu 的前两个字段。
pub fn prepareSwitch(save_slot: *usize, new_sp: usize) void {
    const cpu = me();
    cpu.save_slot = save_slot;
    cpu.target_sp = new_sp;
}

pub fn prepareSwitchFor(cpu: *PerCpu, save_slot: *usize, new_sp: usize) void {
    cpu.save_slot = save_slot;
    cpu.target_sp = new_sp;
}

// ---------------------------------------------------------------------------
// core1 启动
// ---------------------------------------------------------------------------

const hp_sys: usize = 0x2058_6000;
const hp_sys_clkrst: usize = 0x2058_7000;
const pmu: usize = 0x2070_4000;

const hpcore1_ctrl0: usize = hp_sys_clkrst + 0x20;
const bit_core1_clic_clk_en: u32 = 1 << 0;
const bit_core1_cpu_clk_en: u32 = 1 << 1;
const bit_core1_global_rst_en: u32 = 1 << 2;

const pmu_cpu_stall_sw: usize = pmu + 0x1ec;
const stall_core1_shift: u5 = 16;
const stall_run: u32 = 0xFF;

const corestalled_st: usize = hp_sys + 0x64;
const bit_core1_stalled: u32 = 1 << 1;

/// ROM: void ets_set_appcpu_boot_addr(uint32_t start)（esp32s31.rom.ld:57）。
extern fn ets_set_appcpu_boot_addr(start: u32) void;

/// core0 调用：把 core1 从复位/停钟/停核状态放出来，让它从 `entry` 取指。
pub fn startCore1(entry: usize) void {
    // 1) 时钟：CLIC 与 CPU 两路都开，但**先不**碰 GLOBAL_RST_EN —— 复位仍保持。
    const ctrl = hw.reg(hpcore1_ctrl0);
    var v = ctrl.*;
    v |= bit_core1_clic_clk_en | bit_core1_cpu_clk_en;
    ctrl.* = v;
    hw.fenceRwRw();

    // 2) 引导地址：必须在释放复位之前写好（见文件头）。
    ets_set_appcpu_boot_addr(@intCast(entry));
    hw.fenceRwRw();

    // 3) 单独一次写释放全局复位。与第 1 步合并会留下“时钟已开、复位已松、
    //    引导地址还是旧值”的窗口 —— 核可能从 0 或上一次的残留地址取指。
    var r = ctrl.*;
    r &= ~bit_core1_global_rst_en;
    ctrl.* = r;
    hw.fenceRwRw();

    // 4) 解 stall：core1 的 stall code 在 PMU_CPU_STALL_SW[23:16]，
    //    0xFF = 运行（pmu_reg.h:4099 起；IDF 的 cpu_utility_ll_unstall_cpu
    //    写的就是这个字段）。
    const stall = hw.reg(pmu_cpu_stall_sw);
    var s = stall.*;
    s = (s & ~(@as(u32, 0xFF) << stall_core1_shift)) | (stall_run << stall_core1_shift);
    stall.* = s;

    // 5) 等 core1 的 CORESTALLED_ST 清零。
    const st = hw.reg(corestalled_st);
    var guard: u32 = 0;
    while ((st.* & bit_core1_stalled) != 0 and guard < 2_000_000) : (guard += 1) {}
}

/// core1 在自己的 core1Main 里调用：IPI 输入 + 矩阵路由 + tick 通道。
pub fn setupCore1Interrupts() void {
    // IPI：源 66（ETS_CPU_INTR_FROM_CPU_1_SOURCE）→ 本核输入 20。
    clic.route(1, clic.source_from_cpu_1, clic.ipi_input_core1);
    clic.setupIpiInput(1);

    // tick：源 26（TIMG0 T1）→ 本核输入 16（见 src/tick.zig）。
    hw.meieEnable();
    clic.setThreshold(0);
}

pub fn markReady() void {
    @atomicStore(u32, &core1_ready, 1, .release);
}

pub fn ready() bool {
    return @atomicLoad(u32, &core1_ready, .acquire) != 0;
}

pub fn waitReady() bool {
    var guard: u32 = 0;
    while (guard < 20_000_000) : (guard += 1) {
        if (ready()) return true;
        hw.burn(8);
    }
    return false;
}

// ---------------------------------------------------------------------------
// IPI
// ---------------------------------------------------------------------------

/// HP_SYSTEM 的 CPU_INT_FROM_CPU_n（n = 目标核）。
const from_cpu_reg: [hart_count]usize = .{ hp_sys + 0x10, hp_sys + 0x14 };

/// 向 `target` 发一个 IPI。
///
/// **顺序是语义的一部分**：调用者必须先发布共享状态（入队、改状态），
/// 这里再 `fence rw, rw`，最后写触发寄存器。少了 fence，目标核可能
/// 先看到“中断来了”，再看到“队列还是空的”，于是醒来却无事可做。
/// 这是 release 语义的最低要求，而 MMIO 写不在普通 store 的排序保证里，
/// 所以显式 fence 比依赖 @atomicStore(..., .release) 更可靠。
pub fn sendIpi(target: u32) void {
    hw.fenceRwRw();
    hw.reg(from_cpu_reg[target]).* = 1;
    me().ipis_out += 1;
}

/// 在本核的 IPI 中断里调用：清源 + 清 CLIC pending。
///
/// 先清源（HP_SYSTEM_CPU_INT_FROM_CPU_n = 0）再清 CLIC 的 IP：反过来的话，
/// 源还挂着（level 型），CLIC 会在 mret 后立刻再投一次。
pub fn ackIpi(core: u32) void {
    hw.reg(from_cpu_reg[core]).* = 0;
    clic.clearPending(clic.ipiInput(core));
}

// ---------------------------------------------------------------------------
// 统计辅助
// ---------------------------------------------------------------------------

pub fn recordRoundTrip(cpu: *PerCpu, ticks: u64) void {
    if (ticks < cpu.rt_min) cpu.rt_min = ticks;
    if (ticks > cpu.rt_max) cpu.rt_max = ticks;
    cpu.rt_sum += ticks;
    cpu.rt_n += 1;
}

pub fn recordWakeLatency(cpu: *PerCpu, ticks: u64) void {
    if (ticks < cpu.wk_min) cpu.wk_min = ticks;
    if (ticks > cpu.wk_max) cpu.wk_max = ticks;
    cpu.wk_sum += ticks;
    cpu.wk_n += 1;
}
