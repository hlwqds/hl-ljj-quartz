//! ch24-mqtt-ota-application-protocols：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以能在 x86_64 / Zig 0.17.1 上跑，
//! 不需要开发板、不需要 broker、不需要网线。
//!
//! 被测试的三个模块全是纯逻辑：
//!
//!   - `mqtt.zig`    MQTT 3.1.1 固定头 / 剩余长度变长编码（含 4 字节与上界）/
//!                   CONNECT / CONNACK / PUBLISH / 四个 ACK / SUBSCRIBE /
//!                   SUBACK / 主题过滤器合法性与匹配 / 流式重组；
//!   - `session.zig` 连接、心跳（keepalive/2 发 PINGREQ、再等满 keepalive 判死）、
//!                   重传窗口（DUP=1）、inflight 上限背压、QoS2 接收侧去重；
//!   - `ota.zig`     清单编码/解码、SHA-256、Ed25519（RFC 8032 §7.1 TEST 1）、
//!                   版本单调性、A/B 槽位状态机与回滚。
//!
//! 板侧那一只自检（`src/selftest.zig`）复用同样的模块，在 rv32 上把13 条
//! 判据各走一遍；两套测试的边界必须写清楚，不能互相冒充：主机侧负责
//! 边界值与规范向量，板侧只负责“同一份代码在真实 SRAM 布局下跑得出同样结论”。

test {
    _ = @import("mqtt.zig");
    _ = @import("session.zig");
    _ = @import("ota.zig");
}

const std = @import("std");
const testing = std.testing;

const mqtt = @import("mqtt.zig");
const session = @import("session.zig");
const ota = @import("ota.zig");

// ---------------------------------------------------------------------------
// 测试脚手架：把 Session 的发包录进数组
// ---------------------------------------------------------------------------

const Recorder = session.FrameRecorder;

/// 造一个已连接的会话（CONNECT + CONNACK 都走真实字节）。
fn connectedSession(rec: *Recorder, cfg: session.Config) !session.Session {
    var s = session.Session.init(cfg, rec.sink());
    try s.connect("ch24", 0);
    var connack: [4]u8 = undefined;
    _ = try mqtt.writeFixedHeader(&connack, .connack, 0, 2);
    connack[2] = 0;
    connack[3] = 0;
    const ev = try s.onPacket(&connack, 3);
    try testing.expect(ev == .connack);
    try testing.expectEqual(session.State.connected, s.state);
    return s;
}

// ---------------------------------------------------------------------------
// mqtt.zig：剩余长度
// ---------------------------------------------------------------------------

test "remaining length encodes 0/127/128/16383/16384 at the canonical widths" {
    const Case = struct { value: u32, bytes: []const u8 };
    const cases = [_]Case{
        .{ .value = 0, .bytes = &.{0x00} },
        .{ .value = 127, .bytes = &.{0x7F} },
        .{ .value = 128, .bytes = &.{ 0x80, 0x01 } },
        .{ .value = 16383, .bytes = &.{ 0xFF, 0x7F } },
        .{ .value = 16384, .bytes = &.{ 0x80, 0x80, 0x01 } },
        .{ .value = 2_097_151, .bytes = &.{ 0xFF, 0xFF, 0x7F } },
        .{ .value = 2_097_152, .bytes = &.{ 0x80, 0x80, 0x80, 0x01 } },
        .{ .value = mqtt.max_remaining_length, .bytes = &.{ 0xFF, 0xFF, 0xFF, 0x7F } },
    };
    for (cases) |c| {
        var buf: [4]u8 = undefined;
        const n = try mqtt.encodeRemainingLength(&buf, c.value);
        try testing.expectEqual(c.bytes.len, n);
        try testing.expectEqualSlices(u8, c.bytes, buf[0..n]);

        const dec = try mqtt.decodeRemainingLength(&buf);
        try testing.expectEqual(c.value, dec.value);
        try testing.expectEqual(@as(u8, @intCast(c.bytes.len)), dec.len);
    }
}

