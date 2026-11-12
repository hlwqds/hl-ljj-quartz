//! ch24-mqtt-ota-application-protocols：MQTT 3.1.1 控制报文编解码。
//!
//! 这一层只做“字节 ↔ 结构”的翻译，不做会话、不做重传、不碰网络：
//!
//!   - 固定头：`type << 4 | flags`，flags 的合法值由报文类型决定
//!     （PUBLISH 是 dup/qos/retain，PUBREL/SUBSCRIBE/UNSUBSCRIBE 恒为 0b0010，
//!      其余必须为 0）；
//!   - 剩余长度：变长整数编码，7 位一组、最高位续位，最多 4 字节，
//!     上限 268435455（MQTT 3.1.1 §2.2.3）；
//!   - 可变头/载荷：CONNECT、CONNACK、PUBLISH、PUBACK/PUBREC/PUBREL/PUBCOMP、
//!     SUBSCRIBE/SUBACK、UNSUBSCRIBE、PINGREQ/PINGRESP、DISCONNECT；
//!   - 主题过滤器匹配：`+` 与 `#` 的层级语义（§4.7），以及过滤器本身的合法性。
//!
//! 所有函数都是“写进调用方给的缓冲 / 从调用方给的切片里切”，没有分配器。
//! 解码返回的 `[]const u8` 指向输入缓冲，不做拷贝——板侧只有一块
//! `g_rx`，拷贝一次就多一份 1 KiB 的开销，而且会让“哪个缓冲是谁的”变模糊。
//!
//! 为什么把编解码做成纯函数：这样主机侧测试能逐字节对拍，板侧自检能复用
//! 同一份代码打印真实字节。协议层的 bug 有 90% 是“某个长度字段少算了 2”，
//! 这种错误只有字节级对拍才能钉住。

const std = @import("std");

/// 剩余长度的编码上限：4 字节 × 7 位（MQTT 3.1.1 §2.2.3）。
pub const max_remaining_length: u32 = 268_435_455;

/// 固定头的最大长度：1 字节类型 + 4 字节剩余长度。
pub const max_fixed_header_len: usize = 5;

pub const Error = error{
    BufferTooSmall,
    MalformedPacket,
    RemainingLengthTooLong,
    UnsupportedPacketType,
    InvalidFlags,
    InvalidQos,
    InvalidPacketId,
    InvalidTopicFilter,
    InvalidProtocolName,
    InvalidProtocolLevel,
};

// ---------------------------------------------------------------------------
// 报文类型
// ---------------------------------------------------------------------------

/// 控制报文类型（固定头高 4 位）。0 与 15 是保留值，必须拒绝。
pub const PacketType = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
};

pub fn typeFromByte(b: u8) Error!PacketType {
    const nibble: u4 = @truncate(b >> 4);
    return switch (nibble) {
        0, 15 => error.UnsupportedPacketType,
        else => @fromBackingInt(@intCast(nibble)),
    };
}

/// PUBREL / SUBSCRIBE / UNSUBSCRIBE 的固定头 flags 必须是 0b0010
/// （MQTT-3.6.1-1 / MQTT-3.8.1-1 / MQTT-3.10.1-1），其余类型必须是 0。
pub const fixed_flags_required: u4 = 0b0010;

pub fn flagsValid(t: PacketType, flags: u4) bool {
    return switch (t) {
        .publish => true, // dup/qos/retain 三个字段占满低 3 位
        .pubrel, .subscribe, .unsubscribe => flags == fixed_flags_required,
        else => flags == 0,
    };
}

// ---------------------------------------------------------------------------
// 变长整数（剩余长度）
// ---------------------------------------------------------------------------

