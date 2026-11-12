//! ch18-ipv4-icmp-arp-routing：IPv4 首部、分片与重组、PMTU 缓存。
//!
//! 与 ch16 的 `headers.zig` 的分工：
//!
//!   - ch16 只做"把 20 字节变成值、把值写成 20 字节"，外加严格校验；
//!     它刻意不碰分片、不碰路由、不持有任何状态。
//!   - 本章再加三件事：**分片**（把超 MTU 的数据报切成合法片）、
//!     **重组**（把乱序/重复/重叠的片拼回来）、**PMTU**（记住对端路径的
//!     最小 MTU，避免反复把 DF 包打出去再被 ICMP 打回来）。
//!
//! 为什么不 import ch16 的 `headers.zig`：`zig build` 的根模块只包含本工程
//! 的 `src/`，跨工程引用要么复制路径（隐式依赖别人的目录布局），要么在
//! `build.zig` 里挂一个 `../ch16-...` 的模块（这一章就不能单独拷走）。本章的
//! 取舍是**每个工程自带一份最小实现**，接口边界写在章节 18.3。
//!
//! ## 首部里最容易写错的三个字段
//!
//! 1. `IHL` 以 **4 字节**为单位：`ihl=5` 才是 20 字节；不是"字节数 / 4"之外的任何东西。
//! 2. 标志位与片偏移共用一个 16 位字：`bit15..13` 是 flags（reserved/DF/MF），
//!    `bit12..0` 是**以 8 字节为单位**的片偏移。因此除最后一片外，载荷长度
//!    必须是 8 的倍数——这也解释了为什么分片大小要向下取整到 8。
//! 3. `total_length` 是**首部 + 载荷**，包含本片自己的 20 字节；不是载荷长度。

const std = @import("std");
const inet = @import("inet.zig");

pub const min_header_len = 20;
pub const max_header_len = 60;
pub const min_payload_for_fragment = 8; // RFC 791：除最后一片外，片载荷是 8 字节的倍数

/// 协议号（IP protocol field）。只列本章用到的三个。
pub const proto = struct {
    pub const icmp: u8 = 1;
    pub const tcp: u8 = 6;
    pub const udp: u8 = 17;
};

pub const Error = error{
    Truncated,
    BadVersion,
    BadIhl,
    BadTotalLength,
    BadChecksum,
    ShortBuffer,
    MtuTooSmall,
    DfSet,
    UnsupportedOptions,
};

// ---------------------------------------------------------------------------
// 首部
// ---------------------------------------------------------------------------

/// IPv4 首部（值语义，不持有缓冲区）。选项不建模：解析时允许 `ihl > 5`
/// 并跳过；生成时只写 20 字节固定首部，分片时拒绝带选项的数据报。
pub const Header = struct {
    version: u4 = 4,
    ihl: u4 = 5,
    dscp: u6 = 0,
    ecn: u2 = 0,
    total_len: u16 = min_header_len,
    id: u16 = 0,
    df: bool = false,
    mf: bool = false,
    /// 以 8 字节为单位（RFC 791 的 fragment offset 语义）。
    frag_offset: u13 = 0,
    ttl: u8 = 64,
    protocol: u8 = 0,
    /// `write` 回填的校验和；`parse` 原样读出。
    checksum: u16 = 0,
    src: inet.Addr = inet.any,
    dst: inet.Addr = inet.any,

    pub fn headerLen(self: Header) usize {
        return @as(usize, self.ihl) * 4;
    }

    pub fn payloadLen(self: Header) usize {
        return @as(usize, self.total_len) - self.headerLen();
    }

    pub fn offsetBytes(self: Header) usize {
        return @as(usize, self.frag_offset) * 8;
    }

    pub fn isFragmented(self: Header) bool {
        return self.mf or self.frag_offset != 0;
    }

    /// 写 20 字节固定首部并回填校验和。选项由调用方自行追加（本章不生成）。
    pub fn write(self: *Header, buf: []u8) Error!usize {
        if (buf.len < min_header_len) return error.ShortBuffer;
        self.version = 4;
        self.ihl = 5;
        encode(self.*, buf);
        self.checksum = inet.of(buf[0..min_header_len]);
        std.mem.writeInt(u16, buf[10..12], self.checksum, .big);
        return min_header_len;
    }

    /// 严格解析：版本、IHL、总长与缓冲区长度四项必须自洽。
    /// 校验和**不**在这里验证（错误包也可能需要计数上报）；用 `parseChecked`。
    pub fn parse(buf: []const u8) Error!Header {
        if (buf.len < min_header_len) return error.Truncated;
        if (buf[0] >> 4 != 4) return error.BadVersion;
        const ihl: u4 = @intCast(buf[0] & 0x0F);
        if (ihl < 5) return error.BadIhl;
        const hlen = @as(usize, ihl) * 4;
        if (buf.len < hlen) return error.Truncated;

        const total_len = std.mem.readInt(u16, buf[2..4], .big);
        if (total_len < hlen) return error.BadTotalLength;
        if (total_len > buf.len) return error.Truncated;

        const flags_offset = std.mem.readInt(u16, buf[6..8], .big);
        return .{
            .version = 4,
            .ihl = ihl,
            .dscp = @intCast(buf[1] >> 2),
            .ecn = @intCast(buf[1] & 0x03),
            .total_len = total_len,
            .id = std.mem.readInt(u16, buf[4..6], .big),
            .df = (flags_offset & 0x4000) != 0,
            .mf = (flags_offset & 0x2000) != 0,
            .frag_offset = @intCast(flags_offset & 0x1FFF),
            .ttl = buf[8],
            .protocol = buf[9],
            .checksum = std.mem.readInt(u16, buf[10..12], .big),
            .src = buf[12..16].*,
            .dst = buf[16..20].*,
        };
    }

    pub fn parseChecked(buf: []const u8) Error!Header {
        const h = try parse(buf);
        if (!inet.verify(buf[0..h.headerLen()])) return error.BadChecksum;
        return h;
    }

    /// 载荷视图（零拷贝）：`buf[hdr..total]`。
    pub fn payload(self: Header, buf: []const u8) Error![]const u8 {
        const hlen = self.headerLen();
        if (buf.len < self.total_len) return error.Truncated;
        return buf[hlen..self.total_len];
    }
};

