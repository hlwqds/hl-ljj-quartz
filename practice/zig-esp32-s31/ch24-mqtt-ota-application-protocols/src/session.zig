//! ch24-mqtt-ota-application-protocols：MQTT 会话状态机（纯 tick 驱动、无锁）。
//!
//! 这一层不编码字节（那是 mqtt.zig），也不碰网络（那是 ch20/ch22）。
//! 它只管四件事，每一件都用“调用方传进来的毫秒数”推进，因此可以在
//! x86_64 上把时间轴跑一遍：
//!
//!   1) **连接**：`connect()` → CONNECT，`onPacket()` 收到 CONNACK 才进
//!      `connected`；返回码非 0 直接进 `failed`（MQTT 3.1.1 §3.2.2.3：
//!      非 0 返回码之后 broker 必须关闭连接，客户端也不许再发报文）；
//!   2) **心跳**：以“最后一次发出控制报文”为基准，空闲到 `keepalive/2`
//!      发 PINGREQ；发出 PINGREQ 后再过 `keepalive` 仍无 PINGRESP 就判链路
//!      死亡（总预算 1.5×keepalive，与 esp-mqtt 的 process_keepalive 一致，
//!      见 mqtt_client.c:787-807）；
//!   3) **重传窗口**：QoS1/2 的 PUBLISH 在 `retry_ms` 内没等到 PUBACK/PUBREC
//!      就带 DUP=1 重发；QoS2 收到 PUBREC 后改发 PUBREL，PUBREL 的重传
//!      **不设** DUP 位（PUBREL 的固定头 flags 恒为 0b0010，没有 dup 字段）；
//!   4) **背压**：inflight 窗口满了就返回 `error.InflightFull`，让生产者停住。
//!      这里刻意**没有**内部队列——无界队列把“对端太慢”变成“我们 OOM”，
//!      而板侧连分配器都没有。
//!
//! 去重（QoS2 接收侧）：PUBLISH(QoS2, id) 第一次到达时把 id 记进
//! `rx_qos2`，之后同 id 的重复 PUBLISH 只回 PUBREC、不再上抛；PUBREL 到达
//! 时回 PUBCOMP 并**保留** id 记录，这样重发的 PUBREL 也只会得到 PUBCOMP。
//! 只有收到新的 PUBREL 之后才允许同一个 id 再被当作新消息——3.1.1 的
//! packet id 在“一次会话内的同一方向”上必须唯一（MQTT-2.3.1-4）。
//!
//! 为什么不加锁：本章没有中断、没有第二个核、没有抢占（ch10/ch11 的调度器
//! 不在本工程里）。状态全部由一次 `onPacket`/`tick` 调用串行推进，
//! 加锁只会掩盖“谁在什么时候推进状态”这个真正的问题。

const std = @import("std");
const mqtt = @import("mqtt.zig");

pub const Error = mqtt.Error || error{
    NotConnected,
    InflightFull,
    PacketIdExhausted,
    UnexpectedPacket,
};

pub const State = enum {
    disconnected,
    connecting,
    connected,
    /// 链路被判死（心跳超时 / CONNACK 拒绝）。等待调用方重建 Session。
    failed,
};

pub const Config = struct {
    keepalive_s: u16 = 60,
    /// 同时在途的 QoS>0 报文上限（真机上就是 broker 的 receive maximum，
    /// 3.1.1 没有这个字段，靠我们自律）。
    max_inflight: u8 = 4,
    /// 重传超时。3.1.1 §4.4 只说“未确认就重发”，不给具体秒数。
    retry_ms: u32 = 5_000,
};

/// 发送出口：一个函数指针 + 上下文。
///
/// 用函数指针而不是返回缓冲，是为了让“字节确实发出去了”这件事只有一个
/// 出口；自检与主机测试都挂一个录制器，把每次 emit 的字节存进数组再对拍。
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,

    pub fn emit(self: Sink, bytes: []const u8) void {
        self.write(self.ctx, bytes);
    }
};

