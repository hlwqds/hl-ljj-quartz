//! ch26-wifi-connection-wpa2-wpa3：连接状态机与事件环形队列。
//!
//! 这一层完全是「事件 + tick」驱动的纯逻辑：没有射频、没有中断、没有调度器
//! （`mstatus.MIE = 0`，全轮询）。它能被断言，是因为它把「连接」拆成了
//! 七个可观测状态和一条唯一的转移图：
//!
//!     idle ──start──▶ scan ──scan_done──▶ auth ──auth_ok──▶ assoc
//!                                                     ──assoc_ok──▶ fourway
//!                                                     ──fourway_ok──▶ connected
//!     任意状态 ──link_lost──▶ reconnect ──backoff 到点──▶ scan
//!     reconnect 超过重试上限 ──▶ failed
//!
//! 三个刻意设计的选择：
//!
//!   1. **上行事件进环形队列，满了丢最旧并计数**。真实 Wi-Fi 事件来自
//!      blob 的回调，回调不能在中断里阻塞；丢最旧 + 计数让「背压」变成
//!      可观测的读数，而不是悄悄覆盖或死等。
//!   2. **重连退避是指数的，带抖动上限**。同一批设备断电重启后会在同一秒
//!      一起重连（重连风暴），抖动把它们的相位打散；上限防止退避无限增长。
//!   3. **tick 只推进时间，不推进状态**。状态只由事件推进，所以测试可以
//!      把时间「快进」（`tick(now + 10_000)`），不需要真的等 8 秒。
//!
//! 本文件不 import hw/log，主机测试与板侧自检共用。

const std = @import("std");

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

pub const State = enum {
    idle,
    scan,
    auth,
    assoc,
    fourway,
    connected,
    reconnect,
    failed,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .idle => "idle",
            .scan => "scan",
            .auth => "auth",
            .assoc => "assoc",
            .fourway => "fourway",
            .connected => "connected",
            .reconnect => "reconnect",
            .failed => "failed",
        };
    }
};

pub const EventKind = enum {
    scan_done,
    auth_ok,
    assoc_ok,
    fourway_ok,
    link_lost,
    backoff_expired,
    gave_up,

    pub fn name(self: EventKind) []const u8 {
        return switch (self) {
            .scan_done => "scan_done",
            .auth_ok => "auth_ok",
            .assoc_ok => "assoc_ok",
            .fourway_ok => "fourway_ok",
            .link_lost => "link_lost",
            .backoff_expired => "backoff_expired",
            .gave_up => "gave_up",
        };
    }
};

pub const Event = struct {
    kind: EventKind,
    /// 序号（从 0 递增）或状态值，随事件种类而定；日志里原样打印。
    arg: u32 = 0,
};

// ---------------------------------------------------------------------------
// 事件环形队列：容量 8，满了丢最旧
// ---------------------------------------------------------------------------

pub const queue_capacity = 8;

pub const PushResult = enum { queued, dropped_oldest };

pub const EventQueue = struct {
    buf: [queue_capacity]Event = undefined,
    head: u32 = 0, // 指向最旧的一个
    len: u32 = 0,
    pushed: u32 = 0,
    dropped: u32 = 0,

    pub fn reset(self: *EventQueue) void {
        self.* = .{};
    }

    pub fn push(self: *EventQueue, ev: Event) PushResult {
        self.pushed += 1;
        if (self.len < queue_capacity) {
            self.buf[(self.head + self.len) % queue_capacity] = ev;
            self.len += 1;
            return .queued;
        }
        // 满：覆盖最旧的一个，并把 head 前移。
        self.buf[self.head] = ev;
        self.head = (self.head + 1) % queue_capacity;
        self.dropped += 1;
        return .dropped_oldest;
    }

    pub fn pop(self: *EventQueue) ?Event {
        if (self.len == 0) return null;
        const ev = self.buf[self.head];
        self.head = (self.head + 1) % queue_capacity;
        self.len -= 1;
        return ev;
    }

    pub fn at(self: *const EventQueue, index: u32) ?Event {
        if (index >= self.len) return null;
        return self.buf[(self.head + index) % queue_capacity];
    }
};

// ---------------------------------------------------------------------------
// 重连退避：base × 2^n，上限 cap；抖动是 base/8 范围内的确定性伪随机量
// ---------------------------------------------------------------------------

pub const backoff_base_ms: u32 = 1000;
pub const backoff_cap_ms: u32 = 8000;
/// 第 6 次断线直接 failed：1→2→4→8→8 之后不再等。
pub const max_retries: u8 = 5;

/// 第 `retry` 次重连（从 1 开始）的退避时间，不含抖动。
/// 序列：1000 / 2000 / 4000 / 8000 / 8000（上限）。
pub fn backoffMs(retry: u8) u32 {
    if (retry == 0) return 0;
    const shift: u5 = @intCast(@min(retry - 1, 3));
    const v = backoff_base_ms << shift;
    return @min(v, backoff_cap_ms);
}

/// 抖动：base/8 以内的加性偏移，用 32 位 LCG 生成（确定性，便于断言）。
/// 真实实现可以用 TRNG；这里只要「同 seed 同序列」，好让板侧日志可复现。
pub const jitter_span_ms: u32 = backoff_base_ms / 8; // 125 ms