fn encode(h: Header, buf: []u8) void {
    buf[0] = (@as(u8, h.version) << 4) | @as(u8, h.ihl);
    buf[1] = (@as(u8, h.dscp) << 2) | @as(u8, h.ecn);
    std.mem.writeInt(u16, buf[2..4], h.total_len, .big);
    std.mem.writeInt(u16, buf[4..6], h.id, .big);
    var flags_offset: u16 = @as(u16, h.frag_offset);
    if (h.df) flags_offset |= 0x4000;
    if (h.mf) flags_offset |= 0x2000;
    std.mem.writeInt(u16, buf[6..8], flags_offset, .big);
    buf[8] = h.ttl;
    buf[9] = h.protocol;
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    buf[12..16].* = h.src;
    buf[16..20].* = h.dst;
}

/// 就地重算 20 字节首部的校验和（分片改写 offset/MF/total 之后必须调用）。
pub fn recomputeChecksum(buf: []u8) void {
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    std.mem.writeInt(u16, buf[10..12], inet.of(buf[0..min_header_len]), .big);
}

// ---------------------------------------------------------------------------
// 分片
// ---------------------------------------------------------------------------

pub const Fragment = struct {
    buf: []u8,
    len: usize,
};

/// 每片的载荷上限：`(mtu - 首部长) / 8 * 8`。除最后一片外都必须是 8 的倍数。
pub fn fragmentChunk(mtu: usize, header_len: usize) Error!usize {
    if (mtu < header_len + min_payload_for_fragment) return error.MtuTooSmall;
    return ((mtu - header_len) / 8) * 8;
}

/// 载荷 `payload_len` 字节、路径 MTU 为 `mtu` 时需要几片（含最后一片）。
pub fn fragmentsNeeded(payload_len: usize, mtu: usize, header_len: usize) Error!usize {
    const chunk = try fragmentChunk(mtu, header_len);
    if (payload_len == 0) return 1;
    return (payload_len + chunk - 1) / chunk;
}

/// 把 `datagram`（完整 IPv4 报文）按 `mtu` 切分，逐片写入 `out`。
/// 返回写入的片数；`out` 不够长时返回 `error.ShortBuffer` 且**不**回滚
/// （已经写出的片由调用方丢弃——它们还没发出去）。
///
/// 片首部的 `id` 保持不变；`df` 被清掉（df=1 的包不允许分片，见 `error.DfSet`）；
/// `mf` 除最后一片外为 1；`frag_offset` 以 8 字节为单位递增。
pub fn fragment(datagram: []const u8, mtu: usize, out: []Fragment) Error!usize {
    const h = try Header.parseChecked(datagram);
    if (h.df) return error.DfSet;
    if (h.ihl != 5) return error.UnsupportedOptions;

    const hlen = h.headerLen();
    const payload = try h.payload(datagram);
    const chunk = try fragmentChunk(mtu, hlen);
    if (chunk == 0) return error.MtuTooSmall;

    var off: usize = 0;
    var idx: usize = 0;
    while (true) {
        if (idx >= out.len) return error.ShortBuffer;
        const remaining = payload.len - off;
        const take = @min(chunk, remaining);
        const last = off + take == payload.len;

        const f = &out[idx];
        if (f.buf.len < hlen + take) return error.ShortBuffer;

        var part = h;
        part.total_len = @intCast(hlen + take);
        part.df = false;
        part.mf = !last;
        part.frag_offset = @intCast(off / 8);
        part.checksum = 0;
        encode(part, f.buf[0..hlen]);
        recomputeChecksum(f.buf[0..hlen]);
        if (take > 0) @memcpy(f.buf[hlen .. hlen + take], payload[off .. off + take]);
        f.len = hlen + take;

        off += take;
        idx += 1;
        if (last) break;
    }
    return idx;
}

// ---------------------------------------------------------------------------
// 重组
// ---------------------------------------------------------------------------

pub const ReasmKey = struct {
    src: inet.Addr,
    dst: inet.Addr,
    id: u16,
    protocol: u8,
};

pub const ReasmError = error{
    UnsupportedOptions,
    BadLength,
    OverlapConflict,
    TooLarge,
    TooManyRanges,
    /// 没有挂上重组缓冲（见 `Reasm.attach`）。
    NoStorage,
} || Error;