test "remaining length rejects overflow, five-byte forms and non-minimal encodings" {
    var buf: [8]u8 = undefined;
    try testing.expectError(
        error.RemainingLengthTooLong,
        mqtt.encodeRemainingLength(&buf, mqtt.max_remaining_length + 1),
    );

    // 四个续位字节 = 编码者想要第 5 个字节。
    try testing.expectError(
        error.RemainingLengthTooLong,
        mqtt.decodeRemainingLength(&.{ 0x80, 0x80, 0x80, 0x80 }),
    );

    // 非最短编码：0x80 0x00 表示 0，但规范要求单字节 0x00。
    try testing.expectError(
        error.MalformedPacket,
        mqtt.decodeRemainingLength(&.{ 0x80, 0x00 }),
    );

    // 头部还没收全：不是错误，只是不完整——StreamReader 会等。
    try testing.expectError(error.MalformedPacket, mqtt.decodeRemainingLength(&.{0x80}));
}

test "fixed header flags are enforced per packet type" {
    try testing.expect(mqtt.flagsValid(.publish, 0b1001));
    try testing.expect(mqtt.flagsValid(.subscribe, 0b0010));
    try testing.expect(!mqtt.flagsValid(.subscribe, 0b0000));
    try testing.expect(mqtt.flagsValid(.pingreq, 0));
    try testing.expect(!mqtt.flagsValid(.connect, 0b0010));
    var hdr: [8]u8 = @splat(0);
    try testing.expectError(error.InvalidFlags, mqtt.writeFixedHeader(&hdr, .puback, 0b0010, 2));
}

// ---------------------------------------------------------------------------
// mqtt.zig：CONNECT / CONNACK
// ---------------------------------------------------------------------------

test "CONNECT byte-level KAT for client_id ch24, clean session, keepalive 60" {
    var buf: [64]u8 = undefined;
    const n = try mqtt.encodeConnect(&buf, .{
        .client_id = "ch24",
        .keepalive_s = 60,
        .clean_session = true,
    });
    const expected = [_]u8{
        0x10, 0x10, // CONNECT, remaining length 16
        0x00, 0x04,
        'M',  'Q',
        'T',  'T',
        0x04, // protocol level 3.1.1
        0x02, // connect flags: clean session only
        0x00, 0x3C, // keepalive 60 s
        0x00, 0x04,
        'c',  'h',
        '2',  '4',
    };
    try testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "CONNECT round-trips through the variable header decoder" {
    var buf: [96]u8 = undefined;
    const n = try mqtt.encodeConnect(&buf, .{
        .client_id = "ch24",
        .keepalive_s = 45,
        .clean_session = false,
        .will = .{ .topic = "dev/24/state", .payload = "offline", .qos = 1, .retain = true },
        .username = "user",
        .password = "pass",
    });

    const rl = try mqtt.decodeRemainingLength(buf[1..n]);
    const body = buf[1 + rl.len .. n];
    const h = try mqtt.decodeConnectHeader(body);
    try testing.expectEqual(@as(u16, 45), h.keepalive_s);
    try testing.expect(!h.clean_session);
    try testing.expect(h.has_will);
    try testing.expectEqual(@as(u2, 1), h.will_qos);
    try testing.expect(h.will_retain);
    try testing.expect(h.has_username);
    try testing.expect(h.has_password);
}

test "CONNECT rejects password without username and a set reserved bit" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.MalformedPacket, mqtt.encodeConnect(&buf, .{
        .client_id = "x",
        .password = "p",
    }));

    // 手工拼一条保留位为 1 的 CONNECT 可变头（MQTT-3.1.2-3）。
    var body: [10]u8 = .{ 0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x03, 0x00, 0x3C };
    try testing.expectError(error.InvalidFlags, mqtt.decodeConnectHeader(&body));
    body[7] = 0x02;
    _ = try mqtt.decodeConnectHeader(&body);
}

