//! ch13-heap-stack-caps：TLSF（Two-Level Segregated Fit）分配器。
//!
//! 为什么是 TLSF 而不是"第一次适应 + 空闲链"：TLSF 的分配与释放都是
//! **O(1) 上界**（两次位图 ctz + 常数次链表操作），最坏情况可分析——这是
//! 实时系统要的。代价是内部碎片与"按幂次分层"的索引开销。
//!
//! 结构（与 Masmano 等 2004 年的原始论文同一套两级索引）：
//!
//!   fl_bitmap       u32，bit i = 第 i 个一级类里有空闲块
//!   sl_bitmap[23]   u32，bit j = 该一级类的第 j 个二级类里有空闲块
//!   heads[23*16]    u32，每个 (fl, sl) 一条双向空闲链，存块的**地址**
//!
//! 一级索引 = floor(log2(size))，二级索引 = 该幂次内的线性细分：
//!
//!     sl = (size >> (fl - 4)) & 0xF          （SL_LOG2 = 4，每个 fl 细分 16 段）
//!
//! 于是"找一块 ≥ n 的空闲块"= 在 fl_bitmap 上找 ≥ fl 的最低位置位，再在
//! sl_bitmap 上找 ≥ sl 的最低位置位，取该链的表头。两次 `@ctz` + 一张表。
//!
//! 块布局（32 位地址空间，8 字节对齐）：
//!
//!       块地址 a ┌──────────────────────────┐
//!                │ size_and_flags  u32      │  size 含 16 字节头；低 3 位标志
//!                │ prev_phys       u32      │  前一个**物理**相邻块的地址
//!                │ next_free       u32      │  同一 (fl,sl) 链的下一个空闲块
//!                │ prev_free       u32      │  链上的前一个空闲块
//!      a + 16    ├──────────────────────────┤  ← alloc() 返回的指针
//!                │ payload …                │
//!                └──────────────────────────┘
//!
//! 标志位：FREE(bit0)、PREV_FREE(bit1)、LAST(bit2)。`LAST` 标记 arena 的最后
//! 一块——没有它，后继块的 `prev_phys` 会把读操作带到 arena 外面去。
//!
//! 与本系列其他模块的关系：本文件不 `@import` 任何硬件/打印模块，纯粹是
//! 数据结构。arena 由调用方给出（`heap.zig` 用 `_heap_start/_heap_end`），
//! 因此同一份代码可以在主机侧对着一块 `[4*1024]u8` 数组跑 `zig test`。

const std = @import("std");

/// 最小对齐：所有块地址与块长度都是它的倍数。
pub const align_size: usize = 8;

/// 块头字节数：4 个机器字。rv32 上 16 字节，主机侧（64 位）自动变 32 字节——
/// 由类型推导，不硬编码，因此同一份代码能在主机上跑 `zig test`。
pub const block_header: usize = 4 * @sizeOf(usize);

/// 最小块：16 字节头 + 16 字节载荷。再小就没有意义——合并后仍然是它。
pub const min_block: usize = block_header + 16;

/// 一级索引的起点：小于 2^5 = 32 字节的块全部落在 fl=0。
const fl_shift: u5 = 5;

/// 每个一级类细分 2^4 = 16 段。
const sl_log2: u4 = 4;
const sl_count: usize = 1 << sl_log2;

/// 一级索引上限：2^22 = 4 MiB。S31 的整个 SRAM 只有 512 KiB，留足余量。
const fl_max: u5 = 22;
const fl_count: usize = fl_max + 1;

/// 单个分配请求的上限（超过就没有对应的索引类）。
pub const max_alloc: usize = @as(usize, 1) << fl_max;

const ones: u32 = 0xFFFF_FFFF;

const FREE: usize = 1;
const PREV_FREE: usize = 2;
const LAST: usize = 4;
const FLAG_MASK: usize = FREE | PREV_FREE | LAST;

const Block = extern struct {
    size_and_flags: usize,
    prev_phys: usize,
    next_free: usize,
    prev_free: usize,
};

comptime {
    if (@sizeOf(Block) != block_header) @compileError("Block 头必须是 16 字节");
    if (min_block % align_size != 0) @compileError("min_block 必须是 8 的倍数");
}