/// 有界重组器：`capacity` 个槽，每槽最多 `max_datagram` 字节载荷。
///
/// 为什么要有界：无界重组表是经典的内存耗尽向量（RFC 6274 §4.1、RFC 1858）。
/// 这里的策略是"槽满时踢掉最久未更新的槽"，并把踢掉的次数计入 `stats.evicted`——
/// 这个计数是判断"是否在被分片洪水打"的第一个指标。
pub const Reasm = struct {
    pub const capacity = 2;
    /// 每槽的字节数：20 字节首部 + 最大载荷。
    pub const stride = min_header_len + max_datagram;
    /// 单个数据报的重组上限（载荷字节）。刻意大于 1500：上游链路 MTU 比本地
    /// 小时（例如 1280 的 PPPoE 或 576 的老路由），片总长仍是原始数据报的长度。
    /// 上限的存在是为了给"分片洪水"一个硬边界——每个槽的缓冲在 `.bss` 里，
    /// 不随输入增长。
    pub const max_datagram = 3000;
    pub const max_ranges = 8;
    /// RFC 1122 §3.3.2 要求必须有重组超时，推荐 60–120 s；Linux 默认 30 s
    ///（`net.ipv4.ipfrag_time`）。这里取 30 s，方便与主机抓包对照。
    pub const timeout_ms = 30_000;

    pub const Outcome = union(enum) {
        /// 还缺片；附上当前已覆盖的字节数（判读用）。
        accepted: usize,
        /// 完全重复的一片；缓存未被改写，等待其它片。
        duplicate,
        /// 组装完成：切片指向槽内缓冲（`首部 + 完整载荷`），
        /// **有效期到下一次 `insert`/`expire`**。上层必须同步消费。
        complete: []const u8,
    };

    pub const Stats = struct {
        inserted: u32 = 0,
        duplicates: u32 = 0,
        completed: u32 = 0,
        expired: u32 = 0,
        evicted: u32 = 0,
        failed: u32 = 0,
    };

    const Range = struct { start: usize, end: usize };

    /// 槽里的**元数据**。字节缓冲单独放在 `storage` 里：把 `[1520]u8` 放进
    /// 可 `@splat` 的结构会让 `Reasm{}` 变成"在编译期展开 3 KB"，既慢又没必要。
    const Slot = struct {
        used: bool = false,
        key: ReasmKey = .{ .src = inet.any, .dst = inet.any, .id = 0, .protocol = 0 },
        header: Header = .{},
        ranges: [max_ranges]Range = @splat(.{ .start = 0, .end = 0 }),
        range_count: usize = 0,
        /// 由 MF=0 的最后一片确定；没收到最后一片时为 null。
        total: ?usize = null,
        updated_ms: u32 = 0,
    };

    slots: [capacity]Slot = @splat(Slot{}),
    /// 重组缓冲由**调用方**提供，不放进结构体默认值：否则 `Reasm{}` 这个
    /// 编译期常量会把整块缓冲写进 `.data`（多 6 KB 镜像 + 启动期搬运）。
    /// 约定：`storage[i*stride ..][0..20]` 放首部，`[20..]` 放载荷。
    storage: []u8 = &.{},
    stats: Stats = .{},

    /// 挂上缓冲。长度必须 ≥ `capacity * stride`。
    pub fn attach(self: *Reasm, buf: []u8) ReasmError!void {
        if (buf.len < capacity * stride) return error.NoStorage;
        self.storage = buf[0 .. capacity * stride];
    }

    fn findSlot(self: *Reasm, key: ReasmKey) ?usize {
        for (&self.slots, 0..) |*s, i| {
            if (s.used and s.key.id == key.id and s.key.protocol == key.protocol and
                inet.eql(s.key.src, key.src) and inet.eql(s.key.dst, key.dst)) return i;
        }
        return null;
    }

    fn allocSlot(self: *Reasm, key: ReasmKey, now_ms: u32) usize {
        for (&self.slots, 0..) |*s, i| {
            if (!s.used) return initSlot(i, s, key, now_ms);
        }
        // 槽满：踢掉最久没更新的一槽（含已完整的槽——它们只有在崩溃恢复时才可能残留）。
        var victim: usize = 0;
        for (self.slots, 0..) |s, i| {
            if (s.updated_ms < self.slots[victim].updated_ms) victim = i;
        }
        self.stats.evicted += 1;
        return initSlot(victim, &self.slots[victim], key, now_ms);
    }

    fn initSlot(i: usize, s: *Slot, key: ReasmKey, now_ms: u32) usize {
        s.used = true;
        s.key = key;
        s.range_count = 0;
        s.total = null;
        s.updated_ms = now_ms;
        return i;
    }

    fn coveredPayload(slot: *const Slot) usize {
        var sum: usize = 0;
        for (slot.ranges[0..slot.range_count]) |r| sum += r.end - r.start;
        return sum;
    }

    fn covers(slot: *const Slot, start: usize, end: usize) bool {
        if (start == end) return true;
        var at = start;
        var i: usize = 0;
        while (i < slot.range_count) : (i += 1) {
            const r = slot.ranges[i];
            if (r.start <= at and at < r.end) {
                at = r.end;
                if (at >= end) return true;
                i = 0; // 合并过的区间应当有序；保险起见从头再扫（n ≤ 8）
            }
        }
        return at >= end;
    }

    /// 比较重叠区间的字节是否一致（RFC 791 只允许完全相同的重叠；
    /// 不一致即 teardrop/重叠攻击，整包丢弃）。
    fn overlapMatches(slot: *const Slot, buf: []const u8, off: usize, payload: []const u8) bool {
        const end = off + payload.len;
        for (slot.ranges[0..slot.range_count]) |r| {
            const lo = @max(off, r.start);
            const hi = @min(end, r.end);
            if (lo >= hi) continue;
            const stored = buf[min_header_len + lo .. min_header_len + hi];
            const incoming = payload[lo - off .. hi - off];
            if (!std.mem.eql(u8, stored, incoming)) return false;
        }
        return true;
    }

    fn addRange(slot: *Slot, start: usize, end: usize) ReasmError!void {
        if (start == end) return;
        // 先合并到已有区间（相邻也算，避免区间碎片化）。
        var i: usize = 0;
        while (i < slot.range_count) : (i += 1) {
            const r = slot.ranges[i];
            if (start <= r.end and r.start <= end) {
                slot.ranges[i].start = @min(r.start, start);
                slot.ranges[i].end = @max(r.end, end);
                var j = i + 1;
                while (j < slot.range_count) {
                    const n = slot.ranges[j];
                    if (n.start <= slot.ranges[i].end) {
                        slot.ranges[i].end = @max(slot.ranges[i].end, n.end);
                        var k = j;
                        while (k + 1 < slot.range_count) : (k += 1) slot.ranges[k] = slot.ranges[k + 1];
                        slot.range_count -= 1;
                    } else j += 1;
                }
                return;
            }
        }
        if (slot.range_count == max_ranges) return error.TooManyRanges;
        slot.ranges[slot.range_count] = .{ .start = start, .end = end };
        slot.range_count += 1;
        // 按起点插入排序：`covers` 依赖有序性，也能让抓包打印更好看。
        var k = slot.range_count - 1;
        while (k > 0 and slot.ranges[k - 1].start > slot.ranges[k].start) : (k -= 1) {
            const tmp = slot.ranges[k - 1];
            slot.ranges[k - 1] = slot.ranges[k];
            slot.ranges[k] = tmp;
        }
    }

    fn assemble(slot: *Slot, buf: []u8) []const u8 {
        var h = slot.header;
        const total = slot.total.?;
        h.total_len = @intCast(min_header_len + total);
        h.mf = false;
        h.frag_offset = 0;
        h.checksum = 0;
        encode(h, buf[0..min_header_len]);
        recomputeChecksum(buf[0..min_header_len]);
        slot.used = false;
        return buf[0 .. min_header_len + total];
    }

    /// 插入一片。`payload` 是去掉 20 字节首部之后的载荷视图。
    pub fn insert(self: *Reasm, h: Header, payload: []const u8, now_ms: u32) ReasmError!Outcome {
        if (self.storage.len < capacity * stride) return error.NoStorage;
        if (h.ihl != 5) return error.UnsupportedOptions;
        const off = h.offsetBytes();
        const end = off + payload.len;
        if (end > max_datagram) {
            self.stats.failed += 1;
            return error.TooLarge;
        }
        if (payload.len != h.payloadLen()) {
            self.stats.failed += 1;
            return error.BadLength;
        }
        // RFC 791 §3.1：片偏移以 8 字节为单位，所以 MF=1 的片载荷必须是 8 的倍数。
        // 不满足就无法与后续片的偏移对齐，整包丢弃而不是"先收下再说"。
        if (h.mf and payload.len % 8 != 0) {
            self.stats.failed += 1;
            return error.BadLength;
        }

        const key = ReasmKey{ .src = h.src, .dst = h.dst, .id = h.id, .protocol = h.protocol };
        const found = self.findSlot(key);
        const idx = found orelse self.allocSlot(key, now_ms);
        const slot = &self.slots[idx];
        const buf = self.storage[idx * stride ..][0..stride];
        if (found == null) slot.header = h;

        // 先记账 total_len：最后一片（MF=0）决定整包载荷长度。
        if (!h.mf) {
            if (slot.total) |known| {
                if (known != end) {
                    self.stats.failed += 1;
                    slot.used = false;
                    return error.BadLength;
                }
            }
            slot.total = end;
        }
        if (slot.total) |known| {
            if (end > known) {
                self.stats.failed += 1;
                slot.used = false;
                return error.BadLength;
            }
        }

        if (!overlapMatches(slot, buf, off, payload)) {
            self.stats.failed += 1;
            slot.used = false;
            return error.OverlapConflict;
        }

        const duplicate = covers(slot, off, end);
        if (!duplicate) {
            @memcpy(buf[min_header_len + off .. min_header_len + end], payload);
            try addRange(slot, off, end);
            self.stats.inserted += 1;
        } else {
            self.stats.duplicates += 1;
        }
        slot.updated_ms = now_ms;

        if (slot.total) |total| {
            if (covers(slot, 0, total)) {
                self.stats.completed += 1;
                return .{ .complete = assemble(slot, buf) };
            }
        }
        if (duplicate) return .duplicate;
        return .{ .accepted = coveredPayload(slot) };
    }

    /// 回收超时未完成的槽。返回回收数量。板侧/主循环应在 tick 里调用。
    pub fn expire(self: *Reasm, now_ms: u32) usize {
        var n: usize = 0;
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (now_ms -% s.updated_ms >= timeout_ms) {
                s.used = false;
                n += 1;
            }
        }
        self.stats.expired += @intCast(n);
        return n;
    }

    /// 当前占用槽数（判读用）。
    pub fn inUse(self: *const Reasm) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.used) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// PMTU：路径 MTU 缓存