/// 把 `value` 编成变长整数写进 `out`，返回写入字节数（1..4）。
///
/// 编码规则：低位在前，每字节 7 位有效 + 1 位续位（0x80 = 还有后续）。
pub fn encodeRemainingLength(out: []u8, value: u32) Error!usize {
    if (value > max_remaining_length) return error.RemainingLengthTooLong;
    var v = value;
    var n: usize = 0;
    while (true) {
        var b: u8 = @intCast(v % 128);
        v /= 128;
        if (v > 0) b |= 0x80;
        if (n >= out.len) return error.BufferTooSmall;
        out[n] = b;
        n += 1;
        if (v == 0) break;
    }
    return n;
}

pub const RemainingLength = struct { value: u32, len: u8 };

/// 从 `in` 的头部解出一个变长整数；**字段还没收全时返回 `null`**。
///
/// 这是流式重组的正确语义：字节不够时我们无法判断“它非法”还是“它还没来完”，
/// 只能等。`decodeRemainingLength()` 是它的严格包装（把 `null` 变成
/// `MalformedPacket`），供“手里已经是完整报文”的调用方使用。
///
/// 拒绝分支（都是**确定**的非法，与“还没收全”严格区分）：
///   1) 第 4 个字节仍带续位 → 编码者想要第 5 个字节，规范不允许；
///   2) 结果超过 268435455（4 字节 × 7 位能表示 2^28-1，恰好是上限，
///      所以超过上限只能来自 5 字节编码）；
///   3) 非最短编码（例如 0x80 0x00 表示 0）——3.1.1 要求用最短形式，
///      这里额外拒绝，避免“同一报文两种字节串”。
pub fn decodeRemainingLengthOrNull(in: []const u8) Error!?RemainingLength {
    var value: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i >= in.len) return null; // 字段还没收全：等，不要判非法
        const b = in[i];
        value |= @as(u32, b & 0x7F) << @intCast(7 * i);
        if ((b & 0x80) == 0) {
            // 非最短编码：多字节却在高位补 0（末字节 == 0 且前面还有字节）。
            if (i > 0 and b == 0) return error.MalformedPacket;
            return .{ .value = value, .len = @intCast(i + 1) };
        }
    }
    return error.RemainingLengthTooLong;
}

/// 严格版：`in` 必须已经包含完整的剩余长度字段，否则报 `MalformedPacket`。
///
/// 用于 `Session.onPacket()`——它拿到的是一条**完整报文**，长度字段缺失
/// 就意味着调用方给的切片是坏的。流式路径请用 `decodeRemainingLengthOrNull`。
pub fn decodeRemainingLength(in: []const u8) Error!RemainingLength {
    return (try decodeRemainingLengthOrNull(in)) orelse error.MalformedPacket;
}

/// 写固定头（类型 + flags + 剩余长度），返回总字节数。
pub fn writeFixedHeader(out: []u8, t: PacketType, flags: u4, remaining: u32) Error!usize {
    if (!flagsValid(t, flags)) return error.InvalidFlags;
    if (out.len < 2) return error.BufferTooSmall;
    out[0] = (@as(u8, @backingInt(t)) << 4) | @as(u8, flags);
    const n = try encodeRemainingLength(out[1..], remaining);
    return 1 + n;
}

// ---------------------------------------------------------------------------
// 小工具：大端 u16 与“长度前缀字符串”（MQTT 的 UTF-8 字符串一律 2 字节长度）
// ---------------------------------------------------------------------------

fn writeU16(out: []u8, v: u16) void {
    out[0] = @intCast(v >> 8);
    out[1] = @intCast(v & 0xFF);
}

fn readU16(in: []const u8) u16 {
    return (@as(u16, in[0]) << 8) | in[1];
}

fn writeStr(out: []u8, pos: *usize, s: []const u8) Error!void {
    if (s.len > 0xFFFF) return error.MalformedPacket;
    if (pos.* + 2 + s.len > out.len) return error.BufferTooSmall;
    writeU16(out[pos.*..], @intCast(s.len));
    @memcpy(out[pos.* + 2 ..][0..s.len], s);
    pos.* += 2 + s.len;
}

fn readStr(in: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* + 2 > in.len) return error.MalformedPacket;
    const len = readU16(in[pos.*..]);
    if (pos.* + 2 + len > in.len) return error.MalformedPacket;
    const s = in[pos.* + 2 ..][0..len];
    pos.* += 2 + len;
    return s;
}

