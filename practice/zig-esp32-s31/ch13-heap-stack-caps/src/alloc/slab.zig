//! ch13-heap-stack-caps：slab 分配器（固定尺寸槽 + 位图）。
//!
//! 为什么在 TLSF 之上再加一层：TLSF 擅长"大小不一的请求"，但每次分配都要
//! 位图 + 链操作，且块头 16 字节对 16 字节的小对象是 100% 开销。实时系统里
//! 大量对象是**同一尺寸**的（节点、skb、队列元素），它们的分配应当只有
//! "找一个空位" 这一步——那就是位图的 `@ctz`。
//!
//! 结构：
//!
//!   class 0..4 ── 槽尺寸 16/32/64/128/256
//!        │
//!        ├── page 0  [1 KiB，切成 N 个槽，bitmap 记占用]
//!        ├── page 1  …
//!        └── page 3（每类最多 4 页）
//!
//! 页从 `heap.zig` 的 TLSF arena 里按 1 KiB 申请，所以"slab 与 TLSF 的
//! 关系"是真实的两层，而不是两套独立池子：slab 用光了 TLSF，TLSF 用光了
//! 就返回 null，谁都不越界。
//!
//! 本实现不把空页还给 TLSF。理由是抖动：一页还回去、下一轮再申请，位图与
//! 页表都要重写，而 1 KiB 的保留成本在 512 KiB SRAM 上是可接受的确定性。
//! 反过来，"永远留着"意味着预算必须按**峰值**报（见 `Stats`）。

const std = @import("std");
const tlsf = @import("tlsf.zig");

/// 支持的槽尺寸。第一个 ≥ 请求尺寸的类就是选中的类。
pub const size_classes = [_]usize{ 16, 32, 64, 128, 256 };

/// 每页字节数。1 KiB 让 16 字节类正好 64 槽（u64 位图），256 字节类 4 槽。
pub const page_bytes: usize = 1024;

/// 每个类最多几页。4 页 = 4 KiB/类，5 类共 20 KiB 上限。
pub const max_pages_per_class: usize = 4;

const Page = struct {
    base: usize = 0,
    /// 已用槽数（也等于位图里 1 的个数，但单独存省一次 popcount）。
    used: u16 = 0,
    /// 本页槽数。
    slots: u16 = 0,
    /// bit i = 第 i 个槽已分配。
    bitmap: u64 = 0,
};

pub const ClassStats = struct {
    slot_size: usize,
    pages: u32,
    slots: u32,
    used: u32,
    /// 页字节数减去"已用槽 × 槽尺寸" = 内部碎片（含位图浪费与未用槽）。
    waste: usize,
};

pub const Stats = struct {
    classes: [size_classes.len]ClassStats,
    /// 从 TLSF 借来的总字节数（= 页数 × page_bytes）。
    borrowed: usize,
    /// 内部碎片合计。
    waste: usize,
    allocs: u32,
    frees: u32,
    ooms: u32,
};

