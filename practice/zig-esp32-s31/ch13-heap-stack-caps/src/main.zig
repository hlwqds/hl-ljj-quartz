//! ch13-heap-stack-caps：内存实验的编排。
//!
//! 一次跑完五组观测，全部同步执行（本章不开中断，`MIE` 恒为 0）：
//!
//!   1. 预算表：链接符号给出的各段尺寸 + SRAM 分布；
//!   2. 地址归类：caps 表把每个真实地址映射到区间名（IRAM/DRAM/ROM/flash/PSRAM/MMIO）；
//!   3. TLSF：对齐、分配/释放计数、碎片压测（含越界重叠检测与每轮自检）；
//!   4. slab：固定尺寸槽的页借用、复用与内部碎片；
//!   5. 栈：主栈哨兵 + 高水位；模拟栈被故意踩之后检测器必须报 `overrun`；
//!   6. PSRAM：只读 MMU 探针，映射不存在就明确说 `mapped=no`。
//!
//! 输出全部是"可判读的行"：每行以 `budget:` / `space:` / `heap:` / `frag:` /
//! `slab:` / `stack:` / `psram:` 开头，便于串口里 grep。

const log = @import("log.zig");
const heap = @import("heap.zig");
const caps = @import("caps.zig");
const stack = @import("stack_guard.zig");
const psram = @import("psram.zig");
const tlsf = @import("alloc/tlsf.zig");
const slab_mod = @import("alloc/slab.zig");

// ---------------------------------------------------------------------------
// 1) 地址归类
// ---------------------------------------------------------------------------

fn space(name: []const u8, addr: usize) void {
    log.line("space: {s:<14} = 0x{x:0>8} -> {s}", .{ name, addr, caps.nameOf(addr) });
}

fn reportSpaces() void {
    // 代码/常量在 flash 的 MMU 窗口里，trap 与数据在 SRAM 里，ROM 函数在另一块。
    space("image", heap.addrOfImage());
    space("text", heap.addrOfText());
    space("rodata", heap.addrOfRodata());
    space("trap_vector", heap.addrOfTrap());
    space("data", heap.addrOfData());
    space("heap_start", heap.heapStart());
    space("heap_end", heap.heapEnd());
    space("stack_top", heap.stackRegion().high);
    space("rom.ets_printf", 0x2F80_0024);
    space("psram.window", psram.window_base);
    space("mmu.psram_reg", 0x2050_2000);
}

// ---------------------------------------------------------------------------
// 2) TLSF：对齐 + 碎片压测
// ---------------------------------------------------------------------------

fn reportAlignment() void {
    const want = [_]usize{ 1, 8, 17, 64, 65, 1000, 4096 };
    var ok: usize = 0;
    var ptrs: [want.len]usize = @splat(0);

    for (want, 0..) |n, i| {
        ptrs[i] = heap.allocAligned(n, 64) orelse {
            log.line("alloc: align64 size={d} FAILED (oom)", .{n});
            continue;
        };
        if (ptrs[i] % 64 == 0) ok += 1;
    }
    log.line("alloc: sizes={d} aligned64_ok={d} first=0x{x} last=0x{x}", .{
        want.len, ok, ptrs[0], ptrs[want.len - 1],
    });
    for (ptrs) |p| _ = heap.free(p);
    _ = heap.verify("after-align");
}

/// 碎片压测：随机大小、随机槽位反复分配/释放，并检查
///   - 每次操作后块链自洽（verify / verifyLists / verifyFlags）；
///   - 分配出去的内存块互不重叠（每块首字写哨兵，释放时比对）。
fn stressFragmentation(ops: usize) void {
    const slots = 32;
    var ptrs: [slots]usize = @splat(0);
    var marks: [slots]u32 = @splat(0);
    var seed: u32 = 0x00C0_FFEE;
    var peak_used: usize = 0;
    var overlaps: usize = 0;
    var corrupt: usize = 0;
    var ops_done: usize = 0;

    var i: usize = 0;
    while (i < ops) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223; // LCG，与主机侧单测同一条公式
        const slot = (seed >> 8) % slots;
        if (ptrs[slot] == 0) {
            const size = 16 + (seed >> 16) % 400;
            const p = heap.alloc(size) orelse continue;
            ptrs[slot] = p;
            marks[slot] = seed; // 本槽的"哨兵值"
            @as(*volatile u32, @ptrFromInt(p)).* = seed;
            ops_done += 1;
            const st = heap.arena.stats();
            if (st.used > peak_used) peak_used = st.used;
        } else {
            if (@as(*const volatile u32, @ptrFromInt(ptrs[slot])).* != marks[slot]) overlaps += 1;
            if (!heap.free(ptrs[slot])) corrupt += 1;
            ptrs[slot] = 0;
            ops_done += 1;
        }
        if (!heap.verify("stress")) {
            corrupt += 1;
            break;
        }
    }

    // 排空：全部释放后 arena 应当重新合并成极少几块
    for (ptrs) |p| _ = heap.free(p);
    const st = heap.arena.stats();
    log.line("frag: ops={d} peak_used={d} free={d} largest={d} blocks={d}", .{
        ops_done, peak_used, st.free, st.largest, st.free_blocks,
    });
    log.line("frag: overlap_hits={d} corrupt={d} ooms={d} frag={d}permille", .{
        overlaps, corrupt, st.ooms, if (st.free == 0) 0 else 1000 - st.free * 1000 / st.free,
    });
    _ = heap.verify("after-drain");
}

// ---------------------------------------------------------------------------
// 3) slab
// ---------------------------------------------------------------------------

var slab: slab_mod.Slab = undefined;