// ---------------------------------------------------------------------------
// CONNECT
// ---------------------------------------------------------------------------

pub const Will = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2 = 0,
    retain: bool = false,
};

pub const ConnectOptions = struct {
    client_id: []const u8,
    keepalive_s: u16 = 60,
    clean_session: bool = true,
    will: ?Will = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// CONNECT 的可变头长度：2 + 4("MQTT") + 1(level) + 1(flags) + 2(keepalive)。
pub const connect_variable_header_len: usize = 10;

/// 编一条 CONNECT，返回总字节数（含固定头）。
///
/// 字节布局（MQTT 3.1.1 §3.1）：
///
///   10 <rem>                     固定头
///   00 04 'M' 'Q' 'T' 'T'        协议名（UTF-8 字符串，2 字节长度）
///   04                           协议级别：3.1.1 == 4
///   <connect flags>              bit0 保留(0) bit1 clean bit2 will bit3-4 will qos
///                                bit5 will retain bit6 password bit7 username
///   00 3C                        保活秒（无符号 16 位）
///   <client id> [will topic] [will payload] [username] [password]
///
/// MQTT-3.1.2-22：没有用户名时不得设置 password 位——这里直接拒绝，
/// 而不是“默默忽略”，因为对端会以 0x04/0x05 断开，根因却在我们这边。
pub fn encodeConnect(out: []u8, opts: ConnectOptions) Error!usize {
    if (opts.password != null and opts.username == null) return error.MalformedPacket;
    if (opts.will) |w| {
        if (w.qos > 2) return error.InvalidQos;
    }

    var flags: u8 = 0;
    if (opts.clean_session) flags |= 0x02;
    if (opts.will) |w| {
        flags |= 0x04;
        flags |= @as(u8, w.qos) << 3;
        if (w.retain) flags |= 0x20;
    }
    if (opts.password != null) flags |= 0x40;
    if (opts.username != null) flags |= 0x80;

    var payload_len: usize = 2 + opts.client_id.len;
    if (opts.will) |w| payload_len += 2 + w.topic.len + 2 + w.payload.len;
    if (opts.username) |u| payload_len += 2 + u.len;
    if (opts.password) |p| payload_len += 2 + p.len;

    const remaining: u32 = @intCast(connect_variable_header_len + payload_len);
    var pos = try writeFixedHeader(out, .connect, 0, remaining);

    writeU16(out[pos..], 4);
    @memcpy(out[pos + 2 ..][0..4], "MQTT");
    pos += 6;
    out[pos] = 4; // 协议级别 3.1.1
    pos += 1;
    out[pos] = flags;
    pos += 1;
    writeU16(out[pos..], opts.keepalive_s);
    pos += 2;

    try writeStr(out, &pos, opts.client_id);
    if (opts.will) |w| {
        try writeStr(out, &pos, w.topic);
        try writeStr(out, &pos, w.payload);
    }
    if (opts.username) |u| try writeStr(out, &pos, u);
    if (opts.password) |p| try writeStr(out, &pos, p);

    return pos;
}

pub const ProtocolVersion = enum(u8) { v3_1_1 = 4 };

pub const ConnectHeader = struct {
    protocol: ProtocolVersion,
    keepalive_s: u16,
    clean_session: bool,
    will_qos: u2,
    will_retain: bool,
    has_will: bool,
    has_password: bool,
    has_username: bool,
};

/// 只解 CONNECT 的可变头（不碰 client id/will/凭据）。
///
/// 板侧不实现 broker，所以这个解码器只用于“自己编码的字节能被自己解回来”
/// 的对拍；真实 broker 会校验协议名、级别、保留位（MQTT-3.1.2-3：
/// 保留位必须为 0，否则断开）。
pub fn decodeConnectHeader(body: []const u8) Error!ConnectHeader {
    if (body.len < connect_variable_header_len) return error.MalformedPacket;
    var pos: usize = 0;
    const name = try readStr(body, &pos);
    if (!std.mem.eql(u8, name, "MQTT")) return error.InvalidProtocolName;
    if (body[pos] != 4) return error.InvalidProtocolLevel;
    pos += 1;
    const flags = body[pos];
    pos += 1;
    if ((flags & 0x01) != 0) return error.InvalidFlags; // 保留位必须为 0
    const keepalive = readU16(body[pos..]);
    const will_qos: u2 = @truncate((flags >> 3) & 0x03);
    return .{
        .protocol = .v3_1_1,
        .keepalive_s = keepalive,
        .clean_session = (flags & 0x02) != 0,
        .will_qos = will_qos,
        .will_retain = (flags & 0x20) != 0,
        .has_will = (flags & 0x04) != 0,
        .has_password = (flags & 0x40) != 0,
        .has_username = (flags & 0x80) != 0,
    };
}

// ---------------------------------------------------------------------------
// CONNACK
// ---------------------------------------------------------------------------

pub const ReturnCode = enum(u8) {
    accepted = 0,
    unacceptable_protocol_version = 1,
    identifier_rejected = 2,
    server_unavailable = 3,
    bad_username_or_password = 4,
    not_authorized = 5,
    _,
};

pub const Connack = struct {
    session_present: bool,
    return_code: ReturnCode,

    pub fn accepted(self: Connack) bool {
        return self.return_code == .accepted;
    }
};

/// 解 CONNACK 的 body（固定头之后的两字节）。
///
/// MQTT-3.2.2-1：连接确认 flags 的 bit7..1 全部保留且必须为 0，
/// 只剩 bit0 = session present。把它们当“有意义的位”读，会在跟真实
/// broker 对接时把保留位当 session_present。
pub fn decodeConnack(body: []const u8) Error!Connack {
    if (body.len != 2) return error.MalformedPacket;
    const ack_flags = body[0];
    if ((ack_flags & 0xFE) != 0) return error.InvalidFlags;
    // MQTT-3.2.2-4（return code != 0 时 session present 必须为 0）不在解码里
    // 预判：解码只回答“这两个字节是什么”，一致性由 connackConsistent() 判。
    return .{
        .session_present = (ack_flags & 0x01) != 0,
        .return_code = @fromBackingInt(@intCast(body[1])),
    };
}

/// MQTT-3.2.2-4：`return code != 0` 时 `session present` 必须为 0。
pub fn connackConsistent(c: Connack) bool {
    if (!c.accepted()) return !c.session_present;
    return true;
}

// ---------------------------------------------------------------------------
// PUBLISH
// ---------------------------------------------------------------------------

pub const Publish = struct {
    topic: []const u8,
    packet_id: u16,
    qos: u2,
    dup: bool,
    retain: bool,
    payload: []const u8,
};

pub fn encodePublish(
    out: []u8,
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    packet_id: u16,
    dup: bool,
    retain: bool,
) Error!usize {
    if (qos > 2) return error.InvalidQos;
    // MQTT-2.3.1-2：QoS > 0 的 PUBLISH 必须带非零 packet id；
    // QoS 0 必须不带（packet id 字段长度为 0）。
    if (qos > 0 and packet_id == 0) return error.InvalidPacketId;

    const variable_len: usize = 2 + topic.len + (if (qos > 0) @as(usize, 2) else 0);
    const remaining: u32 = @intCast(variable_len + payload.len);

    var flags: u4 = 0;
    if (dup) flags |= 0x8;
    flags |= @as(u4, qos) << 1;
    if (retain) flags |= 0x1;

    var pos = try writeFixedHeader(out, .publish, flags, remaining);
    try writeStr(out, &pos, topic);
    if (qos > 0) {
        writeU16(out[pos..], packet_id);
        pos += 2;
    }
    if (pos + payload.len > out.len) return error.BufferTooSmall;
    @memcpy(out[pos..][0..payload.len], payload);
    pos += payload.len;
    return pos;
}

/// 解一条完整的 PUBLISH（`bytes` 从固定头开始，长度必须等于整包长度）。
///
/// 返回的 `topic`/`payload` 是 `bytes` 的切片，不拷贝。
pub fn decodePublish(bytes: []const u8) Error!Publish {
    if (bytes.len < 2) return error.MalformedPacket;
    const t = try typeFromByte(bytes[0]);
    if (t != .publish) return error.MalformedPacket;
    const flags: u4 = @truncate(bytes[0] & 0x0F);
    const qos: u2 = @truncate((flags >> 1) & 0x03);
    if (qos == 3) return error.InvalidQos; // MQTT-3.3.1-4：QoS 3 是协议错误

    const rl = try decodeRemainingLength(bytes[1..]);
    const header_len = 1 + @as(usize, rl.len);
    if (header_len + rl.value != bytes.len) return error.MalformedPacket;

    var pos = header_len;
    const topic = try readStr(bytes, &pos);
    var packet_id: u16 = 0;
    if (qos > 0) {
        if (pos + 2 > bytes.len) return error.MalformedPacket;
        packet_id = readU16(bytes[pos..]);
        pos += 2;
        if (packet_id == 0) return error.InvalidPacketId;
    }
    return .{
        .topic = topic,
        .packet_id = packet_id,
        .qos = qos,
        .dup = (flags & 0x8) != 0,
        .retain = (flags & 0x1) != 0,
        .payload = bytes[pos..],
    };
}

// ---------------------------------------------------------------------------
// PUBACK / PUBREC / PUBREL / PUBCOMP：2 字节 packet id，4 字节整包
// ---------------------------------------------------------------------------

pub fn encodeAck(out: []u8, t: PacketType, packet_id: u16) Error!usize {
    if (packet_id == 0) return error.InvalidPacketId;
    const flags: u4 = switch (t) {
        .puback, .pubrec, .pubcomp => 0,
        .pubrel => fixed_flags_required,
        else => return error.UnsupportedPacketType,
    };
    var pos = try writeFixedHeader(out, t, flags, 2);
    writeU16(out[pos..], packet_id);
    pos += 2;
    return pos;
}

// ---------------------------------------------------------------------------
// SUBSCRIBE / SUBACK / UNSUBSCRIBE
// ---------------------------------------------------------------------------

pub const TopicSubscription = struct {
    filter: []const u8,
    qos: u2 = 0,
};

pub fn encodeSubscribe(out: []u8, subs: []const TopicSubscription, packet_id: u16) Error!usize {
    if (packet_id == 0) return error.InvalidPacketId;
    if (subs.len == 0) return error.MalformedPacket;

    var payload_len: usize = 0;
    for (subs) |s| {
        if (!validateFilter(s.filter)) return error.InvalidTopicFilter;
        if (s.qos > 2) return error.InvalidQos;
        payload_len += 2 + s.filter.len + 1;
    }
    const remaining: u32 = @intCast(2 + payload_len);
    var pos = try writeFixedHeader(out, .subscribe, fixed_flags_required, remaining);
    writeU16(out[pos..], packet_id);
    pos += 2;
    for (subs) |s| {
        try writeStr(out, &pos, s.filter);
        out[pos] = @as(u8, s.qos);
        pos += 1;
    }
    return pos;
}

pub const Suback = struct {
    packet_id: u16,
    /// 逐条对应 SUBSCRIBE 里的过滤器；`0x80` 表示该过滤器被拒绝。
    granted: []const u8,

    pub fn grantedQos(self: Suback, i: usize) ?u2 {
        if (i >= self.granted.len) return null;
        const g = self.granted[i];
        if (g == 0x80) return null;
        return @truncate(g & 0x03);
    }
};

pub fn decodeSuback(body: []const u8) Error!Suback {
    if (body.len < 3) return error.MalformedPacket;
    const packet_id = readU16(body[0..]);
    if (packet_id == 0) return error.InvalidPacketId;
    const granted = body[2..];
    // MQTT-3.9.3-2：只有 0x00/0x01/0x02/0x80 四个值合法。
    for (granted) |g| {
        if (g != 0x00 and g != 0x01 and g != 0x02 and g != 0x80) return error.MalformedPacket;
    }
    return .{ .packet_id = packet_id, .granted = granted };
}

pub fn encodeUnsubscribe(out: []u8, filters: []const []const u8, packet_id: u16) Error!usize {
    if (packet_id == 0) return error.InvalidPacketId;
    if (filters.len == 0) return error.MalformedPacket;
    var payload_len: usize = 0;
    for (filters) |f| {
        if (!validateFilter(f)) return error.InvalidTopicFilter;
        payload_len += 2 + f.len;
    }
    const remaining: u32 = @intCast(2 + payload_len);
    var pos = try writeFixedHeader(out, .unsubscribe, fixed_flags_required, remaining);
    writeU16(out[pos..], packet_id);
    pos += 2;
    for (filters) |f| try writeStr(out, &pos, f);
    return pos;
}

// ---------------------------------------------------------------------------
// 无载荷报文
// ---------------------------------------------------------------------------

pub fn encodePingreq(out: []u8) Error!usize {
    return writeFixedHeader(out, .pingreq, 0, 0);
}

pub fn encodePingresp(out: []u8) Error!usize {
    return writeFixedHeader(out, .pingresp, 0, 0);
}

pub fn encodeDisconnect(out: []u8) Error!usize {
    return writeFixedHeader(out, .disconnect, 0, 0);
}

// ---------------------------------------------------------------------------
// 主题过滤器：合法性 + 匹配
// ---------------------------------------------------------------------------

/// 过滤器合法性（MQTT 3.1.1 §4.7.1）。
///
/// 三条规则，违反任意一条就是“协议错误”，broker 应当断开连接
/// （MQTT-3.8.3-2 要求 SUBSCRIBE 里的过滤器非法时关闭网络连接）：
///
///   1) `#` 必须是过滤器最后一个字符，且独占整个层级（前面要么是开头，
///      要么是 `/`）；`sport/tennis#`、`sport/#/ranking` 都非法；
///   2) `+` 必须独占整个层级；`sport+`、`a/+b` 非法；
///   3) 长度 1..65535，空过滤器非法（长度 0 的 UTF-8 字符串在 3.1.1 里
///      没有意义）。
///
/// 注意：`a//b` 合法（两级空层），`#` 与 `+` 单独使用也合法。
pub fn validateFilter(filter: []const u8) bool {
    if (filter.len == 0 or filter.len > 0xFFFF) return false;
    for (filter, 0..) |c, i| {
        if (c != '#' and c != '+') continue;

        // 当前层级的起点。
        const level_start = if (std.mem.findScalarLast(u8, filter[0..i], '/')) |p| p + 1 else 0;
        const level_end = std.mem.findScalarPos(u8, filter, i, '/') orelse filter.len;

        // 通配符必须独占本层。
        if (level_start != i or level_end != i + 1) return false;

        // '#' 还必须是整个过滤器的最后一个字符。
        if (c == '#' and level_end != filter.len) return false;
    }
    return true;
}

/// 主题过滤器匹配（MQTT 3.1.1 §4.7.2）。
///
/// 两个容易写错的点：
///
///   1) `sport/#` 匹配 `sport` 本身（`#` 包含父层级），而 `sport/+` **不**匹配
///      `sport`——`+` 至少要吃掉一层（且可以是空层：`sport/+` 匹配 `sport/`）。
///   2) 以 `$` 开头的主题不被以 `#` 或 `+` 开头的过滤器命中
///      （MQTT-4.7.2-1），否则 `#` 会把 `$SYS/broker/uptime` 全订阅下来。
pub fn matches(filter: []const u8, topic: []const u8) bool {
    if (filter.len == 0) return false;
    if (topic.len > 0 and topic[0] == '$' and (filter[0] == '#' or filter[0] == '+')) return false;

    var fi: usize = 0;
    var ti: usize = 0;
    while (true) {
        if (fi < filter.len and filter[fi] == '#') return true;

        const f_end = std.mem.findScalarPos(u8, filter, fi, '/') orelse filter.len;
        const t_end = std.mem.findScalarPos(u8, topic, ti, '/') orelse topic.len;
        const f_level = filter[fi..f_end];
        const t_level = topic[ti..t_end];

        const level_ok = std.mem.eql(u8, f_level, "+") or std.mem.eql(u8, f_level, t_level);
        if (!level_ok) return false;

        const f_done = f_end == filter.len;
        const t_done = t_end == topic.len;
        if (f_done and t_done) return true;
        if (f_done) return false;
        if (t_done) {
            // 主题先耗尽：只有剩下的过滤器恰好是 `#` 才算命中（父层规则）。
            return std.mem.eql(u8, filter[f_end + 1 ..], "#");
        }
        fi = f_end + 1;
        ti = t_end + 1;
    }
}

/// 一组过滤器里是否有任意一条命中（多条命中时 broker 只投递一次，
/// 由会话层去重——这里只回答“是否”）。
pub fn matchesAny(filters: []const []const u8, topic: []const u8) bool {
    for (filters) |f| {
        if (matches(f, topic)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 流式重组：TCP 不保证一次读到一整包
// ---------------------------------------------------------------------------
pub const StreamReader = struct {
    buf: []u8,
    len: usize = 0,

    pub const Frame = struct {
        ptype: PacketType,
        flags: u4,
        /// 整包字节数（固定头 + 剩余长度部分）。
        total: usize,
    };

    pub fn init(buf: []u8) StreamReader {
        return .{ .buf = buf };
    }

    pub fn push(self: *StreamReader, bytes: []const u8) Error!void {
        if (self.len + bytes.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// 看头部能拿到多少信息：返回“下一个完整报文”的长度与类型。
    /// 不完整时返回 null（继续 push），头部非法时返回错误。
    /// 头部能拿到多少就报多少：不够就是 `null`（继续 push），
    /// 头部本身非法才是错误。
    ///
    /// 这里**必须**用 `decodeRemainingLengthOrNull`：TCP 最常见的切分点就是
    /// “类型字节到了、剩余长度字段只到了第一个字节”。如果这里用严格版，
    /// `0x30 0x80`（剩余长度 ≥128 的 PUBLISH 前缀）会被误判成非法报文，
    /// 而这恰好是最不该误判的位置。
    pub fn peek(self: *const StreamReader) Error!?Frame {
        if (self.len < 1) return null;
        const ptype = try typeFromByte(self.buf[0]);
        const flags: u4 = @truncate(self.buf[0] & 0x0F);
        if (!flagsValid(ptype, flags)) return error.InvalidFlags;
        const rl = (try decodeRemainingLengthOrNull(self.buf[1..self.len])) orelse return null;
        const header_len = 1 + @as(usize, rl.len);
        const total = header_len + rl.value;
        if (self.len < total) return null;
        return .{ .ptype = ptype, .flags = flags, .total = total };
    }

    /// 取走一个完整报文（返回切片指向内部缓冲）；消费后调用 `consume`。
    pub fn take(self: *StreamReader) Error!?[]const u8 {
        const f = (try self.peek()) orelse return null;
        const out = self.buf[0..f.total];
        return out;
    }

    pub fn consume(self: *StreamReader, n: usize) void {
        std.debug.assert(n <= self.len);
        std.mem.copyForwards(u8, self.buf[0 .. self.len - n], self.buf[n..self.len]);
        self.len -= n;
    }
};

// ---------------------------------------------------------------------------
// 测试辅助：把字节打成十六进制（自检与单测都用来对拍）
// ---------------------------------------------------------------------------

pub fn hexDump(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    const n = @min(bytes.len, out.len / 2);
    for (bytes[0..n], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0F];
    }
    return out[0 .. n * 2];
}
