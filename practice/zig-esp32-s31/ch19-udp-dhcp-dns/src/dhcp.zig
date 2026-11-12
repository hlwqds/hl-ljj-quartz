//! ch19-udp-dhcp-dns：DHCP 报文编解码与客户端状态机。
//!
//! DHCP（RFC 2131）的报文格式继承自 BOOTP：**236 字节固定区 + 4 字节魔数 +
//! TLV 选项区**。三段的边界是本章最容易写错的地方——
//!
//! ```text
//! 0 .. 236     op/htype/hlen/hops/xid/secs/flags/ciaddr/yiaddr/siaddr/giaddr/
//!              chaddr[16]/sname[64]/file[128]
//! 236 .. 240   magic cookie = 0x63825363（不是 "DHCP"，也不是 LE）
//! 240 .. end   option code(1) + len(1) + value(len)，PAD(0) 与 END(255) 例外
//! ```
//!
//! ## 状态机只做四件事
//!
//! `DISCOVER → OFFER → REQUEST → ACK` 是常见路径，但真正决定“会不会掉线”的
//! 是另外三条分支：**超时重传**、**T1/T2 续租**、**NAK 回 INIT**。本模块把
//! 这三条都做成纯函数（输入 `now`，输出 `Action`），所以能在主机侧把
//! 几小时的租期压缩成几行断言。
//!
//! 时间单位统一用**秒**：DHCP 的重传粒度是秒级（RFC 2131 §4.1 建议初始 4s
//! 随机等待、指数退避），用秒做整数运算既不会溢出，也让用例可以逐秒推演。
//!
//! ## 与 lwIP 的一个已知差异
//!
//! lwIP 把 T1/T2 换算成 60s 的粗定时器 tick 数（`DHCP_COARSE_TIMER_SECS`，
//! `components/lwip/lwip/src/include/lwip/dhcp.h:64-65`），因此租期小于 1 分钟
//! 时 T1 与 T2 会同时触发，它索性把 T1 置 0（`dhcp.c:1206-1210`）。本章直接
//! 用秒，保留同样的“T1 不得晚于 T2”的约束，但不引入粗 tick 的量化误差。

const std = @import("std");

pub const client_port: u16 = 68;
pub const server_port: u16 = 67;

/// BOOTP 固定区长度（到 `file[128]` 结束）。
pub const fixed_len = 236;
/// 选项区从魔数之后开始。
pub const options_off = 240;
pub const magic_cookie: u32 = 0x63825363;
/// 合法报文的最小长度（固定区 + 魔数 + 至少一个 END）。
pub const min_len = options_off + 1;

pub const Error = error{
    Truncated,
    BadCookie,
    BadOption,
    BadLength,
    UnsupportedHardware,
    NotAReply,
    WrongXid,
    MissingOption,
};

pub const Op = enum(u8) { request = 1, reply = 2, _ };

/// 标志字段只有最高位有意义（RFC 2131 §2）：bit15 = BROADCAST。
/// Zig 的 packed struct 按 LSB 起算，所以保留位要先声明。
pub const Flags = packed struct(u16) {
    reserved: u15 = 0,
    broadcast: bool = false,
};

pub const MsgType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    inform = 8,
    _,
};

pub const Option = struct {
    pub const pad: u8 = 0;
    pub const subnet_mask: u8 = 1;
    pub const router: u8 = 3;
    pub const dns: u8 = 6;
    pub const host_name: u8 = 12;
    pub const requested_ip: u8 = 50;
    pub const lease_time: u8 = 51;
    pub const message_type: u8 = 53;
    pub const server_id: u8 = 54;
    pub const param_list: u8 = 55;
    pub const message: u8 = 56;
    pub const max_size: u8 = 57;
    pub const t1: u8 = 58;
    pub const t2: u8 = 59;
    pub const end: u8 = 255;
};

/// 客户端最想知道的六个参数（按优先级）。发给服务器的 `option 55`。
pub const default_param_list = [_]u8{
    Option.subnet_mask,
    Option.router,
    Option.dns,
    Option.lease_time,
    Option.t1,
    Option.t2,
};