test "CONNACK decodes session_present and return code, rejects reserved bits" {
    const c = try mqtt.decodeConnack(&.{ 0x01, 0x00 });
    try testing.expect(c.session_present);
    try testing.expect(c.accepted());
    try testing.expect(mqtt.connackConsistent(c));

    const refused = try mqtt.decodeConnack(&.{ 0x00, 0x05 });
    try testing.expect(!refused.accepted());
    try testing.expectEqual(mqtt.ReturnCode.not_authorized, refused.return_code);

    // 保留位非 0
    try testing.expectError(error.InvalidFlags, mqtt.decodeConnack(&.{ 0x02, 0x00 }));
    // return code != 0 却带 session_present（MQTT-3.2.2-4 自相矛盾）
    const bad = try mqtt.decodeConnack(&.{ 0x01, 0x04 });
    try testing.expect(!mqtt.connackConsistent(bad));
}

// ---------------------------------------------------------------------------
// mqtt.zig：PUBLISH 与四个 ACK
// ---------------------------------------------------------------------------

test "PUBLISH QoS0 has no packet id; QoS1 round-trips topic, id and payload" {
    var buf: [128]u8 = undefined;
    const n0 = try mqtt.encodePublish(&buf, "dev/24/temp", "21.5", 0, 0, false, false);
    const p0 = try mqtt.decodePublish(buf[0..n0]);
    try testing.expectEqual(@as(u2, 0), p0.qos);
    try testing.expectEqualStrings("dev/24/temp", p0.topic);
    try testing.expectEqualStrings("21.5", p0.payload);
    try testing.expectEqual(@as(u16, 0), p0.packet_id);

    const n1 = try mqtt.encodePublish(&buf, "dev/24/cmd", "reboot", 1, 0x1234, true, false);
    const p1 = try mqtt.decodePublish(buf[0..n1]);
    try testing.expectEqual(@as(u2, 1), p1.qos);
    try testing.expectEqual(@as(u16, 0x1234), p1.packet_id);
    try testing.expect(p1.dup);
    try testing.expectEqualStrings("reboot", p1.payload);
    // 固定头：type=3, dup=1, qos=1, retain=0 → 0b0011_1010
    try testing.expectEqual(@as(u8, 0x3A), buf[0]);
}

test "PUBLISH rejects QoS 3, zero packet id on QoS>0 and trailing garbage" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.InvalidQos, mqtt.encodePublish(&buf, "t", "x", 3, 1, false, false));
    try testing.expectError(error.InvalidPacketId, mqtt.encodePublish(&buf, "t", "x", 1, 0, false, false));

    // 手工造一条 QoS 3 的 PUBLISH（MQTT-3.3.1-4 要求断开连接）。
    var bad = [_]u8{ 0x36, 0x05, 0x00, 0x01, 't', 0x00, 0x01 };
    try testing.expectError(error.InvalidQos, mqtt.decodePublish(&bad));

    const n = try mqtt.encodePublish(&buf, "t", "x", 0, 0, false, false);
    try testing.expectError(error.MalformedPacket, mqtt.decodePublish(buf[0 .. n - 1]));
}

test "the four acknowledgement packets are four bytes each, PUBREL keeps flags 0b0010" {
    var buf: [8]u8 = undefined;
    inline for ([_]mqtt.PacketType{ .puback, .pubrec, .pubcomp, .pubrel }) |t| {
        const n = try mqtt.encodeAck(&buf, t, 0x0708);
        try testing.expectEqual(@as(usize, 4), n);
        try testing.expectEqual(@as(u8, @backingInt(t)) << 4 | (if (t == .pubrel) @as(u8, 0x02) else 0), buf[0]);
        try testing.expectEqual(@as(u8, 0x02), buf[1]);
        try testing.expectEqual(@as(u8, 0x07), buf[2]);
        try testing.expectEqual(@as(u8, 0x08), buf[3]);
    }
    try testing.expectError(error.InvalidPacketId, mqtt.encodeAck(&buf, .puback, 0));
}