pub fn lcgNext(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

pub fn backoffWithJitter(retry: u8, seed: *u32) u32 {
    const base = backoffMs(retry);
    if (base == 0) return 0;
    return base + (lcgNext(seed) >> 16) % (jitter_span_ms + 1);
}

// ---------------------------------------------------------------------------
// 扫描候选：去重、过滤开放网络、按 RSSI 降序
// ---------------------------------------------------------------------------

pub const Security = enum { open, wpa2_psk, wpa2_enterprise, wpa3_sae };

pub const Ap = struct {
    bssid: [6]u8,
    rssi: i8, // dBm，-120..0
    channel: u8,
    security: Security = .wpa2_psk,
};

pub const scan_max = 8;

pub const ScanError = error{BufferTooSmall};

/// 选候选：丢掉 open（本章只做 WPA2/WPA3）、同一 BSSID 只留信号最强的、
/// 剩下按 rssi 降序（同 rssi 用 channel 升序、再按 bssid 字节序，保证确定性）。
/// 返回写入 `out` 的条数。
pub fn selectCandidates(aps: []const Ap, out: []Ap) ScanError!usize {
    if (out.len < @min(aps.len, scan_max)) return error.BufferTooSmall;
    var n: usize = 0;
    for (aps) |ap| {
        if (ap.security == .open) continue;
        var merged = false;
        for (out[0..n]) |*kept| {
            if (std.mem.eql(u8, &kept.bssid, &ap.bssid)) {
                if (ap.rssi > kept.rssi) kept.* = ap;
                merged = true;
                break;
            }
        }
        if (merged) continue;
        if (n == out.len) return error.BufferTooSmall;
        out[n] = ap;
        n += 1;
    }
    // 插入排序：n <= 8，稳定即可。
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const cur = out[i];
        var j = i;
        while (j > 0 and before(cur, out[j - 1])) : (j -= 1) {
            out[j] = out[j - 1];
        }
        out[j] = cur;
    }
    return n;
}

fn before(a: Ap, b: Ap) bool {
    if (a.rssi != b.rssi) return a.rssi > b.rssi; // 降序：强的在前
    if (a.channel != b.channel) return a.channel < b.channel;
    return std.mem.order(u8, &a.bssid, &b.bssid) == .lt;
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

pub const Machine = struct {
    state: State = .idle,
    /// 连续失败次数（成功连上后清零）。
    retries: u8 = 0,
    /// 事件里带的单调序号，便于日志对拍。
    seq: u32 = 0,
    /// 退避到点的时间戳（逻辑毫秒，由调用方给）。
    next_attempt_ms: u64 = 0,
    seed: u32 = 0x2026_1113,
    queue: EventQueue = .{},

    pub fn reset(self: *Machine) void {
        self.* = .{};
    }

    fn emit(self: *Machine, kind: EventKind, arg: u32) PushResult {
        self.seq += 1;
        return self.queue.push(.{ .kind = kind, .arg = arg });
    }

    /// idle → scan。
    pub fn start(self: *Machine) bool {
        if (self.state != .idle) return false;
        self.state = .scan;
        return true;
    }

    /// 扫描完成：scan → auth。`found` 是候选数，只记录。
    pub fn onScanDone(self: *Machine, found: u32) bool {
        if (self.state != .scan) return false;
        self.state = .auth;
        _ = self.emit(.scan_done, found);
        return true;
    }

    pub fn onAuthOk(self: *Machine) bool {
        if (self.state != .auth) return false;
        self.state = .assoc;
        _ = self.emit(.auth_ok, @backingInt(self.state));
        return true;
    }

    pub fn onAssocOk(self: *Machine, status: u32) bool {
        if (self.state != .assoc) return false;
        self.state = .fourway;
        _ = self.emit(.assoc_ok, status);
        return true;
    }

    pub fn onFourWayOk(self: *Machine) bool {
        if (self.state != .fourway) return false;
        self.state = .connected;
        self.retries = 0;
        _ = self.emit(.fourway_ok, @backingInt(self.state));
        return true;
    }

    /// 断线：进入 reconnect 与退避；超过上限转 failed。
    /// 返回下一次尝试的时间戳（failed 时等于 now_ms）。
    pub fn onLinkLost(self: *Machine, now_ms: u64) u64 {
        self.retries = if (self.retries == std.math.maxInt(u8)) self.retries else self.retries + 1;
        _ = self.emit(.link_lost, self.retries);
        if (self.retries > max_retries) {
            self.state = .failed;
            self.next_attempt_ms = now_ms;
            _ = self.emit(.gave_up, self.retries);
            return now_ms;
        }
        self.state = .reconnect;
        const wait = backoffWithJitter(self.retries, &self.seed);
        self.next_attempt_ms = now_ms + wait;
        _ = self.emit(.backoff_expired, wait);
        return self.next_attempt_ms;
    }

    /// 时间推进：到点就从 reconnect 回到 scan。返回值表示是否发生了迁移；
    /// 事件里带的是「迟到量」（now − 到点时刻），对拍日志用。
    pub fn tick(self: *Machine, now_ms: u64) bool {
        if (self.state != .reconnect) return false;
        if (now_ms < self.next_attempt_ms) return false;
        const late: u64 = now_ms - self.next_attempt_ms;
        self.state = .scan;
        _ = self.emit(.backoff_expired, @truncate(late));
        return true;
    }

    /// 取出下一个事件（日志用）。
    pub fn pop(self: *Machine) ?Event {
        return self.queue.pop();
    }
};

// ---------------------------------------------------------------------------
// 便于日志的一行摘要
// ---------------------------------------------------------------------------

pub fn stateSummary(m: *const Machine) struct { state: State, retries: u8, queued: u32 } {
    return .{ .state = m.state, .retries = m.retries, .queued = m.queue.len };
}