pub const Msg = struct {
    op: Op = .request,
    htype: u8 = 1, // 1 = Ethernet
    hlen: u8 = 6,
    hops: u8 = 0,
    xid: u32,
    secs: u16 = 0,
    flags: Flags = .{},
    ciaddr: [4]u8 = @splat(0),
    yiaddr: [4]u8 = @splat(0),
    siaddr: [4]u8 = @splat(0),
    giaddr: [4]u8 = @splat(0),
    chaddr: [16]u8 = @splat(0),
};

fn isZero(addr: [4]u8) bool {
    return std.mem.eql(u8, &addr, &[_]u8{ 0, 0, 0, 0 });
}

/// 写 236 字节固定区 + 4 字节魔数，返回 240。
pub fn writeFixed(msg: Msg, buf: []u8) Error!usize {
    if (buf.len < options_off) return error.Truncated;
    @memset(buf[0..options_off], 0);
    buf[0] = @intFromEnum(msg.op);
    buf[1] = msg.htype;
    buf[2] = msg.hlen;
    buf[3] = msg.hops;
    std.mem.writeInt(u32, buf[4..8], msg.xid, .big);
    std.mem.writeInt(u16, buf[8..10], msg.secs, .big);
    std.mem.writeInt(u16, buf[10..12], @bitCast(msg.flags), .big);
    @memcpy(buf[12..16], &msg.ciaddr);
    @memcpy(buf[16..20], &msg.yiaddr);
    @memcpy(buf[20..24], &msg.siaddr);
    @memcpy(buf[24..28], &msg.giaddr);
    @memcpy(buf[28..44], &msg.chaddr);
    std.mem.writeInt(u32, buf[fixed_len..options_off], magic_cookie, .big);
    return options_off;
}

pub fn parseFixed(buf: []const u8) Error!Msg {
    if (buf.len < options_off) return error.Truncated;
    if (std.mem.readInt(u32, buf[fixed_len..options_off], .big) != magic_cookie)
        return error.BadCookie;

    var msg = Msg{ .xid = std.mem.readInt(u32, buf[4..8], .big) };
    msg.op = @enumFromInt(buf[0]);
    msg.htype = buf[1];
    msg.hlen = buf[2];
    msg.hops = buf[3];
    if (msg.htype != 1) return error.UnsupportedHardware;
    if (msg.hlen > 16) return error.BadOption;
    msg.secs = std.mem.readInt(u16, buf[8..10], .big);
    msg.flags = @bitCast(std.mem.readInt(u16, buf[10..12], .big));
    @memcpy(&msg.ciaddr, buf[12..16]);
    @memcpy(&msg.yiaddr, buf[16..20]);
    @memcpy(&msg.siaddr, buf[20..24]);
    @memcpy(&msg.giaddr, buf[24..28]);
    @memcpy(&msg.chaddr, buf[28..44]);
    return msg;
}

/// 选项解析结果。字符串类字段指向**原缓冲区**，不复制（板侧没有堆）。
pub const Options = struct {
    message_type: ?MsgType = null,
    server_id: ?[4]u8 = null,
    subnet_mask: ?[4]u8 = null,
    router: ?[4]u8 = null,
    dns: ?[4]u8 = null,
    requested_ip: ?[4]u8 = null,
    lease_time: ?u32 = null,
    t1: ?u32 = null,
    t2: ?u32 = null,
    message: []const u8 = "",
};

fn ipAt(data: []const u8) Error![4]u8 {
    if (data.len != 4) return error.BadOption;
    var ip: [4]u8 = undefined;
    @memcpy(&ip, data);
    return ip;
}

fn u32At(data: []const u8) Error!u32 {
    if (data.len != 4) return error.BadOption;
    return std.mem.readInt(u32, data[0..4], .big);
}