// ---------------------------------------------------------------------------
// mqtt.zig：SUBSCRIBE / SUBACK
// ---------------------------------------------------------------------------

test "SUBSCRIBE carries two filters and SUBACK maps granted QoS with 0x80 failure" {
    var buf: [128]u8 = undefined;
    const subs = [_]mqtt.TopicSubscription{
        .{ .filter = "dev/24/+", .qos = 1 },
        .{ .filter = "ota/#", .qos = 2 },
    };
    const n = try mqtt.encodeSubscribe(&buf, &subs, 0x000A);
    try testing.expectEqual(@as(u8, 0x82), buf[0]); // SUBSCRIBE + flags 0010
    const rl = try mqtt.decodeRemainingLength(buf[1..n]);
    // remaining = packet id(2) + [len(2) + "dev/24/+"(8) + qos(1)] + [len(2) + "ota/#"(5) + qos(1)]
    try testing.expectEqual(@as(u32, 2 + (2 + 8 + 1) + (2 + 5 + 1)), rl.value);

    const suback = try mqtt.decodeSuback(&.{ 0x00, 0x0A, 0x01, 0x80 });
    try testing.expectEqual(@as(u16, 10), suback.packet_id);
    try testing.expectEqual(@as(?u2, 1), suback.grantedQos(0));
    try testing.expectEqual(@as(?u2, null), suback.grantedQos(1)); // 0x80 = 拒绝

    // MQTT-3.9.3-2：只允许 0x00/0x01/0x02/0x80。
    try testing.expectError(error.MalformedPacket, mqtt.decodeSuback(&.{ 0x00, 0x0A, 0x03 }));
    // 非法过滤器（'#' 不在末尾）在编码阶段就拒绝。
    const bad = [_]mqtt.TopicSubscription{.{ .filter = "ota/#/x", .qos = 0 }};
    try testing.expectError(error.InvalidTopicFilter, mqtt.encodeSubscribe(&buf, &bad, 1));
}

// ---------------------------------------------------------------------------
// mqtt.zig：主题过滤器
// ---------------------------------------------------------------------------

test "topic filter validity follows the # and + placement rules" {
    const valid = [_][]const u8{ "#", "+", "a/#", "a/+", "a/+/c", "sport/tennis/#", "a//b", "/", "/finance", "+/+" };
    for (valid) |f| try testing.expect(mqtt.validateFilter(f));

    const invalid = [_][]const u8{ "", "a/b#", "a/#/b", "sport/tennis#", "a/+b", "sport+", "##", "a/+/#/b" };
    for (invalid) |f| try testing.expect(!mqtt.validateFilter(f));
}

test "topic matching: + eats one level, # eats the rest including the parent" {
    try testing.expect(mqtt.matches("a/+/c", "a/b/c"));
    try testing.expect(!mqtt.matches("a/+/c", "a/b/d"));
    try testing.expect(!mqtt.matches("a/+/c", "a/b/c/d"));
    try testing.expect(mqtt.matches("a/+/c", "a//c")); // 空层也是合法的一层

    try testing.expect(mqtt.matches("a/#", "a/b/c"));
    try testing.expect(mqtt.matches("a/#", "a"));
    try testing.expect(!mqtt.matches("a/+", "a"));
    try testing.expect(mqtt.matches("a/+", "a/"));
    try testing.expect(mqtt.matches("#", "a/b/c"));
    try testing.expect(!mqtt.matches("#", "$SYS/broker/uptime"));
    try testing.expect(!mqtt.matches("+/broker", "$SYS/broker"));
    try testing.expect(mqtt.matches("$SYS/#", "$SYS/broker/uptime"));
    try testing.expect(mqtt.matches("sport/tennis/player1/#", "sport/tennis/player1"));
    try testing.expect(mqtt.matchesAny(&.{ "x/y", "a/+/c" }, "a/q/c"));
}

