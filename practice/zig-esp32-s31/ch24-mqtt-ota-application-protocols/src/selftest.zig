//! ch24-mqtt-ota-application-protocols：板侧自检（13 条判据）。
//!
//! 本章没有可用的真实链路（ch17 的以太网驱动未闭环：DMA 软复位超时、
//! MDIO 扫不到 PHY），也没有 Wi-Fi 链路，更**不写 flash**。因此板侧的
//! 唯一证据形态是：把与 MQTT 报文 / 会话时序 / OTA 清单 / A/B 回滚有关的
//! 确定性部分各走一遍，打印判读行。
//!
//! 这里**没有**“连上 broker”“订阅成功”“OTA 升级完成”“固件已写进 flash”。
//! 会话里的字节全部发给我自己挂的录制器；镜像与清单都在 `.bss` 里。
//! 任何声称“板子真的跟服务器握了手”的读数都是伪造的。
//!
//! 13 条判据（每条一行 `check: ... ok=1/0`）：
//!
//!   ① CONNECT 的字节级已知答案（client_id=ch24 / clean / keepalive 60）
//!   ② 剩余长度：0/127/128/16383/16384/268435455 的宽度、上界拒绝、5 字节拒绝
//!   ③ CONNACK 解码：session present / 返回码 / 保留位拒绝
//!   ④ PUBLISH QoS1 + PUBACK：packet id 往返
//!   ⑤ QoS2 四步（PUBLISH→PUBREC→PUBREL→PUBCOMP）与重复 PUBLISH 去重
//!   ⑥ SUBSCRIBE（两条过滤器）+ SUBACK（含 0x80 拒绝）
//!   ⑦ 主题匹配：`a/+/c`、`a/#`（含父层）、`sport/#`，以及两条非法过滤器
//!   ⑧ 心跳：keepalive/2 发 PINGREQ，再等满 keepalive 判链路死亡
//!   ⑨ OTA 清单：SHA-256 通过 / 镜像篡改失败 / 版本降级拒绝
//!   ⑩ Ed25519：RFC 8032 向量的公钥与签名验过 / 签名翻一位失败
//!   ⑪ A/B：B 启动后连续三次失败 → 标 invalid 并回滚到 A
//!   ⑫ 会话 inflight 上限：第 5 条被拒，PUBACK 之后腾出槽位
//!   ⑬ 流式重组：一条 136 字节 PUBLISH 分四次推入，其中前三次都“还没齐”
//!      （含剩余长度字段只到第一个字节 `0x87` 的最坏切分点）→ 最后拼回整包
//!
//! 另有几行 `read:` 前缀的读数（报文前缀、清单摘要前缀），它们不是判据，
//! 只是让日志能被人肉眼对拍。
//!
//! 所有缓冲都是 `.bss` 里的静态对象：板侧没有分配器，自检也不该依赖
//! `error.OutOfMemory` 才能跑到 verdict。

const std = @import("std");

const mqtt = @import("mqtt.zig");
const session = @import("session.zig");
const ota = @import("ota.zig");
const log = @import("log.zig");

// ---------------------------------------------------------------------------
// 静态工作区（.bss）
// ---------------------------------------------------------------------------
var g_wire: [512]u8 = undefined; // 一条报文的编码缓冲
var g_rx: [512]u8 = undefined; // 入站报文（自造）
var g_stream: [512]u8 = undefined; // StreamReader 的重组缓冲
var g_image: [512]u8 = undefined; // OTA 镜像副本（篡改用）
var g_manifest: [ota.manifest_len]u8 = undefined;
var g_rec: session.FrameRecorder = .{};

/// ⑬ 的载荷：放在 .rodata（`const`），不进 `.bss` 的账。
const stream_payload: [120]u8 = @splat('x');

var g_passed: u32 = 0;
var g_failed: u32 = 0;

// ---------------------------------------------------------------------------
// 判据记录
// ---------------------------------------------------------------------------

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [170]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn read(comptime fmt: []const u8, args: anytype) void {
    log.line("read: " ++ fmt, args);
}