/// 解析 TLV 选项区。**必须有 END**：RFC 2131 要求最后一个选项是 255，
/// 缺了它多半说明报文被截断，宁可报错让上层计数也不要猜。
pub fn parseOptions(packet: []const u8, out: *Options) Error!void {
    if (packet.len < options_off) return error.Truncated;
    var i: usize = options_off;
    while (i < packet.len) {
        const code = packet[i];
        i += 1;
        if (code == Option.pad) continue;
        if (code == Option.end) return;
        if (i >= packet.len) return error.Truncated;
        const l: usize = packet[i];
        i += 1;
        if (i + l > packet.len) return error.Truncated;
        const data = packet[i .. i + l];
        i += l;

        switch (code) {
            Option.message_type => {
                if (l != 1) return error.BadOption;
                out.message_type = @enumFromInt(data[0]);
            },
            Option.server_id => out.server_id = try ipAt(data),
            Option.subnet_mask => out.subnet_mask = try ipAt(data),
            Option.router => {
                // 路由器列表可以有多项，本章只取第一个（板侧只有一条默认路由）。
                if (l < 4) return error.BadOption;
                out.router = try ipAt(data[0..4]);
            },
            Option.dns => {
                if (l < 4) return error.BadOption;
                out.dns = try ipAt(data[0..4]);
            },
            Option.requested_ip => out.requested_ip = try ipAt(data),
            Option.lease_time => out.lease_time = try u32At(data),
            Option.t1 => out.t1 = try u32At(data),
            Option.t2 => out.t2 = try u32At(data),
            Option.message => out.message = data,
            else => {},
        }
    }
    return error.Truncated;
}