// ---------------------------------------------------------------------------

/// 从 `ICMP type 3 code 4`（fragmentation needed & DF set，RFC 1191）里学到的
/// 「去往某目的地最多能给多少字节」。
///
/// 真实实现按**下一跳/路由**为键（一条路由下的所有目的地共享 PMTU）；
/// 本章按目的地址做精确匹配，表容量 8，超时 10 分钟——足够演示
/// 「学到 → 按 MTU 分片/回 ICMP → 老化重探」的闭环，又不会把表撑爆。
pub const Pmtu = struct {
    pub const capacity = 8;
    pub const ttl_ms = 600_000;
    /// RFC 791：所有主机必须能接收 576 字节的数据报；单个链路的最小合法 MTU 是 68。
    pub const floor: u16 = 68;

    const Entry = struct {
        valid: bool = false,
        dst: inet.Addr = inet.any,
        mtu: u16 = 0,
        updated_ms: u32 = 0,
    };

    entries: [capacity]Entry = @splat(.{}),
    link_mtu: u16 = 1500,

    pub fn init(link_mtu: u16) Pmtu {
        return .{ .link_mtu = link_mtu };
    }

    /// 查表：没记录就用链路 MTU。
    pub fn mtuFor(self: *const Pmtu, dst: inet.Addr) u16 {
        for (self.entries) |e| {
            if (e.valid and inet.eql(e.dst, dst)) return @min(self.link_mtu, e.mtu);
        }
        return self.link_mtu;
    }

    /// 学到一条 PMTU。比链路 MTU 大的值被忽略（ICMP 报的 MTU 不可能超过本地 MTU，
    /// 除非对端撒谎——那是要丢掉的信号）；小于 68 的值被夹到 68。
    pub fn learn(self: *Pmtu, dst: inet.Addr, mtu: u16, now_ms: u32) void {
        // RFC 1191 §4：MTU 字段为 0 是老式（不支持 PMTU 发现）的路由器，按 576 处理。
        const effective: u16 = if (mtu == 0) 576 else mtu;
        if (effective >= self.link_mtu) return;
        const clamped = @max(effective, floor);
        for (&self.entries) |*e| {
            if (e.valid and inet.eql(e.dst, dst)) {
                e.mtu = clamped;
                e.updated_ms = now_ms;
                return;
            }
        }
        for (&self.entries) |*e| {
            if (!e.valid) {
                e.* = .{ .valid = true, .dst = dst, .mtu = clamped, .updated_ms = now_ms };
                return;
            }
        }
        // 表满：覆盖最旧的一条（PMTU 本来就会过期，宁可重探）。
        var oldest = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.updated_ms < oldest.updated_ms) oldest = e;
        }
        oldest.* = .{ .valid = true, .dst = dst, .mtu = clamped, .updated_ms = now_ms };
    }

    /// 老化。返回清理的条数。调用方应在拿到「新的 ICMP 不可达」或定时 tick 时调用。
    pub fn age(self: *Pmtu, now_ms: u32) usize {
        var n: usize = 0;
        for (&self.entries) |*e| {
            if (!e.valid) continue;
            if (now_ms -% e.updated_ms >= ttl_ms) {
                e.valid = false;
                n += 1;
            }
        }
        return n;
    }

    pub fn forget(self: *Pmtu, dst: inet.Addr) void {
        for (&self.entries) |*e| {
            if (e.valid and inet.eql(e.dst, dst)) e.valid = false;
        }
    }

    pub fn count(self: *const Pmtu) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.valid) n += 1;
        }
        return n;
    }
};