/// 录制型 Sink：把每次 emit 的字节按序存进固定数组，供自检与单测对拍。
///
/// 板侧用它把“会话到底发了什么字节”变成可打印的事实——没有它，自检只能
/// 断言内部计数器，断言不了报文形状。`frame_count` 故意小而固定：
/// 溢出的断言本身就是“会话发了不该发的报文”的证据。
pub const FrameRecorder = struct {
    pub const frame_max = 512;
    pub const frame_count = 10;

    bytes: [frame_count * frame_max]u8 = undefined,
    lens: [frame_count]usize = @splat(0),
    count: usize = 0,

    fn writeCb(ctx: *anyopaque, data: []const u8) void {
        const self: *FrameRecorder = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.count < frame_count);
        std.debug.assert(data.len <= frame_max);
        const off = self.count * frame_max;
        @memcpy(self.bytes[off..][0..data.len], data);
        self.lens[self.count] = data.len;
        self.count += 1;
    }

    pub fn sink(self: *FrameRecorder) Sink {
        return .{ .ctx = @ptrCast(self), .write = writeCb };
    }

    pub fn frame(self: *const FrameRecorder, i: usize) []const u8 {
        std.debug.assert(i < self.count);
        const off = i * frame_max;
        return self.bytes[off..][0..self.lens[i]];
    }

    pub fn last(self: *const FrameRecorder) []const u8 {
        return self.frame(self.count - 1);
    }

    pub fn reset(self: *FrameRecorder) void {
        self.count = 0;
    }
};

/// 一条在途 QoS>0 报文的阶段。
pub const Stage = enum(u8) {
    /// QoS1：等 PUBACK。
    wait_puback,
    /// QoS2 第一步：等 PUBREC。
    wait_pubrec,
    /// QoS2 第二步：已发 PUBREL，等 PUBCOMP。
    wait_pubcomp,
};

const max_slots = 8;
const encode_buf_len = 384;

const TxSlot = struct {
    used: bool = false,
    packet_id: u16 = 0,
    qos: u2 = 0,
    topic: []const u8 = "",
    payload: []const u8 = "",
    stage: Stage = .wait_puback,
    last_send_ms: u32 = 0,
    retransmits: u8 = 0,
};

/// 一条已上抛的入站 PUBLISH。`duplicate == true` 表示同一 packet id 的
/// 重复投递（QoS2 去重命中）：会话层仍然回 PUBREC，但**不再**把它当成
/// 新消息交给应用。
pub const Delivered = struct {
    packet: mqtt.Publish,
    duplicate: bool,
};

/// 一次 `onPacket` 的结果。`none` 表示“只是确认，没有语义事件”。
pub const Event = union(enum) {
    none,
    connack: mqtt.Connack,
    publish: Delivered,
    puback: u16,
    pubrec: u16,
    pubcomp: u16,
    suback: mqtt.Suback,
    pingresp,
};