pub const Builder = struct {
    buf: []u8,
    len: usize = options_off,

    pub fn init(buf: []u8, msg: Msg) Error!Builder {
        if (buf.len < min_len) return error.Truncated;
        const n = try writeFixed(msg, buf);
        return .{ .buf = buf, .len = n };
    }

    pub fn option(self: *Builder, code: u8, data: []const u8) Error!void {
        if (data.len > 255) return error.BadLength;
        if (self.len + 2 + data.len + 1 > self.buf.len) return error.Truncated;
        self.buf[self.len] = code;
        self.buf[self.len + 1] = @intCast(data.len);
        @memcpy(self.buf[self.len + 2 ..][0..data.len], data);
        self.len += 2 + data.len;
    }

    pub fn ip(self: *Builder, code: u8, addr: [4]u8) Error!void {
        try self.option(code, &addr);
    }

    pub fn u32Opt(self: *Builder, code: u8, value: u32) Error!void {
        if (self.len + 6 + 1 > self.buf.len) return error.Truncated;
        self.buf[self.len] = code;
        self.buf[self.len + 1] = 4;
        std.mem.writeInt(u32, self.buf[self.len + 2 .. self.len + 6][0..4], value, .big);
        self.len += 6;
    }

    /// 追加 END 并返回完整报文切片。
    pub fn finish(self: *Builder) Error![]u8 {
        if (self.len + 1 > self.buf.len) return error.Truncated;
        self.buf[self.len] = Option.end;
        self.len += 1;
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// 客户端状态机
// ---------------------------------------------------------------------------

pub const State = enum {
    /// 没有地址，下一次 `poll` 会发 DISCOVER。
    init,
    /// 已发 DISCOVER，等 OFFER（广播）。
    selecting,
    /// 已发 REQUEST，等 ACK/NAK。
    requesting,
    /// 已绑定，T1 之前不动作。
    bound,
    /// T1 到期，单播续租。
    renewing,
    /// T2 到期，广播重绑定。
    rebinding,
};

/// 状态机对外只输出“下一步该发什么”。没有载荷，所以就是一个普通枚举：
/// 调用方拿到它之后自己组包，状态机不持有缓冲区。
pub const Action = enum {
    idle,
    send_discover,
    send_request,
    send_renew,
    send_rebind,
    lease_expired,
};

pub const Lease = struct {
    ip: [4]u8 = @splat(0),
    mask: [4]u8 = @splat(0),
    router: [4]u8 = @splat(0),
    dns: [4]u8 = @splat(0),
};

/// 重传退避：4、8、16、32、64，封顶 64 秒；`jitter` 加 0/1 秒。
/// 对应 RFC 2131 §4.1 的 “4 秒起步、随机化、指数翻倍”。
pub fn backoffDelay(attempt: u8, jitter: bool) u32 {
    const base: u32 = if (attempt >= 4) 64 else @as(u32, 4) << @intCast(attempt);
    return base + @intFromBool(jitter);
}

/// 服务器没给掩码时的保守猜测（与 lwIP `dhcp_bind()` 的 classful 兜底一致）。
pub fn classfulMask(addr: [4]u8) [4]u8 {
    if (addr[0] < 128) return .{ 255, 0, 0, 0 };
    if (addr[0] < 192) return .{ 255, 255, 0, 0 };
    return .{ 255, 255, 255, 0 };
}

pub const Client = struct {
    state: State = .init,
    xid: u32 = 0,
    xid_seq: u32 = 0,
    offered_ip: [4]u8 = @splat(0),
    server_id: [4]u8 = @splat(0),
    lease: Lease = .{},

    lease_secs: u32 = 0,
    t1_secs: u32 = 0,
    t2_secs: u32 = 0,

    lease_at: u64 = 0,
    t1_at: u64 = 0,
    t2_at: u64 = 0,
    retry_at: u64 = 0,
    attempts: u8 = 0,

    fn nextXid(self: *Client) u32 {
        self.xid_seq +%= 1;
        return 0x3D00_0000 ^ (self.xid_seq *% 0x9E37_79B9);
    }

    fn jitterBit(self: *const Client) bool {
        return ((self.xid >> 2) & 1) != 0;
    }

    fn scheduleRetry(self: *Client, now: u64) void {
        self.retry_at = now + backoffDelay(self.attempts, self.jitterBit());
    }

    fn expire(self: *Client) void {
        self.state = .init;
        self.offered_ip = @splat(0);
        self.server_id = @splat(0);
        self.lease = .{};
        self.lease_secs = 0;
        self.t1_secs = 0;
        self.t2_secs = 0;
        self.lease_at = 0;
        self.t1_at = 0;
        self.t2_at = 0;
        self.attempts = 0;
    }

    /// 推进一步。调用频率建议 1 Hz；所有判断都基于 `now`，与调用频率无关。
    pub fn poll(self: *Client, now: u64) Action {
        switch (self.state) {
            .init => {
                self.xid = self.nextXid();
                self.state = .selecting;
                self.attempts = 0;
                self.scheduleRetry(now);
                return .send_discover;
            },
            .selecting => {
                if (now >= self.retry_at) {
                    self.attempts +|= 1;
                    self.scheduleRetry(now);
                    return .send_discover;
                }
                return .idle;
            },
            .requesting => {
                if (now >= self.retry_at) {
                    self.attempts +|= 1;
                    self.scheduleRetry(now);
                    return .send_request;
                }
                return .idle;
            },
            .bound, .renewing, .rebinding => {
                // 租期优先于一切：过期即回 INIT（RFC 2131 §4.4.5）。
                if (self.lease_at != 0 and now >= self.lease_at) {
                    self.expire();
                    return .lease_expired;
                }
                switch (self.state) {
                    .bound => {
                        if (now >= self.t2_at) {
                            self.state = .rebinding;
                            self.attempts = 0;
                            self.scheduleRetry(now);
                            return .send_rebind;
                        }
                        // t1_secs == 0 表示“关闭 T1 定时器”（服务器给的 T1 不早于 T2）：
                        // 此时 t1_at 也等于绑定时刻，不能拿它当判据，否则会在绑定
                        // 后立刻发出一次单播续租。
                        if (self.t1_secs != 0 and now >= self.t1_at) {
                            self.state = .renewing;
                            self.attempts = 0;
                            self.scheduleRetry(now);
                            return .send_renew;
                        }
                    },
                    .renewing => {
                        if (now >= self.t2_at) {
                            self.state = .rebinding;
                            self.attempts = 0;
                            self.scheduleRetry(now);
                            return .send_rebind;
                        }
                        if (now >= self.retry_at) {
                            self.attempts +|= 1;
                            self.scheduleRetry(now);
                            return .send_renew;
                        }
                    },
                    .rebinding => {
                        if (now >= self.retry_at) {
                            self.attempts +|= 1;
                            self.scheduleRetry(now);
                            return .send_rebind;
                        }
                    },
                    else => {},
                }
                return .idle;
            },
        }
    }

    /// 处理服务器的回包。`xid` 不匹配的迟到包直接拒绝，不能让它改状态。
    pub fn onReply(self: *Client, msg: *const Msg, opts: *const Options, now: u64) Error!Action {
        if (msg.op != .reply) return error.NotAReply;
        if (msg.xid != self.xid) return error.WrongXid;
        const mt = opts.message_type orelse return error.MissingOption;

        switch (mt) {
            .offer => {
                if (self.state != .selecting) return .idle;
                const sid = opts.server_id orelse return error.MissingOption;
                if (isZero(msg.yiaddr)) return error.BadOption;
                self.offered_ip = msg.yiaddr;
                self.server_id = sid;
                self.state = .requesting;
                self.attempts = 0;
                self.scheduleRetry(now);
                return .send_request;
            },
            .ack => switch (self.state) {
                .requesting, .renewing, .rebinding => {
                    const secs = opts.lease_time orelse self.lease_secs;
                    if (secs == 0) return error.MissingOption;
                    if (opts.server_id) |sid| self.server_id = sid;
                    if (!isZero(msg.yiaddr)) self.offered_ip = msg.yiaddr;
                    if (isZero(self.offered_ip)) return error.MissingOption;

                    self.lease.ip = self.offered_ip;
                    self.lease.mask = opts.subnet_mask orelse classfulMask(self.offered_ip);
                    self.lease.router = opts.router orelse self.server_id;
                    self.lease.dns = opts.dns orelse self.server_id;

                    self.lease_secs = secs;
                    self.t1_secs = blk: {
                        const t1 = opts.t1 orelse secs / 2;
                        break :blk if (t1 == 0) secs / 2 else t1;
                    };
                    self.t2_secs = blk: {
                        const t2 = opts.t2 orelse secs - secs / 8;
                        break :blk if (t2 == 0) secs - secs / 8 else t2;
                    };
                    // 租期太短会让 T1 追上 T2：保留“T1 不晚于 T2”的约束，
                    // 做法与 lwIP 一致——把 T1 置 0，让 T2 独立触发。
                    if (self.t2_secs > 0 and self.t1_secs >= self.t2_secs) self.t1_secs = 0;

                    self.lease_at = now + self.lease_secs;
                    self.t1_at = now + self.t1_secs;
                    self.t2_at = now + self.t2_secs;
                    self.attempts = 0;
                    self.state = .bound;
                    return .idle;
                },
                else => return .idle,
            },
            .nak => {
                // NAK 表示“你请求的地址不能给你”。旧 offer 必须清空：
                // 留着它，下一次 REQUEST 会继续请求同一个错误地址。
                self.expire();
                return .idle;
            },
            else => return .idle,
        }
    }
};

// ---------------------------------------------------------------------------
// 主机侧用例
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_mac = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x19 };

fn testMsg(xid: u32) Msg {
    var m = Msg{ .xid = xid };
    @memcpy(m.chaddr[0..6], &test_mac);
    return m;
}

test "dhcp: DISCOVER 的固定字段布局与魔数" {
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, testMsg(0xDEAD_BEEF));
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.discover)});
    try b.option(Option.param_list, &default_param_list);
    const pkt = try b.finish();

    try testing.expectEqual(@as(u8, 1), pkt[0]); // op = request
    try testing.expectEqual(@as(u8, 1), pkt[1]); // htype = Ethernet
    try testing.expectEqual(@as(u8, 6), pkt[2]); // hlen
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), std.mem.readInt(u32, pkt[4..8], .big));
    try testing.expectEqual(@as(u32, 0x63825363), std.mem.readInt(u32, pkt[236..240], .big));
    try testing.expectEqualSlices(u8, &test_mac, pkt[28..34]);
    // 固定区其余字节必须是 0（sname/file 不参与协商）。
    for (pkt[44..236]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(u8, Option.end), pkt[pkt.len - 1]);
}