/// 这个报文在 `mtu` 下是否必须分片（DF=1 时就是"要么丢、要么回 ICMP"的分界）。
pub fn needsFragment(total_len: usize, mtu: usize) bool {
    return total_len > mtu;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testReasm(store: *[Reasm.capacity * Reasm.stride]u8) !Reasm {
    var r = Reasm{};
    try r.attach(store);
    return r;
}

fn sampleDatagram(buf: []u8, payload_len: usize) ![]const u8 {
    var h = Header{
        .total_len = @intCast(min_header_len + payload_len),
        .id = 0x4711,
        .df = false,
        .ttl = 64,
        .protocol = proto.icmp,
        .src = try inet.parse("192.168.1.10"),
        .dst = try inet.parse("192.168.1.1"),
    };
    _ = try h.write(buf);
    var i: usize = 0;
    while (i < payload_len) : (i += 1) buf[min_header_len + i] = @intCast(i & 0xFF);
    return buf[0 .. min_header_len + payload_len];
}

test "ipv4: 首部写入/解析往返" {
    var buf: [64]u8 = undefined;
    const dg = try sampleDatagram(&buf, 16);

    const h = try Header.parseChecked(dg);
    try testing.expectEqual(@as(u4, 4), h.version);
    try testing.expectEqual(@as(u4, 5), h.ihl);
    try testing.expectEqual(@as(u16, 0x4711), h.id);
    try testing.expectEqual(@as(u16, 36), h.total_len);
    try testing.expectEqual(@as(usize, 20), h.headerLen());
    try testing.expectEqual(@as(usize, 16), h.payloadLen());
    try testing.expectEqual(@as(u8, 1), h.protocol);
    try testing.expectEqual(@as(usize, 16), (try h.payload(dg)).len);
}

test "ipv4: 拒绝版本 6 / IHL<5 / 总长过短 / 缓冲区截断" {
    var buf: [64]u8 = undefined;
    const dg = try sampleDatagram(&buf, 8);
    var copy: [64]u8 = @splat(0);
    @memcpy(copy[0..dg.len], dg);

    copy[0] = 0x65;
    try testing.expectError(error.BadVersion, Header.parse(&copy));

    copy[0] = 0x44;
    try testing.expectError(error.BadIhl, Header.parse(&copy));

    copy[0] = 0x45;
    copy[2] = 0;
    copy[3] = 10; // total_len = 10 < 20
    try testing.expectError(error.BadTotalLength, Header.parse(&copy));

    copy[2] = 0;
    copy[3] = 200; // total_len 超过缓冲区
    try testing.expectError(error.Truncated, Header.parse(&copy));
}

test "ipv4: 带选项（IHL=6）时载荷从偏移 24 开始" {
    var buf: [40]u8 = @splat(0);
    buf[0] = 0x46; // version 4, ihl 6
    buf[2] = 0;
    buf[3] = 32; // total_len 32
    buf[8] = 64;
    buf[9] = 6;
    const h = try Header.parse(&buf);
    try testing.expectEqual(@as(usize, 24), h.headerLen());
    try testing.expectEqual(@as(usize, 8), h.payloadLen());
    // 选项的 4 个字节落在 [20,24)，不属于载荷
    try testing.expectEqual(@as(usize, 24), @intFromPtr((try h.payload(&buf)).ptr) - @intFromPtr(&buf));
}

test "ipv4: 校验和错误由 parseChecked 报出" {
    var buf: [64]u8 = undefined;
    const dg = try sampleDatagram(&buf, 8);
    _ = try Header.parseChecked(dg);
    buf[8] = 63; // 改 TTL 而不更新校验和
    try testing.expectError(error.BadChecksum, Header.parseChecked(dg));
}

test "ipv4: DF/MF/片偏移 16 位布局" {
    var buf: [20]u8 = @splat(0);
    var h = Header{
        .total_len = 20,
        .df = true,
        .mf = true,
        .frag_offset = 0x1FFF,
        .ttl = 1,
        .protocol = proto.udp,
    };
    _ = try h.write(&buf);
    const word = std.mem.readInt(u16, buf[6..8], .big);
    try testing.expectEqual(@as(u16, 0x6000 | 0x1FFF), word);
    const back = try Header.parse(&buf);
    try testing.expect(back.df and back.mf);
    try testing.expectEqual(@as(usize, 0x1FFF * 8), back.offsetBytes());
}

test "ipv4: 分片数量按 8 字节向下取整" {
    try testing.expectEqual(@as(usize, 3), try fragmentsNeeded(3000, 1500, 20));
    try testing.expectEqual(@as(usize, 1), try fragmentsNeeded(1480, 1500, 20));
    try testing.expectEqual(@as(usize, 1), try fragmentsNeeded(100, 1500, 20));
    // MTU 1499 时每片载荷 1480（(1499-20)/8*8），仍需 3 片
    try testing.expectEqual(@as(usize, 3), try fragmentsNeeded(3000, 1499, 20));
    try testing.expectError(error.MtuTooSmall, fragmentsNeeded(10, 27, 20));
}

test "ipv4: 分片三片、偏移/MF/长度都对，载荷可拼回原样" {
    var src_buf: [3000 + 20]u8 = undefined;
    const dg = try sampleDatagram(&src_buf, 3000);

    var b0: [1500]u8 = undefined;
    var b1: [1500]u8 = undefined;
    var b2: [1500]u8 = undefined;
    var out = [_]Fragment{
        .{ .buf = &b0, .len = 0 },
        .{ .buf = &b1, .len = 0 },
        .{ .buf = &b2, .len = 0 },
        .{ .buf = &b1, .len = 0 },
    };
    const n = try fragment(dg, 1500, &out);
    try testing.expectEqual(@as(usize, 3), n);

    var rebuilt: [3020]u8 = undefined;
    var at: usize = 20;
    for (out[0..n], 0..) |f, i| {
        const fh = try Header.parseChecked(f.buf[0..f.len]);
        try testing.expectEqual(@as(usize, i * 1480), fh.offsetBytes());
        try testing.expectEqual(i != n - 1, fh.mf);
        const want_len: usize = if (i == n - 1) 60 else 1500;
        try testing.expectEqual(want_len, f.len);
        const p = try fh.payload(f.buf[0..f.len]);
        @memcpy(rebuilt[at .. at + p.len], p);
        at += p.len;
    }
    try testing.expectEqual(@as(usize, 3020), at);
    try testing.expect(std.mem.eql(u8, rebuilt[20..at], src_buf[20..3020]));
}

test "ipv4: DF=1 拒绝分片" {
    var buf: [128]u8 = undefined;
    var h = Header{
        .total_len = 128,
        .df = true,
        .protocol = proto.udp,
    };
    _ = try h.write(&buf);
    var out = [_]Fragment{.{ .buf = &buf, .len = 0 }};
    try testing.expectError(error.DfSet, fragment(buf[0..128], 100, &out));
}

test "ipv4: MTU 太小拒绝分片" {
    var buf: [128]u8 = undefined;
    const dg = try sampleDatagram(&buf, 100);
    var out = [_]Fragment{.{ .buf = &buf, .len = 0 }};
    try testing.expectError(error.MtuTooSmall, fragment(dg, 27, &out));
}

test "ipv4: 重组乱序也能完成，结果与原报文逐字节相同" {
    var src_buf: [3020]u8 = undefined;
    const dg = try sampleDatagram(&src_buf, 3000);

    var b0: [1500]u8 = undefined;
    var b1: [1500]u8 = undefined;
    var b2: [1500]u8 = undefined;
    var frags = [_]Fragment{
        .{ .buf = &b0, .len = 0 },
        .{ .buf = &b1, .len = 0 },
        .{ .buf = &b2, .len = 0 },
    };
    const n = try fragment(dg, 1500, &frags);
    try testing.expectEqual(@as(usize, 3), n);

    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    // 顺序：最后一片 → 第一片 → 中间一片
    const order = [_]usize{ 2, 0, 1 };
    var done: ?[]const u8 = null;
    for (order, 0..) |i, step| {
        const f = frags[i];
        const fh = try Header.parseChecked(f.buf[0..f.len]);
        const outcome = try r.insert(fh, try fh.payload(f.buf[0..f.len]), @intCast(step * 10));
        switch (outcome) {
            .complete => |bytes| done = bytes,
            .accepted => |covered| try testing.expect(covered < 3000),
            .duplicate => return error.Unexpected,
        }
    }
    try testing.expect(done != null);
    try testing.expectEqual(@as(usize, 3020), done.?.len);
    try testing.expect(std.mem.eql(u8, done.?, dg));
    const rh = try Header.parseChecked(done.?);
    try testing.expectEqual(@as(u16, 3020), rh.total_len);
    try testing.expect(!rh.mf and rh.frag_offset == 0);
    try testing.expectEqual(@as(u32, 1), r.stats.completed);
}

test "ipv4: 重复片不改变缓存，也不提前完成" {
    var src_buf: [3020]u8 = undefined;
    const dg = try sampleDatagram(&src_buf, 3000);
    var b0: [1500]u8 = undefined;
    var b1: [1500]u8 = undefined;
    var b2: [1500]u8 = undefined;
    var frags = [_]Fragment{
        .{ .buf = &b0, .len = 0 },
        .{ .buf = &b1, .len = 0 },
        .{ .buf = &b2, .len = 0 },
    };
    _ = try fragment(dg, 1500, &frags);

    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    const f0 = frags[0];
    const h0 = try Header.parseChecked(f0.buf[0..f0.len]);
    const p0 = try h0.payload(f0.buf[0..f0.len]);

    _ = try r.insert(h0, p0, 0);
    try testing.expectEqual(Reasm.Outcome.duplicate, try r.insert(h0, p0, 1));
    try testing.expectEqual(@as(u32, 1), r.stats.duplicates);
    try testing.expectEqual(@as(usize, 1), r.inUse());
}

test "ipv4: 重叠但内容不同 → 整包丢弃（teardrop）" {
    var src_buf: [3020]u8 = undefined;
    const dg = try sampleDatagram(&src_buf, 3000);
    var b0: [1500]u8 = undefined;
    var b1: [1500]u8 = undefined;
    var b2: [1500]u8 = undefined;
    var frags = [_]Fragment{
        .{ .buf = &b0, .len = 0 },
        .{ .buf = &b1, .len = 0 },
        .{ .buf = &b2, .len = 0 },
    };
    _ = try fragment(dg, 1500, &frags);

    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    const f0 = frags[0];
    const h0 = try Header.parseChecked(f0.buf[0..f0.len]);
    _ = try r.insert(h0, try h0.payload(f0.buf[0..f0.len]), 0);

    // 伪造一片：offset 0、载荷 16 字节，但内容与原片不同（0xAA…）
    var evil_buf: [20 + 16]u8 = undefined;
    @memcpy(evil_buf[0..20], f0.buf[0..20]);
    std.mem.writeInt(u16, evil_buf[2..4], 36, .big);
    std.mem.writeInt(u16, evil_buf[6..8], 0x2000, .big); // MF=1, offset=0
    std.mem.writeInt(u16, evil_buf[10..12], 0, .big);
    std.mem.writeInt(u16, evil_buf[10..12], inet.of(evil_buf[0..20]), .big);
    @memset(evil_buf[20..36], 0xAA);

    const evil = try Header.parseChecked(&evil_buf);
    try testing.expectError(error.OverlapConflict, r.insert(evil, evil_buf[20..36], 5));
    try testing.expectEqual(@as(usize, 0), r.inUse());
    try testing.expectEqual(@as(u32, 1), r.stats.failed);
}

test "ipv4: 缺中间片不完成；超时后槽被回收" {
    var src_buf: [3020]u8 = undefined;
    const dg = try sampleDatagram(&src_buf, 3000);
    var b0: [1500]u8 = undefined;
    var b1: [1500]u8 = undefined;
    var b2: [1500]u8 = undefined;
    var frags = [_]Fragment{
        .{ .buf = &b0, .len = 0 },
        .{ .buf = &b1, .len = 0 },
        .{ .buf = &b2, .len = 0 },
    };
    _ = try fragment(dg, 1500, &frags);

    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    for ([_]usize{ 0, 2 }) |i| {
        const f = frags[i];
        const fh = try Header.parseChecked(f.buf[0..f.len]);
        const o = try r.insert(fh, try fh.payload(f.buf[0..f.len]), 0);
        try testing.expect(o == .accepted);
    }
    try testing.expectEqual(@as(usize, 1), r.inUse());
    try testing.expectEqual(@as(usize, 0), r.expire(29_999));
    try testing.expectEqual(@as(usize, 1), r.expire(30_000));
    try testing.expectEqual(@as(usize, 0), r.inUse());
}

test "ipv4: 槽满时踢掉最久未更新的键" {
    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    var h = Header{ .total_len = 28, .id = 1, .mf = true, .protocol = proto.udp };
    var payload8: [8]u8 = @splat(0);

    h.id = 1;
    _ = try r.insert(h, &payload8, 100);
    h.id = 2;
    _ = try r.insert(h, &payload8, 200);
    h.id = 3;
    _ = try r.insert(h, &payload8, 300);
    try testing.expectEqual(@as(u32, 1), r.stats.evicted);
    try testing.expectEqual(@as(usize, 2), r.inUse());
}

test "ipv4: 片数超过区间表上限即拒绝" {
    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    var h = Header{ .total_len = 20 + 8, .id = 7, .mf = true, .protocol = proto.udp };
    h.checksum = 0;
    var payload8: [8]u8 = @splat(0x11);

    var i: usize = 0;
    while (i < Reasm.max_ranges) : (i += 1) {
        h.frag_offset = @intCast(i * 2); // 每片之间留一个 8 字节空档
        _ = try r.insert(h, &payload8, @intCast(i));
    }
    h.frag_offset = @intCast(Reasm.max_ranges * 2);
    try testing.expectError(error.TooManyRanges, r.insert(h, &payload8, 1000));
}

test "ipv4: 偏移超过重组上限直接拒绝" {
    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    var h = Header{ .total_len = 20, .id = 9, .protocol = proto.udp };
    h.frag_offset = (Reasm.max_datagram / 8) + 1;
    var payload8: [8]u8 = @splat(0);
    try testing.expectError(error.TooLarge, r.insert(h, &payload8, 0));
}

test "ipv4: 上游 MTU 600 时 1500 字节载荷分三片仍能重组成原报文" {
    var src_buf: [1520]u8 = undefined;
    const dg = try sampleDatagram(&src_buf, 1500);

    var b0: [600]u8 = undefined;
    var b1: [600]u8 = undefined;
    var b2: [600]u8 = undefined;
    var frags = [_]Fragment{
        .{ .buf = &b0, .len = 0 },
        .{ .buf = &b1, .len = 0 },
        .{ .buf = &b2, .len = 0 },
    };
    const n = try fragment(dg, 600, &frags);
    try testing.expectEqual(@as(usize, 3), n);

    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    var done: ?[]const u8 = null;
    for (frags[0..n]) |f| {
        const fh = try Header.parseChecked(f.buf[0..f.len]);
        switch (try r.insert(fh, try fh.payload(f.buf[0..f.len]), 0)) {
            .complete => |bytes| done = bytes,
            else => {},
        }
    }
    try testing.expect(done != null);
    try testing.expect(std.mem.eql(u8, done.?, dg));
}

test "ipv4: 没有挂缓冲时 insert 拒绝（不越界、不改状态）" {
    var r = Reasm{};
    const h = Header{ .total_len = 28, .id = 1, .mf = true, .protocol = proto.udp };
    var payload8: [8]u8 = @splat(0);
    try testing.expectError(error.NoStorage, r.insert(h, &payload8, 0));
    try testing.expectEqual(@as(usize, 0), r.inUse());

    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoStorage, r.attach(&tiny));
}