pub const Session = struct {
    cfg: Config,
    sink: Sink,
    state: State = .disconnected,
    next_id: u16 = 1,

    tx: [max_slots]TxSlot = @splat(.{}),
    tx_count: u8 = 0,

    /// 接收侧 QoS2 去重表：0 表示空位（packet id 0 在 QoS2 里非法）。
    rx_qos2: [max_slots]u16 = @splat(0),
    rx_qos2_count: u8 = 0,

    last_tx_ms: u32 = 0,
    last_rx_ms: u32 = 0,
    ping_sent_ms: u32 = 0,
    awaiting_pingresp: bool = false,

    // 读数（不是判据）：自检把它打进日志，便于人工对拍。
    stat_retransmits: u32 = 0,
    stat_pingreq: u32 = 0,
    stat_qos2_dups: u32 = 0,

    pub fn init(cfg: Config, sink: Sink) Session {
        return .{ .cfg = cfg, .sink = sink };
    }

    // -- 状态读数 ---------------------------------------------------------

    pub fn inflightCount(self: *const Session) u8 {
        return self.tx_count;
    }

    /// 窗口是否已满（调用方据此做背压：停住生产者，而不是丢报文）。
    pub fn windowFull(self: *const Session) bool {
        return self.tx_count >= self.cfg.max_inflight;
    }

    // -- 连接生命周期 -----------------------------------------------------

    pub fn connect(self: *Session, client_id: []const u8, now_ms: u32) Error!void {
        var buf: [encode_buf_len]u8 = undefined;
        const n = try mqtt.encodeConnect(&buf, .{
            .client_id = client_id,
            .keepalive_s = self.cfg.keepalive_s,
            .clean_session = true,
        });
        self.sink.emit(buf[0..n]);
        self.state = .connecting;
        self.last_tx_ms = now_ms;
        self.awaiting_pingresp = false;
    }

    pub fn disconnect(self: *Session, now_ms: u32) Error!void {
        var buf: [encode_buf_len]u8 = undefined;
        const n = try mqtt.encodeDisconnect(&buf);
        self.sink.emit(buf[0..n]);
        self.last_tx_ms = now_ms;
        self.state = .disconnected;
    }

    // -- 出站：PUBLISH / SUBSCRIBE ---------------------------------------

    /// 发一条 PUBLISH。QoS0 直接发出并返回 0；QoS1/2 分配 packet id、
    /// 占用一个 inflight 槽位，窗口满时返回 `error.InflightFull`。
    pub fn publish(
        self: *Session,
        topic: []const u8,
        payload: []const u8,
        qos: u2,
        now_ms: u32,
    ) Error!u16 {
        if (self.state != .connected) return error.NotConnected;
        if (qos > 2) return error.InvalidQos;

        var buf: [encode_buf_len]u8 = undefined;
        if (qos == 0) {
            const n = try mqtt.encodePublish(&buf, topic, payload, 0, 0, false, false);
            self.sink.emit(buf[0..n]);
            self.last_tx_ms = now_ms;
            return 0;
        }

        const slot = self.allocSlot() orelse return error.InflightFull;
        const id = self.allocPacketId();
        slot.* = .{
            .used = true,
            .packet_id = id,
            .qos = qos,
            .topic = topic,
            .payload = payload,
            .stage = if (qos == 1) .wait_puback else .wait_pubrec,
            .last_send_ms = now_ms,
            .retransmits = 0,
        };
        self.tx_count += 1;

        const n = try mqtt.encodePublish(&buf, topic, payload, qos, id, false, false);
        self.sink.emit(buf[0..n]);
        self.last_tx_ms = now_ms;
        return id;
    }

    pub fn subscribe(self: *Session, subs: []const mqtt.TopicSubscription, now_ms: u32) Error!u16 {
        if (self.state != .connected) return error.NotConnected;
        var buf: [encode_buf_len]u8 = undefined;
        const id = self.nextPacketId();
        const n = try mqtt.encodeSubscribe(&buf, subs, id);
        self.sink.emit(buf[0..n]);
        self.last_tx_ms = now_ms;
        return id;
    }

    pub fn unsubscribe(self: *Session, filters: []const []const u8, now_ms: u32) Error!u16 {
        if (self.state != .connected) return error.NotConnected;
        var buf: [encode_buf_len]u8 = undefined;
        const id = self.nextPacketId();
        const n = try mqtt.encodeUnsubscribe(&buf, filters, id);
        self.sink.emit(buf[0..n]);
        self.last_tx_ms = now_ms;
        return id;
    }

    // -- 入站 -------------------------------------------------------------

    /// 处理一条**完整**报文（不完整的字节流归 mqtt.StreamReader）。
    pub fn onPacket(self: *Session, bytes: []const u8, now_ms: u32) Error!Event {
        const ptype = try mqtt.typeFromByte(bytes[0]);
        const flags: u4 = @truncate(bytes[0] & 0x0F);
        if (!mqtt.flagsValid(ptype, flags)) return error.InvalidFlags;

        const rl = try mqtt.decodeRemainingLength(bytes[1..]);
        const header_len = 1 + @as(usize, rl.len);
        if (header_len + rl.value != bytes.len) return error.MalformedPacket;
        const body = bytes[header_len..];
        self.last_rx_ms = now_ms;

        switch (ptype) {
            .connack => {
                if (self.state != .connecting) return error.UnexpectedPacket;
                const c = try mqtt.decodeConnack(body);
                if (!mqtt.connackConsistent(c)) return error.MalformedPacket;
                if (c.accepted()) {
                    self.state = .connected;
                } else {
                    self.state = .failed;
                }
                return .{ .connack = c };
            },
            .publish => {
                const p = try mqtt.decodePublish(bytes);
                return .{ .publish = try self.deliverInbound(p, now_ms) };
            },
            .puback => {
                const id = try ackId(body);
                self.freeSlot(id);
                return .{ .puback = id };
            },
            .pubrec => {
                const id = try ackId(body);
                const slot = self.findSlot(id) orelse return error.UnexpectedPacket;
                slot.stage = .wait_pubcomp;
                slot.last_send_ms = now_ms;
                slot.retransmits = 0;
                var buf: [encode_buf_len]u8 = undefined;
                const n = try mqtt.encodeAck(&buf, .pubrel, id);
                self.sink.emit(buf[0..n]);
                self.last_tx_ms = now_ms;
                return .{ .pubrec = id };
            },
            .pubcomp => {
                const id = try ackId(body);
                self.freeSlot(id);
                return .{ .pubcomp = id };
            },
            .pingresp => {
                self.awaiting_pingresp = false;
                return .pingresp;
            },
            .suback => {
                const s = try mqtt.decodeSuback(body);
                return .{ .suback = s };
            },
            .pubrel => {
                // 接收侧 QoS2 第三步：回 PUBCOMP。重复的 PUBREL 也回 PUBCOMP
                // （幂等），但不再上抛、也不清 id 记录以外的东西。
                const id = try ackId(body);
                self.removeRxQos2(id);
                var buf: [encode_buf_len]u8 = undefined;
                const n = try mqtt.encodeAck(&buf, .pubcomp, id);
                self.sink.emit(buf[0..n]);
                self.last_tx_ms = now_ms;
                return .none;
            },
            else => return error.UnexpectedPacket,
        }
    }

    /// QoS 接收路径。QoS0/1 每次都上抛；QoS2 第一次上抛、重复只回 PUBREC。
    fn deliverInbound(self: *Session, p: mqtt.Publish, now_ms: u32) Error!Delivered {
        var buf: [encode_buf_len]u8 = undefined;
        switch (p.qos) {
            0 => return .{ .packet = p, .duplicate = false },
            1 => {
                const n = try mqtt.encodeAck(&buf, .puback, p.packet_id);
                self.sink.emit(buf[0..n]);
                self.last_tx_ms = now_ms;
                return .{ .packet = p, .duplicate = false };
            },
            2 => {
                const dup = self.rxQos2Contains(p.packet_id);
                if (!dup) {
                    if (self.rx_qos2_count >= max_slots) return error.BufferTooSmall;
                    self.insertRxQos2(p.packet_id);
                } else {
                    self.stat_qos2_dups += 1;
                }
                const n = try mqtt.encodeAck(&buf, .pubrec, p.packet_id);
                self.sink.emit(buf[0..n]);
                self.last_tx_ms = now_ms;
                return .{ .packet = p, .duplicate = dup };
            },
            else => return error.InvalidQos,
        }
    }

    // -- 时间驱动 ---------------------------------------------------------

    /// 推进重传与心跳。调用方按自己的节拍（例如每 100 ms）调用；
    /// 时间单位全部是毫秒，且允许 `now_ms` 回绕（用无符号减法比较）。
    pub fn tick(self: *Session, now_ms: u32) Error!void {
        if (self.state != .connected) return;

        try self.retransmitExpired(now_ms);

        if (self.cfg.keepalive_s == 0) return;
        const keepalive_ms: u32 = @as(u32, self.cfg.keepalive_s) * 1000;

        if (self.awaiting_pingresp) {
            // 已经发过 PINGREQ：再等满一个 keepalive 就判死。
            // 总预算是 1.5×keepalive（半程空闲 + 一个完整等待）。
            if (elapsed(now_ms, self.ping_sent_ms) >= keepalive_ms) {
                self.state = .failed;
                self.awaiting_pingresp = false;
            }
            return;
        }

        if (elapsed(now_ms, self.last_tx_ms) >= keepalive_ms / 2) {
            var buf: [encode_buf_len]u8 = undefined;
            const n = try mqtt.encodePingreq(&buf);
            self.sink.emit(buf[0..n]);
            self.ping_sent_ms = now_ms;
            self.last_tx_ms = now_ms;
            self.awaiting_pingresp = true;
            self.stat_pingreq += 1;
        }
    }

    fn retransmitExpired(self: *Session, now_ms: u32) Error!void {
        // 按槽位顺序遍历 == 按 packet id 升序：MQTT-4.6.0-2 要求重发的
        // PUBLISH 保持原始发送顺序，跳着发会让对端先看到 id 大的。
        for (&self.tx) |*slot| {
            if (!slot.used) continue;
            if (elapsed(now_ms, slot.last_send_ms) < self.cfg.retry_ms) continue;
            slot.last_send_ms = now_ms;
            slot.retransmits +|= 1;
            self.stat_retransmits += 1;

            var buf: [encode_buf_len]u8 = undefined;
            const n = switch (slot.stage) {
                .wait_puback, .wait_pubrec => try mqtt.encodePublish(
                    &buf,
                    slot.topic,
                    slot.payload,
                    slot.qos,
                    slot.packet_id,
                    true, // DUP=1：MQTT-3.3.1-1
                    false,
                ),
                .wait_pubcomp => try mqtt.encodeAck(&buf, .pubrel, slot.packet_id),
            };
            self.sink.emit(buf[0..n]);
            self.last_tx_ms = now_ms;
        }
    }

    // -- 槽位与 id --------------------------------------------------------

    fn allocSlot(self: *Session) ?*TxSlot {
        if (self.tx_count >= self.cfg.max_inflight) return null;
        for (&self.tx) |*slot| {
            if (!slot.used) return slot;
        }
        return null;
    }

    fn findSlot(self: *Session, id: u16) ?*TxSlot {
        for (&self.tx) |*slot| {
            if (slot.used and slot.packet_id == id) return slot;
        }
        return null;
    }

    fn freeSlot(self: *Session, id: u16) void {
        if (self.findSlot(id)) |slot| {
            slot.* = .{};
            self.tx_count -= 1;
        }
    }

    /// packet id 从 1 开始，跳过 0（MQTT-2.3.1-2）；用完一轮不算错误，
    /// 因为同一时刻在途的报文最多 `max_inflight` 个。
    fn allocPacketId(self: *Session) u16 {
        while (true) {
            const id = self.nextPacketId();
            if (self.findSlot(id) == null) return id;
        }
    }

    fn nextPacketId(self: *Session) u16 {
        const id = self.next_id;
        self.next_id = if (self.next_id == std.math.maxInt(u16)) 1 else self.next_id + 1;
        return id;
    }

    fn rxQos2Contains(self: *const Session, id: u16) bool {
        for (self.rx_qos2) |v| {
            if (v == id) return true;
        }
        return false;
    }

    fn insertRxQos2(self: *Session, id: u16) void {
        for (&self.rx_qos2) |*v| {
            if (v.* == 0) {
                v.* = id;
                self.rx_qos2_count += 1;
                return;
            }
        }
    }

    fn removeRxQos2(self: *Session, id: u16) void {
        for (&self.rx_qos2) |*v| {
            if (v.* == id) {
                v.* = 0;
                self.rx_qos2_count -= 1;
                return;
            }
        }
    }
};

fn ackId(body: []const u8) Error!u16 {
    if (body.len != 2) return error.MalformedPacket;
    const id = (@as(u16, body[0]) << 8) | body[1];
    if (id == 0) return error.InvalidPacketId;
    return id;
}

/// 无符号回绕安全的时间差（毫秒）。`now` 落后于 `since` 时按回绕处理。
inline fn elapsed(now: u32, since: u32) u32 {
    return now -% since;
}