// ---------------------------------------------------------------------------
// mqtt.zig：流式重组
// ---------------------------------------------------------------------------

test "StreamReader waits while the remaining-length field is incomplete" {
    // 剩余长度 135 → 两个字节 0x87 0x01，第一个字节带续位。这条报文的
    // 头部切分点正好落在“长度字段中间”，是 TCP 下最常见的一种切分。
    var payload: [120]u8 = undefined;
    @memset(&payload, 'x');

    var buf: [256]u8 = undefined;
    var wire: [256]u8 = undefined;
    const n = try mqtt.encodePublish(&wire, "dev/24/temp", &payload, 1, 0x0102, false, false);
    try testing.expectEqual(@as(u8, 0x87), wire[1]);
    try testing.expectEqual(@as(u8, 0x01), wire[2]);

    // 两个契约必须分开：严格版把“不完整”当坏报文，可空版把它当“继续等”。
    try testing.expectEqual(@as(?mqtt.RemainingLength, null), try mqtt.decodeRemainingLengthOrNull(&.{0x87}));
    try testing.expectError(error.MalformedPacket, mqtt.decodeRemainingLength(&.{0x87}));
    try testing.expectError(error.RemainingLengthTooLong, mqtt.decodeRemainingLengthOrNull(&.{ 0x80, 0x80, 0x80, 0x80 }));

    var reader = mqtt.StreamReader.init(&buf);
    try reader.push(wire[0..1]); // 只有类型字节
    try testing.expectEqual(@as(?mqtt.StreamReader.Frame, null), try reader.peek());
    try reader.push(wire[1..2]); // 只有长度字段的第一个字节 0x87
    try testing.expectEqual(@as(?mqtt.StreamReader.Frame, null), try reader.peek());
    try reader.push(wire[2..8]); // 长度字段齐了，报文体还不够
    try testing.expectEqual(@as(?mqtt.StreamReader.Frame, null), try reader.peek());
    try reader.push(wire[8..n]);

    const frame = (try reader.peek()).?;
    try testing.expectEqual(mqtt.PacketType.publish, frame.ptype);
    try testing.expectEqual(n, frame.total);
    const bytes = (try reader.take()).?;
    const p = try mqtt.decodePublish(bytes);
    try testing.expectEqual(@as(u16, 0x0102), p.packet_id);
    try testing.expectEqual(payload.len, p.payload.len);
    reader.consume(frame.total);
    try testing.expectEqual(@as(usize, 0), reader.len);
}

// ---------------------------------------------------------------------------
// session.zig
// ---------------------------------------------------------------------------

test "session retransmits an unacknowledged QoS1 PUBLISH with DUP=1 and stops on PUBACK" {
    var rec: Recorder = .{};
    var s = try connectedSession(&rec, .{ .retry_ms = 1000 });

    const id = try s.publish("dev/24/cmd", "on", 1, 10);
    try testing.expectEqual(@as(u16, 1), id);
    try testing.expectEqual(@as(u8, 1), s.inflightCount());
    try testing.expectEqual(@as(u2, 1), (try mqtt.decodePublish(rec.last())).qos);
    try testing.expect(!(try mqtt.decodePublish(rec.last())).dup);

    // 未到重传窗口：tick 不发任何东西。
    const before = rec.count;
    try s.tick(1000);
    try testing.expectEqual(before, rec.count);

    // 到窗口：重发，且 DUP=1（MQTT-3.3.1-1）。
    try s.tick(1010);
    try testing.expectEqual(before + 1, rec.count);
    const dup = try mqtt.decodePublish(rec.last());
    try testing.expect(dup.dup);
    try testing.expectEqual(id, dup.packet_id);

    // PUBACK 之后槽位释放，不再重传。
    _ = try s.onPacket(&.{ 0x40, 0x02, 0x00, 0x01 }, 1020);
    try testing.expectEqual(@as(u8, 0), s.inflightCount());
    const after_ack = rec.count;
    try s.tick(5000);
    try testing.expectEqual(after_ack, rec.count);
}