/// 十六进制前缀。缓冲由调用方给：同一条日志里要打两个前缀时，
/// 共用一个静态缓冲会让前一个被后一个覆盖（这里踩过一次）。
fn hexInto(buf: []u8, bytes: []const u8) []const u8 {
    return mqtt.hexDump(buf, bytes);
}

/// 造一个“已完成 CONNECT/CONNACK”的会话。CONNACK 走真实字节，
/// 不直接改 `state` 字段——否则测的就不是状态机而是赋值。
fn connected(cfg: session.Config) !session.Session {
    g_rec.reset();
    var s = session.Session.init(cfg, g_rec.sink());
    try s.connect("ch24", 0);

    var connack: [4]u8 = undefined;
    _ = try mqtt.writeFixedHeader(&connack, .connack, 0, 2);
    connack[2] = 0;
    connack[3] = 0;
    _ = try s.onPacket(&connack, 1);
    return s;
}

// ---------------------------------------------------------------------------
// ① CONNECT 字节级 KAT
// ---------------------------------------------------------------------------

fn c01_connectKat() void {
    var ok = false;
    var n: usize = 0;
    var keepalive: u16 = 0;
    if (mqtt.encodeConnect(&g_wire, .{
        .client_id = "ch24",
        .keepalive_s = 60,
        .clean_session = true,
    })) |len| {
        n = len;
        const expected = [_]u8{
            0x10, 0x10, // CONNECT + remaining length 16
            0x00, 0x04,
            'M',  'Q',
            'T',  'T',
            0x04, // protocol level 3.1.1
            0x02, // connect flags: clean session
            0x00, 0x3C, // keepalive 60
            0x00, 0x04,
            'c',  'h',
            '2',  '4',
        };
        const same = n == expected.len and std.mem.eql(u8, g_wire[0..n], &expected);
        if (mqtt.decodeRemainingLength(g_wire[1..n])) |rl| {
            if (mqtt.decodeConnectHeader(g_wire[1 + rl.len .. n])) |h| {
                keepalive = h.keepalive_s;
            } else |_| {}
        } else |_| {}
        ok = same and keepalive == 60;
    } else |_| {}

    var h: [24]u8 = undefined;
    check(ok, "mqtt connect kat len={d} ka={d} bytes={s}", .{ n, keepalive, hexInto(&h, g_wire[0..@min(n, 10)]) });
    var full: [40]u8 = undefined;
    read("mqtt connect kat_full={s}", .{hexInto(&full, g_wire[0..n])});
}

// ---------------------------------------------------------------------------
// ② 剩余长度
// ---------------------------------------------------------------------------

fn c02_remainingLength() void {
    const values = [_]u32{ 0, 127, 128, 16383, 16384, 268_435_455 };
    const widths = [_]usize{ 1, 1, 2, 2, 3, 4 };
    var ok = true;
    var actual: [16]u8 = undefined;
    var pos: usize = 0;
    for (values, widths) |v, want| {
        var buf: [4]u8 = undefined;
        const n = mqtt.encodeRemainingLength(&buf, v) catch {
            ok = false;
            continue;
        };
        const dec = mqtt.decodeRemainingLength(&buf) catch {
            ok = false;
            continue;
        };
        if (n != want or dec.value != v or dec.len != n) ok = false;
        if (pos < actual.len) {
            actual[pos] = @intCast('0' + n);
            pos += 1;
        }
    }

    var scratch: [4]u8 = @splat(0);
    const over = mqtt.encodeRemainingLength(&scratch, mqtt.max_remaining_length + 1);
    const over_ok = if (over) |_| false else |e| e == error.RemainingLengthTooLong;
    const five = mqtt.decodeRemainingLength(&.{ 0x80, 0x80, 0x80, 0x80 });
    const five_ok = if (five) |_| false else |e| e == error.RemainingLengthTooLong;

    check(ok and over_ok and five_ok, "mqtt rem-len widths={s} max=1 over=rej five=rej", .{actual[0..pos]});
}