test "dhcp: 魔数不对直接拒绝" {
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, testMsg(1));
    _ = try b.finish();
    std.mem.writeInt(u32, buf[236..240], 0x01020304, .big);
    try testing.expectError(error.BadCookie, parseFixed(&buf));
}

test "dhcp: 选项 TLV 解析（53/54/1/3/6/51/58/59）" {
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, testMsg(7));
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.ack)});
    try b.ip(Option.server_id, .{ 192, 168, 1, 1 });
    try b.ip(Option.subnet_mask, .{ 255, 255, 255, 0 });
    try b.ip(Option.router, .{ 192, 168, 1, 1 });
    try b.ip(Option.dns, .{ 223, 5, 5, 5 });
    try b.u32Opt(Option.lease_time, 7200);
    try b.u32Opt(Option.t1, 3600);
    try b.u32Opt(Option.t2, 6300);
    const pkt = try b.finish();

    const msg = try parseFixed(pkt);
    try testing.expectEqual(@as(u16, 6), msg.hlen);

    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    try testing.expectEqual(MsgType.ack, opts.message_type.?);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &opts.server_id.?);
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 0 }, &opts.subnet_mask.?);
    try testing.expectEqualSlices(u8, &[_]u8{ 223, 5, 5, 5 }, &opts.dns.?);
    try testing.expectEqual(@as(u32, 7200), opts.lease_time.?);
    try testing.expectEqual(@as(u32, 3600), opts.t1.?);
    try testing.expectEqual(@as(u32, 6300), opts.t2.?);
}