fn reportSlab() void {
    slab.init(&heap.arena);
    const demand = [_]usize{ 70, 40, 20, 8, 6 }; // 每个尺寸类的请求数（16/32/64/128/256）

    var held: [5][70]usize = @splat(@splat(0));
    var cls: usize = 0;
    while (cls < slab_mod.size_classes.len) : (cls += 1) {
        var k: usize = 0;
        while (k < demand[cls]) : (k += 1) {
            held[cls][k] = slab.alloc(slab_mod.size_classes[cls]) orelse 0;
        }
        // 每个类释放一半，再申请同样多，验证"复用而不是再借页"
        k = 0;
        while (k < demand[cls] / 2) : (k += 1) {
            _ = slab.free(held[cls][k]);
            held[cls][k] = 0;
        }
        k = 0;
        while (k < demand[cls] / 2) : (k += 1) {
            held[cls][k] = slab.alloc(slab_mod.size_classes[cls]) orelse 0;
        }
    }

    const st = slab.stats();
    cls = 0;
    while (cls < slab_mod.size_classes.len) : (cls += 1) {
        const c = st.classes[cls];
        log.line("slab: class={d:>3}B pages={d} slots={d} used={d} waste={d}B", .{
            c.slot_size, c.pages, c.slots, c.used, c.waste,
        });
    }
    log.line("slab: borrowed={d}B waste={d}B allocs={d} frees={d} ooms={d}", .{
        st.borrowed, st.waste, st.allocs, st.frees, st.ooms,
    });

    // 收尾：全部还回去（页不还给 TLSF，这是本章的既定策略）
    cls = 0;
    while (cls < slab_mod.size_classes.len) : (cls += 1) {
        var k: usize = 0;
        while (k < demand[cls]) : (k += 1) _ = slab.free(held[cls][k]);
    }
    const after = slab.stats();
    log.line("slab: after_release used_slots_total={d} borrowed={d}B (pages are kept)", .{
        after.classes[0].used + after.classes[1].used + after.classes[2].used +
            after.classes[3].used + after.classes[4].used,
        after.borrowed,
    });
}

// ---------------------------------------------------------------------------
// 4) 栈
// ---------------------------------------------------------------------------

fn reportStacks() void {
    stack.armMain();
    log.line("stack: main armed span={d}B fill=0x{x} canary=0x{x}", .{
        heap.stackRegion().high - heap.stackRegion().low, stack.fill_byte, stack.canary_word,
    });

    // 制造一点栈用量，让高水位不是 0（调用三层的临时占用）
    var sink: [256]u8 = @splat(0);
    var i: usize = 0;
    while (i < sink.len) : (i += 1) sink[i] = @truncate(i);
    if (sink[0] == 0xFF) log.raw("");

    stack.reportMain();

    // 模拟任务栈：先证明"好"的情况报 ok，再故意踩哨兵，必须报 overrun
    stack.armSim();
    log.line("stack: sim armed base=0x{x} len={d}B", .{ stack.simBase(), stack.simLen() });
    stack.reportSim("sim");

    const bad: u32 = 0x7856_3412;
    log.line("stack: sim simulate overrun -> write 0x{x} at 0x{x}", .{ bad, stack.simBase() });
    stack.simulateOverflow(bad);
    stack.reportSim("sim");
    if (!stack.checkSim()) log.raw("stack: sim overrun DETECTED (checker works)\n");

    stack.restoreSim();
    stack.reportSim("sim");
}

// ---------------------------------------------------------------------------
// 5) caps 拒绝
// ---------------------------------------------------------------------------

fn reportCapsRefusals() void {
    const ok_ptr = heap.allocCaps(.{ .bit8 = true, .internal = true }, 128) catch 0;
    log.line("caps: alloc(internal+8bit, 128)=0x{x} region={s}", .{ ok_ptr, caps.nameOf(ok_ptr) });
    _ = heap.free(ok_ptr);

    // 要 PSRAM：caps 表里有这个区间，但本章没接 arena —— 必须明确失败
    _ = heap.allocCaps(.{ .bit8 = true, .psram = true }, 1024) catch {};
    // 要 retention（只有 LP SRAM 满足）—— 同样没有 arena
    _ = heap.allocCaps(.{ .bit8 = true, .retention = true }, 64) catch {};
    // 要 exec + dma + internal 的组合：只有 SRAM 满足，应当成功
    const p = heap.allocCaps(.{ .exec = true, .dma = true, .internal = true }, 64) catch 0;
    log.line("caps: alloc(exec+dma+internal, 64)=0x{x}", .{p});
    _ = heap.free(p);
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub export fn main() noreturn {
    log.raw("ch13-heap-stack-caps | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.line("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)", .{});
    log.line("allocator: TLSF fl_shift={d} sl_log2={d} header={d}B min_block={d}B", .{
        5, 4, tlsf.block_header, tlsf.min_block,
    });

    heap.budget();
    reportSpaces();

    heap.init();
    heap.report("init");
    log.line("heap: verify={s}", .{if (heap.verify("init")) "ok" else "FAIL"});

    reportAlignment();
    stressFragmentation(2000);
    heap.report("after-frag");

    reportSlab();
    heap.report("after-slab");

    reportCapsRefusals();
    reportStacks();
    psram.report();

    heap.report("final");
    log.line("heap: verify={s} allocs={d} frees={d} ooms={d}", .{
        if (heap.verify("final")) "ok" else "FAIL",
        heap.arena.allocs,
        heap.arena.frees,
        heap.arena.ooms,
    });
    log.raw("lab: done (halt)\n");
    while (true) {
        asm volatile ("wfi");
    }
}