// ---------------------------------------------------------------------------
// ③ CONNACK
// ---------------------------------------------------------------------------

fn c03_connack() void {
    var ok = false;
    var sp: u8 = 0;
    var rc: u8 = 0xFF;
    var refuse: []const u8 = "?";
    if (mqtt.decodeConnack(&.{ 0x01, 0x00 })) |c| {
        sp = @intFromBool(c.session_present);
        rc = @backingInt(c.return_code);
    } else |_| {}
    if (mqtt.decodeConnack(&.{ 0x00, 0x05 })) |c| {
        refuse = if (c.return_code == .not_authorized) "not_authorized" else "other";
    } else |_| {}
    const reserved = mqtt.decodeConnack(&.{ 0x02, 0x00 });
    const reserved_ok = if (reserved) |_| false else |e| e == error.InvalidFlags;
    ok = sp == 1 and rc == 0 and std.mem.eql(u8, refuse, "not_authorized") and reserved_ok;

    check(ok, "mqtt connack sp={d} rc={d} refuse={s} reserved=rej", .{ sp, rc, refuse });
}

// ---------------------------------------------------------------------------
// ④ PUBLISH QoS1 + PUBACK
// ---------------------------------------------------------------------------

fn c04_publishQos1() void {
    var ok = false;
    var id: u16 = 0;
    var payload: []const u8 = "";
    if (mqtt.encodePublish(&g_wire, "dev/24/cmd", "on", 1, 0x0102, false, false)) |n| {
        if (mqtt.decodePublish(g_wire[0..n])) |p| {
            id = p.packet_id;
            payload = p.payload;
        } else |_| {}
    } else |_| {}

    var ack: [8]u8 = undefined;
    var ack_buf: [12]u8 = undefined;
    var ack_len: usize = 0;
    var ack_hex: []const u8 = "";
    if (mqtt.encodeAck(&ack, .puback, 0x0102)) |n| {
        ack_len = n;
        ack_hex = hexInto(&ack_buf, ack[0..n]);
    } else |_| {}

    ok = id == 0x0102 and std.mem.eql(u8, payload, "on") and ack_len == 4 and
        std.mem.eql(u8, ack_hex, "40020102");
    check(ok, "mqtt publish qos1 id={d} payload={s} puback={s}", .{ id, payload, ack_hex });
}

// ---------------------------------------------------------------------------
// ⑤ QoS2 四步 + 去重
// ---------------------------------------------------------------------------

fn c05_qos2() void {
    // 出站四步：PUBLISH → (PUBREC 入) → PUBREL 出 → (PUBCOMP 入)。
    var s = connected(.{}) catch return check(false, "mqtt qos2 steps=0 ok", .{});
    const pub_id = s.publish("ota/chunk", "block0", 2, 10) catch 0;
    _ = s.onPacket(&.{ 0x50, 0x02, 0x00, 0x01 }, 11) catch {};
    var pubrel_buf: [12]u8 = undefined;
    const pubrel_hex = hexInto(&pubrel_buf, g_rec.last());
    const pubrel_ok = g_rec.last().len == 4 and g_rec.last()[0] == 0x62;
    _ = s.onPacket(&.{ 0x70, 0x02, 0x00, 0x01 }, 12) catch {};
    const freed = s.inflightCount() == 0;

    // 入站去重：同一 id 的 QoS2 PUBLISH 第二次只回 PUBREC，不再上抛。
    var delivered: u8 = 0;
    var dup: u8 = 0;
    var wire_len: usize = 0;
    if (mqtt.encodePublish(&g_rx, "dev/24/in", "payload", 2, 7, false, false)) |n| {
        wire_len = n;
        if (s.onPacket(g_rx[0..n], 20)) |ev| {
            if (!ev.publish.duplicate) delivered += 1;
        } else |_| {}
        // DUP=1 的重发：同一个 packet id。
        if (mqtt.encodePublish(&g_rx, "dev/24/in", "payload", 2, 7, true, false)) |n2| {
            if (s.onPacket(g_rx[0..n2], 21)) |ev| {
                if (ev.publish.duplicate) {
                    dup += 1;
                } else {
                    delivered += 1;
                }
            } else |_| {}
        } else |_| {}
        // PUBREL → PUBCOMP，并清掉去重记录。
        _ = s.onPacket(&.{ 0x62, 0x02, 0x00, 0x07 }, 22) catch {};
    } else |_| {}

    const pubcomp_ok = g_rec.last().len == 4 and g_rec.last()[0] == 0x70;
    const ok = pub_id == 1 and pubrel_ok and freed and delivered == 1 and dup == 1 and
        pubcomp_ok and wire_len > 0;
    check(ok, "mqtt qos2 pubrel={s} delivered={d} dup={d} pubcomp=1", .{ pubrel_hex, delivered, dup });
}