test "session QoS2 outbound walks PUBLISH -> PUBREC -> PUBREL -> PUBCOMP" {
    var rec: Recorder = .{};
    var s = try connectedSession(&rec, .{});

    _ = try s.publish("ota/chunk", "x", 2, 0);
    try testing.expectEqual(@as(u8, 2), (try mqtt.decodePublish(rec.last())).qos);

    _ = try s.onPacket(&.{ 0x50, 0x02, 0x00, 0x01 }, 1); // PUBREC
    try testing.expectEqual(@as(u8, 0x62), rec.last()[0]); // PUBREL, flags 0010
    try testing.expectEqual(@as(u8, 1), s.inflightCount());

    _ = try s.onPacket(&.{ 0x70, 0x02, 0x00, 0x01 }, 2); // PUBCOMP
    try testing.expectEqual(@as(u8, 0), s.inflightCount());
}

test "session Qos2 inbound dedup: duplicate PUBLISH is acknowledged but not redelivered" {
    var rec: Recorder = .{};
    var s = try connectedSession(&rec, .{});

    var wire: [64]u8 = undefined;
    const n = try mqtt.encodePublish(&wire, "dev/24/in", "payload", 2, 7, false, false);

    const first = try s.onPacket(wire[0..n], 100);
    try testing.expectEqual(false, first.publish.duplicate);
    try testing.expectEqual(@as(u8, 0x50), rec.last()[0]); // PUBREC

    const again = try mqtt.encodePublish(&wire, "dev/24/in", "payload", 2, 7, true, false);
    const second = try s.onPacket(wire[0..again], 110);
    try testing.expectEqual(true, second.publish.duplicate);
    try testing.expectEqual(@as(u8, 0x50), rec.last()[0]); // 仍然回 PUBREC
    try testing.expectEqual(@as(u32, 1), s.stat_qos2_dups);

    // PUBREL → PUBCOMP，并清掉去重记录。
    _ = try s.onPacket(&.{ 0x62, 0x02, 0x00, 0x07 }, 120);
    try testing.expectEqual(@as(u8, 0x70), rec.last()[0]);
    try testing.expectEqual(@as(u8, 0), s.rx_qos2_count);

    // 同一个 id 在 PUBREL 之后可以重新当新消息（发送方重新启用该 id）。
    const third = try s.onPacket(wire[0..n], 130);
    try testing.expectEqual(false, third.publish.duplicate);
}

test "session enforces the inflight window and frees it on PUBACK (backpressure)" {
    var rec: Recorder = .{};
    var s = try connectedSession(&rec, .{ .max_inflight = 4 });

    for (0..4) |i| {
        var topic_buf: [16]u8 = undefined;
        const topic = try std.fmt.bufPrint(&topic_buf, "dev/24/{d}", .{i});
        _ = try s.publish(topic, "x", 1, 0);
    }
    try testing.expect(s.windowFull());
    try testing.expectError(error.InflightFull, s.publish("dev/24/full", "x", 1, 0));

    // QoS0 不占窗口：窗口满时仍然能发（它没有确认，也就没有在途状态）。
    const ok0 = try s.publish("dev/24/fire_and_forget", "x", 0, 0);
    try testing.expectEqual(@as(u16, 0), ok0);

    _ = try s.onPacket(&.{ 0x40, 0x02, 0x00, 0x01 }, 10);
    try testing.expect(!s.windowFull());
    _ = try s.publish("dev/24/after", "x", 1, 11);
}