pub const Slab = struct {
    heap: *tlsf.Allocator,
    tables: [size_classes.len][max_pages_per_class]Page = @splat(@splat(.{})),
    page_count: [size_classes.len]u32 = @splat(0),
    borrowed: usize = 0,
    allocs: u32 = 0,
    frees: u32 = 0,
    ooms: u32 = 0,

    pub fn init(self: *Slab, heap: *tlsf.Allocator) void {
        self.* = .{ .heap = heap };
    }

    /// 请求尺寸 → 类号。超过最大类返回 null（请改用 heap.alloc）。
    pub fn classFor(size: usize) ?usize {
        for (size_classes, 0..) |s, i| {
            if (size <= s) return i;
        }
        return null;
    }

    /// 从 TLSF 借一页并登记到 `cls`。
    fn grow(self: *Slab, cls: usize) bool {
        if (self.page_count[cls] >= max_pages_per_class) return false;
        const raw = self.heap.allocAligned(page_bytes, 16) orelse return false;
        const slots: u16 = @intCast(page_bytes / size_classes[cls]);
        self.tables[cls][self.page_count[cls]] = .{
            .base = raw,
            .used = 0,
            .slots = slots,
            .bitmap = 0,
        };
        self.page_count[cls] += 1;
        self.borrowed += page_bytes;
        return true;
    }

    /// 分配一个 ≥ `size` 的槽。返回槽地址（按槽尺寸对齐，因为页按 16 对齐）。
    pub fn alloc(self: *Slab, size: usize) ?usize {
        if (size == 0) return null;
        const cls = classFor(size) orelse {
            self.ooms += 1;
            return null;
        };
        var attempt: u32 = 0;
        while (attempt < 2) : (attempt += 1) {
            const n = self.page_count[cls];
            var p: u32 = 0;
            while (p < n) : (p += 1) {
                const page = &self.tables[cls][p];
                if (page.slots >= 64) {
                    if (page.bitmap == ~@as(u64, 0)) continue;
                } else {
                    const full: u64 = (@as(u64, 1) << @intCast(page.slots)) - 1;
                    if (page.bitmap == full) continue;
                }
                const bit: u6 = @intCast(@ctz(~page.bitmap));
                page.bitmap |= @as(u64, 1) << bit;
                page.used += 1;
                self.allocs += 1;
                return page.base + @as(usize, bit) * size_classes[cls];
            }
            // 没有空位：借一页再试一次；借不到就是真 OOM。
            if (!self.grow(cls)) {
                self.ooms += 1;
                return null;
            }
        }
        self.ooms += 1;
        return null;
    }

    /// 释放一个槽。地址必须落在某个已知页里且按槽尺寸对齐——
    /// 否则返回 false（说明调用方传了别的池子的指针）。
    pub fn free(self: *Slab, ptr: usize) bool {
        if (ptr == 0) return true;
        var cls: usize = 0;
        while (cls < size_classes.len) : (cls += 1) {
            var p: u32 = 0;
            while (p < self.page_count[cls]) : (p += 1) {
                const page = &self.tables[cls][p];
                if (ptr < page.base or ptr >= page.base + page_bytes) continue;
                const off = ptr - page.base;
                if (off % size_classes[cls] != 0) return false;
                const bit: u6 = @intCast(off / size_classes[cls]);
                if (page.bitmap & (@as(u64, 1) << bit) == 0) return false; // 双重释放
                page.bitmap &= ~(@as(u64, 1) << bit);
                page.used -= 1;
                self.frees += 1;
                return true;
            }
        }
        return false;
    }

    pub fn stats(self: *Slab) Stats {
        var out: Stats = .{
            .classes = @splat(.{ .slot_size = 0, .pages = 0, .slots = 0, .used = 0, .waste = 0 }),
            .borrowed = self.borrowed,
            .waste = 0,
            .allocs = self.allocs,
            .frees = self.frees,
            .ooms = self.ooms,
        };
        for (size_classes, 0..) |sz, cls| {
            var used: u32 = 0;
            var slots: u32 = 0;
            var p: u32 = 0;
            while (p < self.page_count[cls]) : (p += 1) {
                used += self.tables[cls][p].used;
                slots += self.tables[cls][p].slots;
            }
            const pages = self.page_count[cls];
            out.classes[cls] = .{
                .slot_size = sz,
                .pages = pages,
                .slots = slots,
                .used = used,
                .waste = @as(usize, pages) * page_bytes - @as(usize, used) * sz,
            };
            out.waste += out.classes[cls].waste;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// 主机侧自测：`zig test src/alloc/slab.zig`
// ---------------------------------------------------------------------------

var test_arena: [16384]u8 align(16) = undefined;

test "slab 分页、复用与双重释放" {
    const t = std.testing;
    var heap: tlsf.Allocator = .{};
    heap.init(@intFromPtr(&test_arena), @intFromPtr(&test_arena) + test_arena.len);
    var s: Slab = undefined;
    s.init(&heap);

    // 16 字节类：一页 64 槽，先占满一页再触发第二页
    var ptrs: [70]usize = @splat(0);
    for (&ptrs) |*p| p.* = s.alloc(16) orelse return error.OutOfMemory;
    const st = s.stats();
    try t.expectEqual(@as(u32, 2), st.classes[0].pages);
    try t.expectEqual(@as(u32, 70), st.classes[0].used);

    // 释放一半后再分配，必须复用旧槽而不是再借页
    var i: usize = 0;
    while (i < 35) : (i += 1) try t.expect(s.free(ptrs[i]));
    const before = s.stats().classes[0].pages;
    const again = s.alloc(16) orelse return error.OutOfMemory;
    try t.expectEqual(before, s.stats().classes[0].pages);
    try t.expect(s.free(again));

    // 双重释放被拒绝
    try t.expect(!s.free(ptrs[0]));

    // 不认识的地址被拒绝（不是本页池的指针）
    try t.expect(!s.free(0x1234));
}