// ---------------------------------------------------------------------------
// ⑥ SUBSCRIBE + SUBACK
// ---------------------------------------------------------------------------

fn c06_subscribe() void {
    const subs = [_]mqtt.TopicSubscription{
        .{ .filter = "dev/24/+", .qos = 1 },
        .{ .filter = "ota/#", .qos = 2 },
    };
    var ok = false;
    var sub_id: u16 = 0;
    if (mqtt.encodeSubscribe(&g_wire, &subs, 0x000A)) |n| {
        ok = n > 2 and g_wire[0] == 0x82;
    } else |_| {
        return check(false, "mqtt subscribe encode failed ok", .{});
    }
    if (mqtt.decodeSuback(&.{ 0x00, 0x0A, 0x01, 0x80 })) |s| {
        sub_id = s.packet_id;
        const g0 = s.grantedQos(0);
        const g1 = s.grantedQos(1);
        ok = ok and sub_id == 10 and g0 == 1 and g1 == null;
    } else |_| {
        ok = false;
    }
    check(ok, "mqtt subscribe filters=2 id={d} granted=1,rej", .{sub_id});
}

// ---------------------------------------------------------------------------
// ⑦ 主题匹配
// ---------------------------------------------------------------------------

fn c07_topic() void {
    const plus_hit = mqtt.matches("a/+/c", "a/b/c");
    const plus_miss = mqtt.matches("a/+/c", "a/b/d");
    const hash_parent = mqtt.matches("a/#", "a");
    const hash_hit = mqtt.matches("a/#", "a/b/c");
    const sport = mqtt.matches("sport/tennis/#", "sport/tennis/player1");
    const dollar = mqtt.matches("#", "$SYS/broker/uptime");
    const bad_hash = mqtt.validateFilter("a/b#");
    const bad_plus = mqtt.validateFilter("a/+b");
    const good = mqtt.validateFilter("a/+/c");

    const ok = plus_hit and !plus_miss and hash_parent and hash_hit and sport and
        !dollar and !bad_hash and !bad_plus and good;
    check(ok, "mqtt topic a/+/c=1 a/b/d=0 a/#(a)=1 sport/#=1 $SYS=0 invalid=2", .{});
}

// ---------------------------------------------------------------------------
// ⑧ 心跳
// ---------------------------------------------------------------------------

fn c08_keepalive() void {
    var s = connected(.{ .keepalive_s = 60 }) catch return check(false, "session keepalive connect failed ok", .{});
    const base = g_rec.count;

    s.tick(29_999) catch {};
    const early = g_rec.count == base;
    s.tick(30_000) catch {};
    const pinged = g_rec.count == base + 1 and g_rec.last()[0] == 0xC0 and g_rec.last()[1] == 0x00;
    s.tick(90_000) catch {};
    const dead = s.state == .failed;

    check(early and pinged and dead, "session keepalive early=0 ping@30000=1 dead@90000=1", .{});
}

