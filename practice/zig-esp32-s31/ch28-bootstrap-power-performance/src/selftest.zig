//! ch28：板侧自检（12 条判据）。
//!
//! 本章不写 flash、不真正进睡、不改 CPU 频率；板侧只把 bootloader 选槽、
//! A/B 回滚预算、睡眠/唤醒算术、性能统计这四组**纯逻辑**各走一遍。
//! 真机验收（OTA 写槽、deep sleep 电流、80/160/320 MHz 吞吐）见章节 28.9。
//!
//! 12 条判据：
//!   ① otadata 16 字节往返 + CRC
//!   ② 两扇区取 seq 最大者
//!   ③ 一个扇区 CRC 坏 → 回退到另一个
//!   ④ 选中槽 ABORTED/INVALID → 回 factory
//!   ⑤ pending_verify 启动次数超预算
//!   ⑥ 连续运行失败触发 A/B 回滚
//!   ⑦ esp_app_desc 魔数/结构偏移
//!   ⑧ RTC 32 位计数器单次最大睡眠
//!   ⑨ deep/light 占空比平均电流均低于 run
//!   ⑩ 最近秩 p50/p95
//!   ⑪ 1 MiB / 1 s 吞吐 = 1 MiB/s
//!   ⑫ 80→320 MHz 周期/时间折算

const std = @import("std");

const bootslot = @import("bootslot.zig");
const ota = @import("ota.zig");
const perf = @import("perf.zig");
const power = @import("power.zig");
const log = @import("log.zig");

var g_a: [bootslot.entry_len]u8 = undefined;
var g_b: [bootslot.entry_len]u8 = undefined;
var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var buf: [180]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn read(comptime fmt: []const u8, args: anytype) void {
    log.line("read: " ++ fmt, args);
}

pub fn run() bool {
    // ① 往返 + CRC
    var one: [bootslot.entry_len]u8 = undefined;
    const enc = bootslot.encodeEntry(&one, .{ .seq = 9, .slot = .b, .state = .valid }) catch null;
    const dec = bootslot.decodeEntry(&one) catch null;
    check(enc == bootslot.entry_len and dec != null and dec.?.seq == 9 and dec.?.slot == .b, "otadata entry roundtrip + crc32", .{});

    // ② seq 最大者
    _ = bootslot.encodeEntry(&g_a, .{ .seq = 3, .slot = .a, .state = .valid }) catch {};
    _ = bootslot.encodeEntry(&g_b, .{ .seq = 4, .slot = .b, .state = .new }) catch {};
    const p = bootslot.pickBytes(&g_a, &g_b);
    check(p != null and p.?.entry.slot == .b, "pick highest seq (B/4 over A/3)", .{});

    // ③ 一个扇区坏 → 另一个仍可用
    g_b[12] ^= 0xFF;
    const q = bootslot.pickBytes(&g_a, &g_b);
    check(q != null and q.?.entry.slot == .a, "bad crc sector ignored, A remains", .{});

    // ④ ABORTED / INVALID → factory
    _ = bootslot.encodeEntry(&g_b, .{ .seq = 5, .slot = .b, .state = .aborted }) catch {};
    const d_aborted = bootslot.decide(&g_a, &g_b);
    _ = bootslot.encodeEntry(&g_b, .{ .seq = 6, .slot = .b, .state = .invalid }) catch {};
    const d_invalid = bootslot.decide(&g_a, &g_b);
    check(
        d_aborted.slot == null and d_aborted.reason == .factory_fallback and
            d_invalid.slot == null and d_invalid.reason == .factory_fallback,
        "aborted/invalid winner falls back to factory",
        .{},
    );

    // ⑤ 启动预算
    const cfg = ota.AbConfig{ .max_boot_attempts = 2 };
    check(!bootslot.bootAttemptsExceeded(2, cfg) and bootslot.bootAttemptsExceeded(3, cfg), "pending_verify boot budget (2 ok, 3 exceeds)", .{});

    // ⑥ 回滚
    var rb = ota.Rollback.init(.{ .max_boot_attempts = 2, .max_runtime_failures = 3 });
    rb.stage(.b) catch {};
    rb.setBootSlot(.b) catch {};
    rb.noteFailure();
    rb.noteFailure();
    rb.noteFailure();
    check(rb.active == .a and rb.rollbacks == 1, "three runtime failures roll back B -> A", .{});

    // ⑦ app_desc 魔数与偏移
    const AppDesc = extern struct {
        magic_word: u32,
        secure_version: u32,
        reserv1: [2]u32,
        version: [32]u8,
        project_name: [32]u8,
        time: [16]u8,
        date: [16]u8,
        idf_ver: [32]u8,
        app_elf_sha256: [32]u8,
        min_efuse_blk_rev_full: u16,
        max_efuse_blk_rev_full: u16,
        mmu_page_size: u8,
        spi_flash_mode: u8,
        reserv3: u16,
        reserv2: [72]u8,
    };
    check(@sizeOf(AppDesc) == 256 and @offsetOf(AppDesc, "idf_ver") == 112, "esp_app_desc_t size/offset (256, idf_ver@112)", .{});

    // ⑧ RTC 32 位上限
    const max_us = power.maxSleepUs(136_000);
    check(max_us > 31_500_000_000 and max_us < 31_600_000_000, "rtc 32-bit max sleep ~{d} us", .{max_us});

    // ⑨ 占空比平均电流
    const m = power.Model{};
    const deep = power.dutyAverageMa(m, .deep_sleep, 10_000_000);
    const light = power.dutyAverageMa(m, .light_sleep, 10_000_000);
    check(deep < light and light < m.run_ma, "avg current deep={d:.2}mA < light={d:.2}mA < run", .{ deep, light });

    // ⑩ 百分位
    var samples = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10 };
    const s = perf.summarize(&samples) catch null;
    check(s != null and s.?.p50 == 5 and s.?.p95 == 10, "nearest-rank p50/p95 on 1..10", .{});

    // ⑪ 吞吐
    const mib = perf.mibPerSecond(1 << 20, 1_000_000_000);
    check(@abs(mib - 1.0) < 0.0001, "1 MiB / 1 s = {d:.4} MiB/s", .{mib});

    // ⑫ 频率折算
    check(perf.scaleCycles(1000, 80, 320) == 4000 and perf.scaleNs(1000, 80, 320) == 250, "80->320 MHz cycle/time scaling", .{});

    read("checks: passed={d} failed={d} total={d}", .{ g_passed, g_failed, g_passed + g_failed });
    return g_failed == 0;
}