/// 统计快照。`frag` 由调用方按 `1 - largest/free` 算，这里只给原始量。
pub const Stats = struct {
    arena: usize,
    used: usize,
    free: usize,
    largest: usize,
    free_blocks: u32,
    allocs: u32,
    frees: u32,
    ooms: u32,
};

/// (fl, sl) 二元组。
const Class = struct { fl: u5, sl: u4 };

pub const Allocator = struct {
    base: usize = 0,
    end: usize = 0,
    fl_bitmap: u32 = 0,
    sl_bitmap: [fl_count]u32 = @splat(0),
    /// 每个 (fl,sl) 的空闲链表头（块地址，0 = 空链）。
    heads: [fl_count * sl_count]usize = @splat(0),
    used: usize = 0,
    free_bytes: usize = 0,
    free_blocks: u32 = 0,
    allocs: u32 = 0,
    frees: u32 = 0,
    ooms: u32 = 0,

    // ---------------------------------------------------------------- 初始化

    /// 把 [start, end) 变成一块空闲区并挂到对应类上。
    /// `start` 会被向上对齐到 8 字节；长度向下取整到 8 的倍数。
    pub fn init(self: *Allocator, start_in: usize, end: usize) void {
        var start = start_in;
        if (start % align_size != 0) start += align_size - start % align_size;
        if (end <= start) {
            self.* = .{};
            return;
        }
        var len = (end - start) & ~(align_size - 1);
        self.* = .{ .base = start, .end = start + len };
        if (len < min_block) {
            // arena 太小：退化成"永远分配失败"的合法状态，而不是崩溃。
            self.end = start;
            return;
        }
        len = self.end - start;
        writeHeader(start, len, false, false, true);
        at(start).prev_phys = 0;
        at(start).next_free = 0;
        at(start).prev_free = 0;
        self.insert(start);
    }

    pub fn initialized(self: *const Allocator) bool {
        return self.end > self.base;
    }

    // -------------------------------------------------------------- 块访问器

    inline fn sizeOf(a: usize) usize {
        return @as(usize, at(a).size_and_flags & ~FLAG_MASK);
    }

    inline fn testFlag(a: usize, f: usize) bool {
        return (at(a).size_and_flags & f) != 0;
    }

    inline fn setFlag(a: usize, f: usize, on: bool) void {
        if (on) {
            at(a).size_and_flags |= f;
        } else {
            at(a).size_and_flags &= ~f;
        }
    }

    inline fn writeHeader(a: usize, size: usize, is_free: bool, prev_free: bool, last: bool) void {
        var v: usize = size;
        if (is_free) v |= FREE;
        if (prev_free) v |= PREV_FREE;
        if (last) v |= LAST;
        at(a).size_and_flags = v;
    }

    // ------------------------------------------------------------ 两级索引

    /// 尺寸 → (fl, sl)。size < 32 时 fl=0，sl = size/2（0..15）。
    pub fn mapping(size: usize) Class {
        if (size < (@as(usize, 1) << fl_shift)) {
            return .{ .fl = 0, .sl = @intCast(size >> 1) };
        }
        const v: u32 = @intCast(size);
        const fl: u5 = @intCast(31 - @clz(v));
        const sl: u4 = @intCast((size >> (fl - sl_log2)) & (sl_count - 1));
        return .{ .fl = fl, .sl = sl };
    }

    inline fn listIndex(c: Class) usize {
        return @as(usize, c.fl) * sl_count + @as(usize, c.sl);
    }

    // ------------------------------------------------------------ 空闲链

    fn insert(self: *Allocator, a: usize) void {
        const c = mapping(sizeOf(a));
        const idx = listIndex(c);
        const head = self.heads[idx];
        at(a).next_free = head;
        at(a).prev_free = 0;
        if (head != 0) at(head).prev_free = a;
        self.heads[idx] = a;
        self.fl_bitmap |= @as(u32, 1) << c.fl;
        self.sl_bitmap[c.fl] |= @as(u32, 1) << c.sl;
        setFlag(a, FREE, true);
        self.free_bytes += sizeOf(a) - block_header;
        self.free_blocks += 1;
    }

    fn remove(self: *Allocator, a: usize) void {
        const c = mapping(sizeOf(a));
        const idx = listIndex(c);
        const nf = at(a).next_free;
        const pf = at(a).prev_free;

        if (pf != 0) {
            at(pf).next_free = nf;
        } else {
            self.heads[idx] = nf;
        }
        if (nf != 0) at(nf).prev_free = pf;

        if (self.heads[idx] == 0) {
            self.sl_bitmap[c.fl] &= ~(@as(u32, 1) << c.sl);
            if (self.sl_bitmap[c.fl] == 0) self.fl_bitmap &= ~(@as(u32, 1) << c.fl);
        }

        self.free_bytes -= sizeOf(a) - block_header;
        self.free_blocks -= 1;
        setFlag(a, FREE, false);
        at(a).next_free = 0;
        at(a).prev_free = 0;
    }

    /// 找一块 ≥ `size` 的空闲块（不摘链）。返回块地址。
    ///
    /// 与原始 TLSF 的差别：论文里可以断言"同 (fl,sl) 的块都 ≥ 请求"，因为它的
    /// 最小块与细分粒度让一个类里只有一个尺寸。本实现 8 字节对齐、min_block 是
    /// 32，同一个 (fl,sl) 里可能同时躺着 512 和 520，所以必须沿链找第一块真正
    /// 放得下的。代价是链长，不是 O(1) 的破坏：每个类里的尺寸种类上界是
    /// `2^fl / 16 / 8`。
    fn findFit(self: *Allocator, size: usize) ?usize {
        const want = mapping(size);
        var fl_map = self.fl_bitmap & (ones << want.fl);
        while (fl_map != 0) {
            const fl: u5 = @intCast(@ctz(fl_map));
            var sl_map = self.sl_bitmap[fl];
            if (fl == want.fl) sl_map &= (ones << want.sl);
            while (sl_map != 0) {
                const sl: u4 = @intCast(@ctz(sl_map));
                var cur = self.heads[@as(usize, fl) * sl_count + sl];
                while (cur != 0) {
                    if (sizeOf(cur) >= size) return cur;
                    cur = at(cur).next_free;
                }
                sl_map &= sl_map - 1;
            }
            fl_map &= fl_map - 1;
        }
        return null;
    }

    // ---------------------------------------------------------------- 分配

    /// 分配 `size` 字节，按 8 字节对齐。失败返回 null（不 panic：调用方决定）。
    pub fn alloc(self: *Allocator, size: usize) ?usize {
        return self.allocAligned(size, align_size);
    }

    /// 分配 `size` 字节，payload 按 `alignment` 对齐（alignment 必须是 8 的倍数）。
    ///
    /// 对齐的做法是"多要一点、把前面切掉"：切下来的前段如果 ≥ min_block 就变成
    /// 独立空闲块，否则（比如只差 8 字节）连它一起吞进对齐间隙。因此按 64 字节
    /// 对齐的分配，最坏会多搜索 `alignment + min_block` 字节。
    pub fn allocAligned(self: *Allocator, size: usize, alignment: usize) ?usize {
        if (size == 0 or size > max_alloc) return null;
        const trunc = alignment - (alignment % align_size);
        const use_align = if (trunc < align_size) align_size else trunc;

        // need 是**整块**字节数（头 + payload），blk_size 与 want 都用它算。
        // 曾经把 need 当 payload、want 再 +header，遇到小请求时块长只有 24 字节
        // 而块头本身就要 32 字节 —— 写 next_free 会踩到下个块的 size 字段。
        const payload = alignUp(@max(size, min_block - block_header), align_size);
        const need = block_header + payload;
        // 对齐间隙上界：最坏 shift0 = use_align - 8，再抬一次 use_align 才够 min_block。
        const reserve: usize = if (use_align > align_size) 2 * use_align + min_block else 0;
        const want = need + reserve;

        const a = self.findFit(want) orelse {
            self.ooms += 1;
            return null;
        };
        self.remove(a);

        const bsize = sizeOf(a);
        const was_last = testFlag(a, LAST);
        const was_prev_free = testFlag(a, PREV_FREE);
        const prev_phys = at(a).prev_phys;

        // 1) 对齐间隙
        var shift: usize = 0;
        const payload0 = a + block_header;
        if (payload0 % use_align != 0) {
            shift = use_align - (payload0 % use_align);
            // 前段太小就做不成独立块：按**对齐粒度**抬到下一个对齐点
            // （+min_block 会破坏对齐，必须加 use_align 的整数倍）。
            if (shift < min_block) {
                const steps = (min_block - shift + use_align - 1) / use_align;
                shift += steps * use_align;
            }
        }
        const blk_addr = a + shift;
        const room = bsize - shift;

        // 2) 尾部：够一块就切出去，并挂进空闲链
        var blk_size = room;
        var has_tail = false;
        if (room - need >= min_block) {
            blk_size = need;
            has_tail = true;
            const t = blk_addr + blk_size;
            // tail 的前一个物理块正是本次被分配掉的块 → PREV_FREE 必须为 0。
            writeHeader(t, room - need, false, false, was_last);
            at(t).prev_phys = blk_addr;
            at(t).next_free = 0;
            at(t).prev_free = 0;
            self.insert(t);
        }

        // 3) 前段空闲块（如果存在）
        const has_front = shift >= min_block;
        if (has_front) {
            writeHeader(a, shift, false, was_prev_free, false);
            at(a).prev_phys = prev_phys;
            at(a).next_free = 0;
            at(a).prev_free = 0;
        }

        // 4) 本次分配块的块头
        writeHeader(blk_addr, blk_size, false, has_front or was_prev_free, !has_tail and was_last);
        at(blk_addr).prev_phys = if (has_front) a else prev_phys;
        at(blk_addr).next_free = 0;
        at(blk_addr).prev_free = 0;

        if (has_front) self.insert(a);

        // 5) 物理后继块回指本链的**最后一块**（可能是 tail）
        if (!was_last) {
            const succ = a + bsize;
            // 物理后继块必须回指本段内存的**最后一块**：切出 tail 时是 tail，
            // 没切出 tail 时（容差被本次分配吞掉）就是 blk_addr 自己。
            const last_block = if (has_tail) blk_addr + blk_size else blk_addr;
            at(succ).prev_phys = last_block;
            // 切出 tail 时后邻的前一块就是 tail（空闲）；吞掉容差时前一块是本次分配。
            setFlag(succ, PREV_FREE, has_tail);
        }

        self.used += blk_size;
        self.allocs += 1;
        return blk_addr + block_header;
    }

    // ---------------------------------------------------------------- 释放

    /// 释放 `alloc` 返回的指针。地址不在 arena 内、未对齐、或块已标记空闲
    /// （双重释放）→ 返回 false，让调用方能打印现场而不是直接复位。
    pub fn free(self: *Allocator, ptr: usize) bool {
        if (ptr == 0) return true;
        if (ptr < self.base + block_header or ptr >= self.end) return false;
        const a0 = ptr - block_header;
        if (a0 % align_size != 0) return false;
        if (testFlag(a0, FREE)) return false;

        const prev_free_flag = testFlag(a0, PREV_FREE);
        const a0_prev_phys = at(a0).prev_phys;
        var last = testFlag(a0, LAST);
        const own = sizeOf(a0); // 本块（已分配）的字节数，`used` 只减这么多
        var total = own;

        // 与后邻合并
        if (!last) {
            const n = a0 + total;
            if (testFlag(n, FREE)) {
                total += sizeOf(n);
                last = testFlag(n, LAST);
                self.remove(n);
            }
        }

        // 与前邻合并。合并后的块头是前邻，它的 prev_phys 是前邻的前邻。
        var a = a0;
        var new_prev_phys = a0_prev_phys;
        var new_prev_free = prev_free_flag;
        if (prev_free_flag) {
            const p = a0_prev_phys;
            new_prev_phys = at(p).prev_phys;
            new_prev_free = testFlag(p, PREV_FREE);
            total += sizeOf(p);
            self.remove(p);
            a = p;
        }

        writeHeader(a, total, false, new_prev_free, last);
        at(a).prev_phys = new_prev_phys;
        at(a).next_free = 0;
        at(a).prev_free = 0;

        if (!last) {
            const succ = a + total;
            at(succ).prev_phys = a;
            setFlag(succ, PREV_FREE, true);
        }

        self.used -= own;
        self.frees += 1;
        self.insert(a);
        return true;
    }

    /// 重新分配：新块拷旧内容。旧块大小从块头读，因此调用方不必记账。
    pub fn realloc(self: *Allocator, ptr: usize, size: usize) ?usize {
        if (ptr == 0) return self.alloc(size);
        const old = sizeOf(ptr - block_header) - block_header;
        if (size <= old) return ptr; // 不缩小：缩小带来的碎片比浪费更糟
        const np = self.alloc(size) orelse return null;
        var i: usize = 0;
        while (i < old) : (i += 1) {
            @as(*u8, @ptrFromInt(np + i)).* = @as(*const u8, @ptrFromInt(ptr + i)).*;
        }
        _ = self.free(ptr);
        return np;
    }

    // ---------------------------------------------------------------- 统计

    pub fn stats(self: *Allocator) Stats {
        var largest: usize = 0;
        var idx: usize = 0;
        while (idx < fl_count * sl_count) : (idx += 1) {
            var cur = self.heads[idx];
            while (cur != 0) {
                const s = sizeOf(cur);
                if (s > largest) largest = s - block_header;
                cur = at(cur).next_free;
            }
        }
        return .{
            .arena = self.end - self.base,
            .used = self.used,
            .free = self.free_bytes,
            .largest = largest,
            .free_blocks = self.free_blocks,
            .allocs = self.allocs,
            .frees = self.frees,
            .ooms = self.ooms,
        };
    }

    /// 结构自检：从 arena 头逐块走，检查尺寸合法、物理相邻、恰好走到 end。
    /// 返回 false 表示块头被踩坏（碎片压测每轮都调它）。
    pub fn verify(self: *Allocator) bool {
        if (!self.initialized()) return true;
        var a = self.base;
        var guard: usize = 0;
        const max_blocks = (self.end - self.base) / min_block + 8;
        while (true) {
            guard += 1;
            if (guard > max_blocks) return false;
            if (a < self.base or a + block_header > self.end) return false;
            const s = sizeOf(a);
            if (s < min_block or s % align_size != 0) return false;
            if (a + s > self.end) return false;
            if (testFlag(a, LAST)) return a + s == self.end;
            a += s;
        }
    }

    /// PREV_FREE 标志必须与"前一个物理块是否空闲"一致，且后邻的 prev_phys
    /// 必须指回本块。合并只依赖这两个字段，它们错了就是"泄漏的碎片"。
    pub fn verifyFlags(self: *Allocator) bool {
        if (!self.initialized()) return true;
        var a = self.base;
        var prev: usize = 0;
        var guard: usize = 0;
        while (true) {
            guard += 1;
            if (guard > (self.end - self.base) / min_block + 8) return false;
            const s = sizeOf(a);
            if (s < min_block) return false;
            if (prev == 0) {
                if (testFlag(a, PREV_FREE)) return false;
            } else {
                if (testFlag(a, PREV_FREE) != testFlag(prev, FREE)) return false;
                if (at(a).prev_phys != prev) return false;
            }
            const last = testFlag(a, LAST);
            prev = a;
            a += s;
            if (last) return a == self.end;
        }
    }

    /// 空闲链自洽：每个 (fl,sl) 里的块必须真的 free，且尺寸真的属于该类。
    pub fn verifyLists(self: *Allocator) bool {
        var idx: usize = 0;
        while (idx < fl_count * sl_count) : (idx += 1) {
            var cur = self.heads[idx];
            var guard: usize = 0;
            while (cur != 0) {
                guard += 1;
                if (guard > 4096) return false;
                if (!testFlag(cur, FREE)) return false;
                const c = mapping(sizeOf(cur));
                if (listIndex(c) != idx) return false;
                cur = at(cur).next_free;
            }
        }
        return true;
    }
};