// ---------------------------------------------------------------------------
// ⑨ OTA 清单：摘要 / 长度 / 降级
// ---------------------------------------------------------------------------

fn c09_manifest() void {
    for (&g_image, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var ok = false;
    var version: u32 = 0;
    var image_len: u32 = 0;
    var sha_buf: [12]u8 = undefined;
    var sha_prefix: []const u8 = "";
    if (ota.seal(&g_manifest, 7, &g_image, ota.trust_seed)) |_| {
        if (ota.verify(&g_manifest, &g_image)) |m| {
            version = m.version;
            image_len = m.image_len;
            sha_prefix = hexInto(&sha_buf, m.sha256[0..4]);
            ok = true;
        } else |_| {}
    } else |_| {}

    // 镜像翻一位 → 摘要先炸。
    g_image[100] ^= 0x01;
    const tampered = ota.verify(&g_manifest, &g_image);
    const tamper_ok = if (tampered) |_| false else |e| e == error.Sha256Mismatch;
    g_image[100] ^= 0x01;

    // 版本降级：清单 v7，当前 v8 → 拒。
    const downgrade = ota.checkVersion(8, 7);
    const downgrade_ok = if (downgrade) |_| false else |e| e == error.Downgrade;

    check(ok and tamper_ok and downgrade_ok, "ota manifest v={d} len={d} sha256={s} tamper=rej downgrade=rej", .{
        version, image_len, sha_prefix,
    });
}

// ---------------------------------------------------------------------------
// ⑩ Ed25519
// ---------------------------------------------------------------------------

fn c10_ed25519() void {
    var ok = false;
    var key_buf: [12]u8 = undefined;
    var sig_buf: [12]u8 = undefined;
    var key_prefix: []const u8 = "";
    var sig_prefix: []const u8 = "";

    if (std.crypto.sign.Ed25519.KeyPair.generateDeterministic(ota.trust_seed)) |kp| {
        const pub_bytes = kp.public_key.toBytes();
        key_prefix = hexInto(&key_buf, pub_bytes[0..4]);
        const key_ok = std.mem.eql(u8, &pub_bytes, &ota.trusted_key);

        // 正例：清单签名能验过（刚才在 ⑨ 里已生成，重新生成一份干净的）。
        var good = true;
        if (ota.seal(&g_manifest, 9, &g_image, ota.trust_seed)) |_| {
            if (ota.verify(&g_manifest, &g_image)) |m| {
                sig_prefix = hexInto(&sig_buf, m.signature[0..4]);
            } else |_| {
                good = false;
            }
        } else |_| {
            good = false;
        }

        // 反例：签名翻一位 → BadSignature。
        g_manifest[ota.signed_len] ^= 0x80;
        const bad = ota.verify(&g_manifest, &g_image);
        const bad_ok = if (bad) |_| false else |e| e == error.BadSignature;
        g_manifest[ota.signed_len] ^= 0x80;

        ok = key_ok and good and bad_ok;
    } else |_| {}

    check(ok, "ota ed25519 key={s} sig={s} badsig=rej", .{ key_prefix, sig_prefix });
}

// ---------------------------------------------------------------------------
// ⑪ A/B 与回滚
// ---------------------------------------------------------------------------

fn c11_rollback() void {
    var ab = ota.Rollback.init(.{ .max_runtime_failures = 3 });
    const start_ok = ab.active == .a and ab.activeState() == .valid;
    ab.stage(.b) catch {};
    ab.setBootSlot(.b) catch {};
    const pending_ok = ab.active == .b and ab.activeState() == .pending_verify;

    ab.noteFailure();
    ab.noteFailure();
    const still_b = ab.active == .b;
    ab.noteFailure();
    const rolled = ab.active == .a and ab.activeState() == .valid and ab.rollbacks == 1;
    const b_state = ab.slots[@backingInt(ota.Slot.b)].state;

    check(start_ok and pending_ok and still_b and rolled, "ota ab start=a fail3=rollback b={s} rollbacks={d}", .{
        switch (b_state) {
            .invalid => "invalid",
            .aborted => "aborted",
            else => "other",
        },
        ab.rollbacks,
    });
}

// ---------------------------------------------------------------------------
// ⑫ inflight 背压
// ---------------------------------------------------------------------------

fn c12_backpressure() void {
    var s = connected(.{ .max_inflight = 4 }) catch return check(false, "session inflight connect failed ok", .{});
    const topics = [_][]const u8{ "dev/24/0", "dev/24/1", "dev/24/2", "dev/24/3", "dev/24/4" };
    var accepted: u8 = 0;
    for (topics[0..4]) |t| {
        if (s.publish(t, "x", 1, 10)) |_| accepted += 1 else |_| {}
    }
    const full = s.windowFull();
    const fifth = s.publish(topics[4], "x", 1, 10);
    const fifth_rejected = if (fifth) |_| false else |e| e == error.InflightFull;

    // QoS0 不占窗口：窗口满时照样能发。
    const qos0 = s.publish("dev/24/ff", "x", 0, 11);
    const qos0_ok = if (qos0) |id| id == 0 else |_| false;

    _ = s.onPacket(&.{ 0x40, 0x02, 0x00, 0x01 }, 12) catch {};
    const freed = s.publish(topics[4], "x", 1, 13) catch 0;

    const ok = accepted == 4 and full and fifth_rejected and qos0_ok and freed != 0 and s.inflightCount() == 4;
    check(ok, "session inflight accepted={d} full=1 fifth=rej qos0=1 freed=1", .{accepted});
}

// ---------------------------------------------------------------------------
// ⑬ 流式重组
// ---------------------------------------------------------------------------

fn c13_stream() void {
    var ok = false;
    var total: usize = 0;
    var id: u16 = 0;
    var stalled: u8 = 0;

    // 120 字节载荷把剩余长度顶到 135 = 0x87 0x01：第一个长度字节带续位，
    // 于是“只收到 0x87”就是一个必须返回 null（而不是报错）的切分点。
    if (mqtt.encodePublish(&g_wire, "dev/24/temp", &stream_payload, 1, 0x0304, false, false)) |n| {
        total = n;
        var reader = mqtt.StreamReader.init(&g_stream);

        reader.push(g_wire[0..1]) catch {}; // 只有类型字节
        if ((reader.peek() catch null) == null) stalled += 1;
        reader.push(g_wire[1..2]) catch {}; // 长度字段只到 0x87（续位已置）
        if ((reader.peek() catch null) == null) stalled += 1;
        reader.push(g_wire[2..8]) catch {}; // 长度字段齐了，报文体还不够
        if ((reader.peek() catch null) == null) stalled += 1;
        reader.push(g_wire[8..n]) catch {};

        if (reader.peek() catch null) |f| {
            if (reader.take() catch null) |bytes| {
                if (mqtt.decodePublish(bytes)) |p| {
                    id = p.packet_id;
                } else |_| {}
                reader.consume(f.total);
            }
            ok = stalled == 3 and f.ptype == .publish and f.total == n and reader.len == 0;
        }
    } else |_| {}

    check(ok and id == 0x0304, "mqtt stream pushes=4 total={d} id={d} stalled=3 reassembled=1", .{ total, id });
}

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

pub fn run() bool {
    c01_connectKat();
    c02_remainingLength();
    c03_connack();
    c04_publishQos1();
    c05_qos2();
    c06_subscribe();
    c07_topic();
    c08_keepalive();
    c09_manifest();
    c10_ed25519();
    c11_rollback();
    c12_backpressure();
    c13_stream();

    var sha_buf: [12]u8 = undefined;
    var sig_buf: [12]u8 = undefined;
    read("ota manifest sha256_prefix={s} sig_prefix={s}", .{
        hexInto(&sha_buf, g_manifest[12..16]),
        hexInto(&sig_buf, g_manifest[44..48]),
    });

    log.line("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