test "session keepalive pings at half the interval and fails the link at 1.5x" {
    var rec: Recorder = .{};
    var s = try connectedSession(&rec, .{ .keepalive_s = 60 });

    // 半程（30 s）之前不发心跳。
    const before = rec.count;
    try s.tick(29_999);
    try testing.expectEqual(before, rec.count);

    // 到 30 s：一条 PINGREQ（0xC0 0x00）。
    try s.tick(30_000);
    try testing.expectEqual(before + 1, rec.count);
    try testing.expectEqualSlices(u8, &.{ 0xC0, 0x00 }, rec.last());
    try testing.expect(s.awaiting_pingresp);

    // 再过 60 s 仍无 PINGRESP → 链路判死（总预算 1.5×keepalive）。
    try s.tick(90_000);
    try testing.expectEqual(session.State.failed, s.state);
    const dead = rec.count;
    try s.tick(200_000); // failed 之后不再发包
    try testing.expectEqual(dead, rec.count);
}

test "session declines to publish before CONNACK and after a refused CONNACK" {
    var rec: Recorder = .{};
    var s = session.Session.init(.{}, rec.sink());
    try s.connect("ch24", 0);
    try testing.expectError(error.NotConnected, s.publish("t", "x", 0, 1));

    _ = try s.onPacket(&.{ 0x20, 0x02, 0x00, 0x05 }, 2); // CONNACK not authorised
    try testing.expectEqual(session.State.failed, s.state);
    try testing.expectError(error.NotConnected, s.publish("t", "x", 0, 3));
}

// ---------------------------------------------------------------------------
// ota.zig：清单、摘要、签名
// ---------------------------------------------------------------------------

test "sha256 of abc matches the FIPS 180-4 vector" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try testing.expectEqualSlices(u8, &expected, &digest);
}

test "Ed25519 fixture key pair reproduces RFC 8032 7.1 TEST 1" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(ota.trust_seed);
    const pub_bytes = kp.public_key.toBytes();
    try testing.expectEqualSlices(u8, &ota.trusted_key, &pub_bytes);

    const sig = try kp.sign("", null);
    const expected = [_]u8{
        0xe5, 0x56, 0x43, 0x00, 0xc3, 0x60, 0xac, 0x72,
        0x90, 0x86, 0xe2, 0xcc, 0x80, 0x6e, 0x82, 0x8a,
        0x84, 0x87, 0x7f, 0x1e, 0xb8, 0xe5, 0xd9, 0x74,
        0xd8, 0x73, 0xe0, 0x65, 0x22, 0x49, 0x01, 0x55,
        0x5f, 0xb8, 0x82, 0x15, 0x90, 0xa3, 0x3b, 0xac,
        0xc6, 0x1e, 0x39, 0x70, 0x1c, 0xf9, 0xb4, 0x6b,
        0xd2, 0x5b, 0xf5, 0xf0, 0x59, 0x5b, 0xbe, 0x24,
        0x65, 0x51, 0x41, 0x43, 0x8e, 0x7a, 0x10, 0x0b,
    };
    const sig_bytes = sig.toBytes();
    try testing.expectEqualSlices(u8, &expected, &sig_bytes);
}

test "OTA manifest verifies a sealed image and rejects every tamper path" {
    var image: [512]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var manifest_buf: [ota.manifest_len]u8 = undefined;
    _ = try ota.seal(&manifest_buf, 7, &image, ota.trust_seed);

    const m = try ota.verify(&manifest_buf, &image);
    try testing.expectEqual(@as(u32, 7), m.version);
    try testing.expectEqual(@as(u32, 512), m.image_len);
    try ota.checkVersion(6, m.version);
    try testing.expectError(error.Downgrade, ota.checkVersion(7, m.version));

    // 镜像内容篡改 → 摘要先炸。
    var tampered = image;
    tampered[100] ^= 0x01;
    try testing.expectError(error.Sha256Mismatch, ota.verify(&manifest_buf, &tampered));

    // 长度不符 → 在摘要之前就拒。
    try testing.expectError(error.LengthMismatch, ota.verify(&manifest_buf, image[0..511]));

    // 版本号被改 → 摘要仍然对（摘要只覆盖 image），但签名覆盖了版本号。
    var bumped = manifest_buf;
    bumped[4] +%= 1;
    try testing.expectError(error.BadSignature, ota.verify(&bumped, &image));

    // 签名本身翻一位 → BadSignature。
    var bad_sig = manifest_buf;
    bad_sig[ota.signed_len] ^= 0x80;
    try testing.expectError(error.BadSignature, ota.verify(&bad_sig, &image));

    // 魔数错 → 连解都不给解。
    var bad_magic = manifest_buf;
    bad_magic[0] = 'X';
    try testing.expectError(error.BadMagic, ota.verify(&bad_magic, &image));
}