inline fn at(a: usize) *Block {
    return @ptrFromInt(a);
}

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) & ~(a - 1);
}

// ---------------------------------------------------------------------------
// 主机侧自测（`zig test src/alloc/tlsf.zig`，x86_64 下跑）
//
// test 块只在测试构建里展开，不影响 riscv32 目标产物。
// ---------------------------------------------------------------------------

/// 只在测试里用：把块链打印出来（verify 失败时定位用）。
fn dumpLayout(self: *Allocator) void {
    var a = self.base;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const sz = Allocator.sizeOf(a);
        std.debug.print("  blk 0x{x} raw=0x{x} size={d} free={} prevfree={} last={} prev=0x{x}\n", .{
            a,                                                     at(a).size_and_flags,
            sz,                                                    Allocator.testFlag(a, FREE),
            Allocator.testFlag(a, PREV_FREE),                      Allocator.testFlag(a, LAST),
            at(a).prev_phys,
        });
        if (sz == 0 or Allocator.testFlag(a, LAST)) break;
        a += sz;
    }
}

/// 主机侧 arena：放在全局而不是测试函数的栈上，避免 printf 的栈缓冲与它相邻。
var host_arena: [16384]u8 align(16) = undefined;

fn freshArena(len: usize) Allocator {
    var a: Allocator = .{};
    a.init(@intFromPtr(&host_arena), @intFromPtr(&host_arena) + len);
    return a;
}