test "ipv4: MF=1 的片载荷不是 8 的倍数 → 整包拒绝" {
    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    const h = Header{ .total_len = 25, .id = 21, .mf = true, .protocol = proto.udp };
    var payload5: [5]u8 = @splat(1);
    try testing.expectError(error.BadLength, r.insert(h, &payload5, 0));
    try testing.expectEqual(@as(usize, 0), r.inUse());
    try testing.expectEqual(@as(u32, 1), r.stats.failed);
}

test "ipv4: 带选项的片不重组" {
    var store: [Reasm.capacity * Reasm.stride]u8 = undefined;
    var r = try testReasm(&store);
    const h = Header{ .total_len = 28, .id = 11, .protocol = proto.udp, .ihl = 6 };
    var payload8: [8]u8 = @splat(0);
    try testing.expectError(error.UnsupportedOptions, r.insert(h, &payload8, 0));
}

test "ipv4: PMTU 学到、夹紧、老化" {
    var p = Pmtu.init(1500);
    const dst = try inet.parse("203.0.113.7");
    try testing.expectEqual(@as(u16, 1500), p.mtuFor(dst));

    p.learn(dst, 1400, 1_000);
    try testing.expectEqual(@as(u16, 1400), p.mtuFor(dst));
    try testing.expectEqual(@as(usize, 1), p.count());

    // 比链路 MTU 大的值被忽略（不能靠谎报把 MTU 抬高）
    p.learn(dst, 9000, 1_100);
    try testing.expectEqual(@as(u16, 1400), p.mtuFor(dst));

    // 小于 68 的值夹到 68
    const other = try inet.parse("198.51.100.1");
    p.learn(other, 24, 1_200);
    try testing.expectEqual(Pmtu.floor, p.mtuFor(other));

    try testing.expectEqual(@as(usize, 0), p.age(1_000 + Pmtu.ttl_ms - 1));
    try testing.expectEqual(@as(usize, 1), p.age(1_000 + Pmtu.ttl_ms));
    try testing.expectEqual(@as(u16, 1500), p.mtuFor(dst));
    try testing.expectEqual(@as(usize, 1), p.age(1_200 + Pmtu.ttl_ms));

    try testing.expect(!needsFragment(1500, 1500));
    try testing.expect(needsFragment(1501, 1500));
}

test "ipv4: 老式 frag-needed（MTU 字段为 0）按 576 处理" {
    var p = Pmtu.init(1500);
    const dst = try inet.parse("198.51.100.7");
    p.learn(dst, 0, 1_000);
    try testing.expectEqual(@as(u16, 576), p.mtuFor(dst));
}