// ---------------------------------------------------------------------------
// ota.zig：A/B 与回滚
// ---------------------------------------------------------------------------

test "A/B: three consecutive runtime failures roll back from B to A" {
    var ab = ota.Rollback.init(.{ .max_runtime_failures = 3 });
    try testing.expectEqual(ota.Slot.a, ab.active);
    try testing.expectEqual(ota.SlotState.valid, ab.activeState());

    try ab.stage(.b);
    try testing.expectEqual(ota.SlotState.new, ab.slots[@backingInt(ota.Slot.b)].state);
    try ab.setBootSlot(.b);
    try testing.expectEqual(ota.Slot.b, ab.active);
    try testing.expectEqual(ota.SlotState.pending_verify, ab.activeState());

    ab.noteFailure();
    ab.noteFailure();
    try testing.expectEqual(ota.Slot.b, ab.active); // 还没到预算
    ab.noteFailure();
    try testing.expectEqual(ota.Slot.a, ab.active); // 第三次失败 → 回滚
    try testing.expectEqual(ota.SlotState.invalid, ab.slots[@backingInt(ota.Slot.b)].state);
    try testing.expectEqual(ota.SlotState.valid, ab.activeState());
    try testing.expectEqual(@as(u8, 1), ab.rollbacks);

    // 回滚之后 A 继续跑，不再计数（否则一次偶发失败会连锁回滚）。
    ab.noteFailure();
    try testing.expectEqual(ota.Slot.a, ab.active);
    try testing.expectEqual(@as(u8, 1), ab.rollbacks);
}

test "A/B: a slot that never confirms is aborted after the boot budget" {
    var ab = ota.Rollback.init(.{ .max_boot_attempts = 2 });
    try ab.stage(.b);
    try ab.setBootSlot(.b);

    ab.onBoot(); // 第二次启动，仍是 pending
    try testing.expectEqual(ota.Slot.b, ab.active);
    try testing.expectEqual(ota.SlotState.pending_verify, ab.activeState());

    ab.onBoot(); // 第三次启动 > 预算 → aborted + 回滚
    try testing.expectEqual(ota.Slot.a, ab.active);
    try testing.expectEqual(ota.SlotState.aborted, ab.slots[@backingInt(ota.Slot.b)].state);
    try testing.expectEqual(@as(u8, 1), ab.rollbacks);
}

test "A/B: markValid pins the new slot and staging the active slot is refused" {
    var ab = ota.Rollback.init(.{});
    try ab.stage(.b);
    try ab.setBootSlot(.b);
    ab.markValid();
    try testing.expectEqual(ota.SlotState.valid, ab.activeState());
    try testing.expectEqual(@as(u8, 0), ab.slots[@backingInt(ota.Slot.b)].boot_attempts);

    // 已经确认的槽不会再被启动计数判死。
    ab.onBoot();
    ab.onBoot();
    ab.onBoot();
    try testing.expectEqual(ota.Slot.b, ab.active);
    try testing.expectEqual(@as(u8, 0), ab.rollbacks);

    try testing.expectError(error.SlotIsActive, ab.stage(.b));
    try testing.expectError(error.NotStaged, ab.setBootSlot(.a)); // A 的 state 仍是 valid，不是 new
}