test "alloc/free 基本路径与全量合并" {
    const t = std.testing;
    var a = freshArena(4096);
    try t.expect(a.initialized());

    const p1 = a.alloc(100) orelse return error.OutOfMemory;
    const p2 = a.alloc(200) orelse return error.OutOfMemory;
    try t.expect(p1 % 8 == 0 and p2 % 8 == 0);
    try t.expect(p1 != p2);
    if (!a.verify()) {
        dumpLayout(&a);
        return error.TestUnexpectedResult;
    }

    try t.expect(a.free(p2));
    try t.expect(a.free(p1));
    try t.expect(a.verify());
    try t.expect(a.verifyLists());

    // 两次释放后应当合并成一整块
    const st = a.stats();
    try t.expectEqual(@as(u32, 1), st.free_blocks);
    try t.expectEqual(@as(usize, 4096 - block_header), st.largest);
}

test "对齐分配" {
    const t = std.testing;
    var a = freshArena(8192);

    const sizes = [_]usize{ 17, 64, 65, 1000, 4096 };
    var ptrs: [sizes.len]usize = @splat(0);
    for (sizes, 0..) |n, i| {
        ptrs[i] = a.allocAligned(n, 64) orelse return error.OutOfMemory;
        if (!a.verify()) {
            std.debug.print("verify failed after alloc({d}) align 64\n", .{n});
            dumpLayout(&a);
            return error.TestUnexpectedResult;
        }
        try t.expect(ptrs[i] % 64 == 0);
    }
    for (ptrs) |p| try t.expect(a.free(p));
    try t.expect(a.verify());
    try t.expect(a.verifyLists());
}