test "dhcp: 参数请求列表按字节顺序编码，且带 PAD 也不影响解析" {
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, testMsg(2));
    try b.option(Option.pad, &.{}); // 显式 PAD（code=0, len=0）
    try b.option(Option.param_list, &[_]u8{ 1, 3, 6, 15, 51, 58, 59 });
    const pkt = try b.finish();
    // PAD 是两个字节 0x00 0x00：第一个是 PAD，第二个是“长度 0 的 PAD”。
    try testing.expectEqual(@as(u8, Option.pad), pkt[240]);
    try testing.expectEqual(@as(u8, Option.param_list), pkt[242]);
    try testing.expectEqual(@as(u8, 7), pkt[243]);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 6, 15, 51, 58, 59 }, pkt[244..251]);
}

test "dhcp: 选项越界 / 缺少 END 都是畸形" {
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, testMsg(3));
    try b.option(Option.lease_time, &.{ 0, 0, 0x0e, 0x10 });
    const pkt = try b.finish();

    var opts: Options = .{};
    try parseOptions(pkt, &opts);

    // 去掉 END：解析器必须报错而不是“读到缓冲末尾就收工”。
    try testing.expectError(error.Truncated, parseOptions(pkt[0 .. pkt.len - 1], &opts));

    // 长度字段声称 200 字节，但报文只剩 5 字节。
    var bad = pkt;
    bad[241] = 200;
    try testing.expectError(error.Truncated, parseOptions(bad[0 .. options_off + 3], &opts));
}

test "dhcp: OFFER → REQUEST，xid 与 server id 被记住" {
    var client: Client = .{};
    try testing.expectEqual(Action.send_discover, client.poll(0));
    try testing.expectEqual(State.selecting, client.state);

    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        m.yiaddr = .{ 192, 168, 1, 42 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.offer)});
    try b.ip(Option.server_id, .{ 192, 168, 1, 1 });
    try b.u32Opt(Option.lease_time, 3600);
    const pkt = try b.finish();

    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);

    try testing.expectEqual(Action.send_request, try client.onReply(&msg, &opts, 1));
    try testing.expectEqual(State.requesting, client.state);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 42 }, &client.offered_ip);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &client.server_id);
}