test "耗尽后返回 null 而不是越界" {
    const t = std.testing;
    var a = freshArena(512);
    var n: usize = 0;
    while (a.alloc(64) != null) n += 1;
    try t.expect(n > 0);
    try t.expect(a.verify());
    try t.expect(a.verifyLists());
    try t.expect(a.stats().ooms > 0);
}

test "双重释放被拒绝" {
    const t = std.testing;
    var a = freshArena(1024);
    const p = a.alloc(64) orelse return error.OutOfMemory;
    try t.expect(a.free(p));
    try t.expect(!a.free(p));
    try t.expect(a.verify());
}

test "随机压力：每步都自检" {
    const t = std.testing;
    var a = freshArena(8192);

    var slots: [16]usize = @splat(0);
    var seed: u32 = 0x1234_5678;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        // LCG：与固件里碎片压测用的是同一条公式
        seed = seed *% 1664525 +% 1013904223;
        const slot = (seed >> 8) % slots.len;
        if (slots[slot] == 0) {
            const size = 16 + (seed >> 16) % 400;
            slots[slot] = a.alloc(size) orelse 0;
        } else {
            _ = a.free(slots[slot]);
            slots[slot] = 0;
        }
        if (!a.verify() or !a.verifyLists() or !a.verifyFlags()) {
            std.debug.print("损坏于第 {d} 步（seed=0x{x}）\n", .{ i, seed });
            dumpLayout(&a);
            return error.TestUnexpectedResult;
        }
    }
    for (slots) |p| _ = a.free(p);
    try t.expect(a.verify());
    const st = a.stats();
    // 全部释放后 arena 应重新合并成很少的几块
    try t.expect(st.free_blocks <= 2);
}