test "dhcp: ACK → bound，缺省 T1/T2 = 1/2 与 7/8 租期" {
    var client: Client = .{};
    _ = client.poll(0);
    client.state = .requesting; // 跳过 OFFER，只验证 ACK 的租期换算
    var buf: [576]u8 = @splat(0);

    // 直接喂 ACK（真实流程见上一条用例）。
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        m.yiaddr = .{ 10, 0, 2, 15 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.ack)});
    try b.ip(Option.server_id, .{ 10, 0, 2, 1 });
    try b.ip(Option.subnet_mask, .{ 255, 255, 255, 0 });
    try b.u32Opt(Option.lease_time, 3600);
    const pkt = try b.finish();

    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);

    try testing.expectEqual(Action.idle, try client.onReply(&msg, &opts, 10));
    try testing.expectEqual(State.bound, client.state);
    try testing.expectEqual(@as(u32, 3600), client.lease_secs);
    try testing.expectEqual(@as(u32, 1800), client.t1_secs);
    try testing.expectEqual(@as(u32, 3150), client.t2_secs);
    try testing.expectEqual(@as(u64, 3610), client.lease_at);
    try testing.expectEqual(@as(u64, 1810), client.t1_at);
    try testing.expectEqual(@as(u64, 3160), client.t2_at);
    // 掩码来自 option 1，网关/DNS 缺省回落到 server id。
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 0 }, &client.lease.mask);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 2, 1 }, &client.lease.router);
}

test "dhcp: ACK 里显式 T1/T2 覆盖缺省值" {
    var client: Client = .{};
    _ = client.poll(0);
    client.state = .requesting;
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        m.yiaddr = .{ 10, 0, 2, 15 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.ack)});
    try b.ip(Option.server_id, .{ 10, 0, 2, 1 });
    try b.u32Opt(Option.lease_time, 600);
    try b.u32Opt(Option.t1, 120);
    try b.u32Opt(Option.t2, 480);
    const pkt = try b.finish();

    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    _ = try client.onReply(&msg, &opts, 0);
    try testing.expectEqual(@as(u32, 120), client.t1_secs);
    try testing.expectEqual(@as(u32, 480), client.t2_secs);
}

test "dhcp: 租期太短时 T1 让位给 T2（不晚于 T2 的约束）" {
    var client: Client = .{};
    _ = client.poll(0);
    client.state = .requesting;
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        m.yiaddr = .{ 10, 0, 2, 15 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.ack)});
    try b.u32Opt(Option.lease_time, 6);
    const pkt = try b.finish();
    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    _ = try client.onReply(&msg, &opts, 0);
    // 缺省 t1 = lease/2 = 3、t2 = lease - lease/8 = 6（整数除法）；t1 < t2 时保留原值。
    try testing.expectEqual(@as(u32, 3), client.t1_secs);
    try testing.expectEqual(@as(u32, 6), client.t2_secs);
}

test "dhcp: 服务器给出 T1 >= T2 时关闭 T1 定时器，只由 T2 触发重绑定" {
    var client: Client = .{};
    _ = client.poll(0);
    client.state = .requesting;
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        m.yiaddr = .{ 172, 16, 4, 21 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.ack)});
    try b.u32Opt(Option.lease_time, 100);
    try b.u32Opt(Option.t1, 90);
    try b.u32Opt(Option.t2, 80);
    const pkt = try b.finish();

    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    _ = try client.onReply(&msg, &opts, 0);

    // T1 不早于 T2：T1 定时器被关掉（t1_secs = 0），而不是“立刻到期”。
    try testing.expectEqual(@as(u32, 0), client.t1_secs);
    try testing.expectEqual(@as(u64, 0), client.t1_at);
    try testing.expectEqual(Action.idle, client.poll(0));
    try testing.expectEqual(Action.idle, client.poll(79));
    try testing.expectEqual(Action.send_rebind, client.poll(80));
    try testing.expectEqual(State.rebinding, client.state);
}

test "dhcp: NAK 清空 offer 并回到 INIT" {
    var client: Client = .{};
    _ = client.poll(0);
    client.offered_ip = .{ 192, 168, 1, 99 };
    client.state = .requesting;
    client.server_id = .{ 192, 168, 1, 1 };

    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.nak)});
    try b.option(Option.message, "wrong network");
    const pkt = try b.finish();

    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    try testing.expectEqual(Action.idle, try client.onReply(&msg, &opts, 5));
    try testing.expectEqual(State.init, client.state);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &client.offered_ip);
    try testing.expectEqualStrings("wrong network", opts.message);

    // 回 INIT 之后 poll 必须重新走 DISCOVER，并换一个 xid。
    const old_xid = client.xid;
    try testing.expectEqual(Action.send_discover, client.poll(6));
    try testing.expect(client.xid != old_xid);
}

test "dhcp: T1 单播续租、T2 广播重绑定、租期到期回 INIT" {
    var client: Client = .{};
    _ = client.poll(0);
    client.state = .requesting;
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid);
        m.op = .reply;
        m.yiaddr = .{ 172, 16, 4, 20 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.ack)});
    try b.u32Opt(Option.lease_time, 100); // t1=50 t2=100-12=88
    const pkt = try b.finish();
    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    _ = try client.onReply(&msg, &opts, 0);

    try testing.expectEqual(Action.idle, client.poll(49));
    try testing.expectEqual(State.bound, client.state);
    try testing.expectEqual(Action.send_renew, client.poll(50));
    try testing.expectEqual(State.renewing, client.state);

    // 续租请求按退避重发（4 秒起步，抖动 +0/1），到 T2 必须改用广播重绑定。
    try testing.expectEqual(Action.send_renew, client.poll(50 + 6));
    try testing.expectEqual(Action.send_rebind, client.poll(88));
    try testing.expectEqual(State.rebinding, client.state);
    try testing.expectEqual(Action.lease_expired, client.poll(100));
    try testing.expectEqual(State.init, client.state);
    try testing.expectEqual(@as(u32, 0), client.lease_secs);
}

test "dhcp: 重传退避 4→64 封顶，抖动只加 1 秒" {
    try testing.expectEqual(@as(u32, 4), backoffDelay(0, false));
    try testing.expectEqual(@as(u32, 5), backoffDelay(0, true));
    try testing.expectEqual(@as(u32, 8), backoffDelay(1, false));
    try testing.expectEqual(@as(u32, 16), backoffDelay(2, false));
    try testing.expectEqual(@as(u32, 32), backoffDelay(3, false));
    try testing.expectEqual(@as(u32, 64), backoffDelay(4, false));
    try testing.expectEqual(@as(u32, 64), backoffDelay(9, false));
    try testing.expectEqual(@as(u32, 65), backoffDelay(9, true));
}

test "dhcp: 迟到包（xid 不匹配）不改状态" {
    var client: Client = .{};
    _ = client.poll(0);
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, blk: {
        var m = testMsg(client.xid +% 1);
        m.op = .reply;
        m.yiaddr = .{ 192, 168, 1, 77 };
        break :blk m;
    });
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.offer)});
    try b.ip(Option.server_id, .{ 192, 168, 1, 1 });
    const pkt = try b.finish();
    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    try testing.expectError(error.WrongXid, client.onReply(&msg, &opts, 1));
    try testing.expectEqual(State.selecting, client.state);
}

test "dhcp: 非 reply（op=request）的报文拒绝" {
    var client: Client = .{};
    _ = client.poll(0);
    var buf: [576]u8 = @splat(0);
    var b = try Builder.init(&buf, testMsg(client.xid));
    try b.option(Option.message_type, &.{@intFromEnum(MsgType.offer)});
    const pkt = try b.finish();
    const msg = try parseFixed(pkt);
    var opts: Options = .{};
    try parseOptions(pkt, &opts);
    try testing.expectError(error.NotAReply, client.onReply(&msg, &opts, 1));
}

test "dhcp: 报文缓冲区小于 241 字节时 Builder 拒绝" {
    var small: [240]u8 = @splat(0);
    try testing.expectError(error.Truncated, Builder.init(&small, testMsg(1)));
}

test "dhcp: 缺省掩码按 classful 兜底" {
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 0 }, &classfulMask(.{ 10, 0, 0, 1 }));
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 0, 0 }, &classfulMask(.{ 172, 16, 0, 1 }));
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 0 }, &classfulMask(.{ 192, 168, 1, 1 }));
}
