//! s31-image-inspect：ESP32-S31 闪存产物的主机侧只读解析器。
//!
//! 用法：
//!   s31-image-inspect <file>
//!
//! 输入首字节为 0xE9        -> 按 ESP 应用镜像（common header + 扩展头 + 段）解析
//! 输入首两字节为 0xAA 0x50 -> 按二进制分区表（32 字节条目 + MD5 尾）解析
//!
//! 本程序只读本地文件：不开串口、不接触芯片、不改写任何东西。
//! 结构非法、XOR 校验和或 SHA256/MD5 对不上时以非零退出码结束。
const std = @import("std");

/// 应用镜像 common header 的 magic。
const image_magic: u8 = 0xE9;
/// XOR 校验的初值。
const checksum_seed: u8 = 0xEF;

const common_header_len: usize = 8;
const extended_header_len: usize = 16;
const segment_header_len: usize = 8;
/// esptool 的固件镜像最多 16 个段。
const max_segments: usize = 16;
/// 校验和字节写在文件 16 字节对齐的位置（中间空隙补 0x00）。
const checksum_align: usize = 16;
const sha256_len: usize = 32;

/// 分区表条目的 magic（字节序 0xAA, 0x50）。
const partition_magic: [2]u8 = .{ 0xAA, 0x50 };
/// MD5 尾块的起始 magic（0xEB, 0xEB，后接 14 个 0xFF）。
const partition_md5_magic: [2]u8 = .{ 0xEB, 0xEB };
const partition_entry_len: usize = 32;
const partition_table_max: usize = 0xC00;
const partition_md5_len: usize = 16;
/// 0xC00 字节的表区域除去 16 字节 MD5，再按 32 字节切分，最多 95 条。
const partition_max_entries: usize = (partition_table_max - partition_md5_len) / partition_entry_len;

/// 单文件上限：S31 整片 Flash 16 MB，留一倍余量。
const max_file_bytes: usize = 32 * 1024 * 1024;

const Segment = struct {
    load_addr: u32,
    size: u32,
    /// 段数据在文件中的起始偏移。
    data_off: usize,
};

const AppImage = struct {
    segment_count: u8,
    flash_mode: u8,
    flash_size_freq: u8,
    entry_addr: u32,
    wp_pin: u8,
    /// clk / q / d / cs / hd / wp 六个引脚驱动强度，各占 4 bit。
    drive: [6]u8,
    chip_id: u16,
    min_rev: u8,
    min_rev_full: u16,
    max_rev_full: u16,
    hash_appended: bool,
    segments: [max_segments]Segment,
    segment_len: usize,
    checksum_off: usize,
    stored_checksum: u8,
    computed_checksum: u8,
    /// 追加 SHA256 的起始偏移；未追加时为 null。
    digest_off: ?usize,
    /// 镜像有效长度（含校验和字节与 SHA256）。
    image_len: usize,
};

const PartitionEntry = struct {
    ptype: u8,
    subtype: u8,
    offset: u32,
    size: u32,
    label: [16]u8,
    label_len: usize,
    flags: u32,
};

const Kind = enum { app_image, partition_table };

/// 往 stdout 打印一行的薄封装：不需要 writer 抽象，也不做缓冲。
const Out = struct {
    file: std.fs.File,

    fn print(self: Out, comptime fmt: []const u8, args: anytype) !void {
        var buf: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.file.writeAll(text);
    }

    fn hex(self: Out, bytes: []const u8) !void {
        for (bytes) |b| try self.print("{x:0>2}", .{b});
    }
};

// ---------------------------------------------------------------- 小端读取

fn readU16(bytes: []const u8) u16 {
    std.debug.assert(bytes.len >= 2);
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

/// 结构性问题：先打印具体原因，再让调用方把退出码置为非零。
fn fail(comptime fmt: []const u8, args: anytype) error{Malformed} {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.Malformed;
}

// ---------------------------------------------------------------- 名称映射

fn flashModeName(mode: u8) []const u8 {
    return switch (mode) {
        0 => "QIO",
        1 => "QOUT",
        2 => "DIO",
        3 => "DOUT",
        else => "invalid",
    };
}

/// common header 第 3 字节高 4 位：Flash 容量。
fn flashSizeName(nibble: u8) []const u8 {
    return switch (nibble) {
        0x0 => "1MB",
        0x1 => "2MB",
        0x2 => "4MB",
        0x3 => "8MB",
        0x4 => "16MB",
        0x5 => "32MB",
        0x6 => "64MB",
        0x7 => "128MB",
        else => "invalid",
    };
}

/// common header 第 3 字节低 4 位：Flash 频率（S31 的取值集合）。
fn flashFreqName(nibble: u8) []const u8 {
    return switch (nibble) {
        0x0 => "40MHz",
        0x2 => "20MHz",
        0xF => "80MHz",
        else => "invalid",
    };
}

fn chipName(id: u16) []const u8 {
    return switch (id) {
        32 => "ESP32-S31",
        else => "unknown",
    };
}

/// 段加载地址落在哪片地址空间：用来区分“Flash 映射段”与“RAM 段”。
fn regionName(addr: u32) []const u8 {
    if (addr >= 0x2F000000 and addr < 0x2F080000) return "SRAM";
    if (addr >= 0x2F800000 and addr < 0x2F850000) return "ROM";
    if (addr >= 0x2E000000 and addr < 0x2E008000) return "LP SRAM";
    if (addr >= 0x40000000 and addr < 0x54000000) return "flash-mapped";
    return "other";
}

/// Flash 映射段（S31 的 IROM/DROM 窗口）：段数据要落在 MMU 页内 0x20 偏移处。
fn isFlashMapped(addr: u32) bool {
    return addr >= 0x40000000 and addr < 0x54000000;
}

fn partitionTypeName(ptype: u8) []const u8 {
    return switch (ptype) {
        0x00 => "app",
        0x01 => "data",
        0x02 => "bootloader",
        0x03 => "partition_table",
        else => "custom",
    };
}

/// 子类型名；OTA 槽位按范围展开成 ota_0 … ota_15。
fn partitionSubtypeName(buf: []u8, ptype: u8, subtype: u8) []const u8 {
    return switch (ptype) {
        0x00 => switch (subtype) {
            0x00 => "factory",
            0x20 => "test",
            0x10...0x1F => std.fmt.bufPrint(buf, "ota_{d}", .{subtype - 0x10}) catch return "ota",
            else => "custom",
        },
        0x01 => switch (subtype) {
            0x00 => "ota",
            0x01 => "phy",
            0x02 => "nvs",
            0x03 => "coredump",
            0x04 => "nvs_keys",
            0x05 => "efuse",
            0x06 => "undefined",
            0x80 => "esphttpd",
            0x81 => "fat",
            0x82 => "spiffs",
            0x83 => "littlefs",
            0x90 => "tee_ota",
            else => "custom",
        },
        0x02 => switch (subtype) {
            0x00 => "primary",
            0x01 => "ota",
            0x02 => "recovery",
            else => "custom",
        },
        0x03 => switch (subtype) {
            0x00 => "primary",
            0x01 => "ota",
            else => "custom",
        },
        else => "custom",
    };
}

// ---------------------------------------------------------------- 镜像解析

fn parseAppImage(data: []const u8) !AppImage {
    if (data.len < common_header_len) {
        return fail("file is {d} bytes, shorter than an 8-byte image header", .{data.len});
    }
    if (data[0] != image_magic) {
        return fail("bad image magic 0x{x:0>2} (expected 0xE9)", .{data[0]});
    }
    if (data[1] == 0) {
        return fail("image declares zero segments", .{});
    }
    if (data[1] > max_segments) {
        return fail("image declares {d} segments (max {d})", .{ data[1], max_segments });
    }
    if (data.len < common_header_len + extended_header_len) {
        return fail("file is too short for the 16-byte extended header", .{});
    }
    var img: AppImage = std.mem.zeroes(AppImage);
    img.segment_count = data[1];
    img.flash_mode = data[2];
    img.flash_size_freq = data[3];
    img.entry_addr = readU32(data[4..8]);

    const ext = data[common_header_len..][0..extended_header_len];
    img.wp_pin = ext[0];
    // 三个字节里塞了六个 4 bit 的驱动强度。
    img.drive = .{ ext[1] & 0x0F, ext[1] >> 4, ext[2] & 0x0F, ext[2] >> 4, ext[3] & 0x0F, ext[3] >> 4 };
    img.chip_id = readU16(ext[4..6]);
    img.min_rev = ext[6];
    img.min_rev_full = readU16(ext[7..9]);
    img.max_rev_full = readU16(ext[9..11]);
    // ext[11..15] 是保留字段；非零不阻断解析（可能来自更新版本打包器）。
    for (ext[11..15]) |b| {
        if (b != 0) std.debug.print("note: extended header reserved byte 0x{x:0>2} is nonzero\n", .{b});
    }
    if (ext[15] > 1) {
        return fail("extended header hash flag is 0x{x:0>2}, must be 0x00 or 0x01", .{ext[15]});
    }
    img.hash_appended = ext[15] == 1;

    var pos: usize = common_header_len + extended_header_len;
    var idx: usize = 0;
    while (idx < img.segment_count) : (idx += 1) {
        if (pos + segment_header_len > data.len) {
            return fail("segment {d}: header runs past the end of the file", .{idx});
        }
        const load_addr = readU32(data[pos..][0..4]);
        const size = readU32(data[pos + 4 ..][0..4]);
        pos += segment_header_len;
        if (size % 4 != 0) {
            return fail("segment {d}: length 0x{x} is not a multiple of 4", .{ idx, size });
        }
        if (size > data.len - pos) {
            return fail("segment {d}: payload of 0x{x} bytes runs past the end of the file", .{ idx, size });
        }
        img.segments[idx] = .{ .load_addr = load_addr, .size = size, .data_off = pos };
        img.segment_len = idx + 1;
        pos += size;
    }

    // 校验和字节之前可能有 0..15 个 0x00 填充，使该字节落在 16 字节边界上。
    const checksum_off = (pos + checksum_align - 1) & ~(checksum_align - 1);
    if (checksum_off >= data.len) {
        return fail("no checksum byte after the last segment (need offset 0x{x})", .{checksum_off});
    }
    img.checksum_off = checksum_off;
    img.stored_checksum = data[checksum_off];

    var computed: u8 = checksum_seed;
    for (img.segments[0..img.segment_len]) |seg| {
        for (data[seg.data_off .. seg.data_off + seg.size]) |b| computed ^= b;
    }
    img.computed_checksum = computed;

    img.image_len = checksum_off + 1;
    if (img.hash_appended) {
        if (img.image_len + sha256_len > data.len) {
            return fail(
                "image declares an appended SHA256 but only {d} bytes remain after the checksum",
                .{data.len - img.image_len},
            );
        }
        img.digest_off = img.image_len;
        img.image_len += sha256_len;
    }
    return img;
}

fn reportAppImage(out: Out, data: []const u8) !bool {
    const img = try parseAppImage(data);
    var ok = true;

    try out.print("format      : ESP application image (magic 0xE9)\n", .{});
    try out.print("file size   : {d} bytes (0x{x})\n", .{ data.len, data.len });

    try out.print("\n[common header]\n", .{});
    try out.print("  magic            : 0x{x:0>2}\n", .{image_magic});
    try out.print("  segment_count    : {d}\n", .{img.segment_count});
    try out.print("  flash_mode       : 0x{x:0>2} ({s})\n", .{ img.flash_mode, flashModeName(img.flash_mode) });
    try out.print("  flash_size_freq  : 0x{x:0>2} (size {s}, freq {s})\n", .{
        img.flash_size_freq,
        flashSizeName(img.flash_size_freq >> 4),
        flashFreqName(img.flash_size_freq & 0x0F),
    });
    try out.print("  entry_addr       : 0x{x:0>8} ({s})\n", .{ img.entry_addr, regionName(img.entry_addr) });

    try out.print("\n[extended header]\n", .{});
    try out.print("  wp_pin           : 0x{x:0>2}{s}\n", .{
        img.wp_pin,
        if (img.wp_pin == 0xEE) " (disabled)" else "",
    });
    try out.print(
        "  pin drive        : clk={d} q={d} d={d} cs={d} hd={d} wp={d}\n",
        .{ img.drive[0], img.drive[1], img.drive[2], img.drive[3], img.drive[4], img.drive[5] },
    );
    try out.print("  chip_id          : {d} ({s})\n", .{ img.chip_id, chipName(img.chip_id) });
    try out.print("  min_rev          : 0x{x:0>2} / v{d}.{d}\n", .{
        img.min_rev,
        img.min_rev_full / 100,
        img.min_rev_full % 100,
    });
    try out.print("  max_rev          : v{d}.{d}\n", .{ img.max_rev_full / 100, img.max_rev_full % 100 });
    try out.print("  hash_appended    : {d}\n", .{@intFromBool(img.hash_appended)});

    try out.print("\n[segments]\n", .{});
    try out.print("  #   load addr     size      file off    region\n", .{});
    var payload_total: usize = 0;
    for (img.segments[0..img.segment_len], 0..) |seg, i| {
        payload_total += @as(usize, seg.size);
        const region = regionName(seg.load_addr);
        try out.print("  {d:<3} 0x{x:0>8}  0x{x:0>6}  0x{x:0>6}    {s}\n", .{
            i,
            seg.load_addr,
            seg.size,
            seg.data_off,
            region,
        });
        if (seg.load_addr % 4 != 0) {
            try out.print("      note: load address is not 4-byte aligned\n", .{});
        }
        if (isFlashMapped(seg.load_addr) and seg.load_addr % 0x10000 != 0x20) {
            try out.print("      note: flash-mapped segment is not at page offset 0x20\n", .{});
        }
    }
    try out.print("  payload total    : {d} bytes\n", .{payload_total});

    try out.print("\n[checksum]\n", .{});
    try out.print("  offset           : 0x{x} (16-byte aligned)\n", .{img.checksum_off});
    try out.print("  stored           : 0x{x:0>2}\n", .{img.stored_checksum});
    try out.print("  computed (XOR)   : 0x{x:0>2}\n", .{img.computed_checksum});
    if (img.stored_checksum == img.computed_checksum) {
        try out.print("  result           : OK\n", .{});
    } else {
        try out.print("  result           : MISMATCH\n", .{});
        ok = false;
    }

    if (img.digest_off) |digest_off| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data[0..digest_off]);
        var computed: [sha256_len]u8 = undefined;
        hasher.final(&computed);
        const stored = data[digest_off..][0..sha256_len];

        try out.print("\n[sha256]\n", .{});
        try out.print("  offset           : 0x{x} (covers 0x{x} bytes)\n", .{ digest_off, digest_off });
        try out.print("  stored           : ", .{});
        try out.hex(stored);
        try out.print("\n  computed         : ", .{});
        try out.hex(computed[0..]);
        try out.print("\n", .{});
        if (std.mem.eql(u8, computed[0..], stored)) {
            try out.print("  result           : OK\n", .{});
        } else {
            try out.print("  result           : MISMATCH\n", .{});
            ok = false;
        }
    } else {
        try out.print("\n[sha256]\n  appended         : no\n", .{});
    }

    if (data.len > img.image_len) {
        try out.print("\n[padding]\n  trailing bytes   : {d} (after the described image)\n", .{data.len - img.image_len});
    }
    return ok;
}

// ------------------------------------------------------------ 分区表解析

fn parsePartitionEntry(raw: []const u8) PartitionEntry {
    std.debug.assert(raw.len == partition_entry_len);
    var entry: PartitionEntry = std.mem.zeroes(PartitionEntry);
    entry.ptype = raw[2];
    entry.subtype = raw[3];
    entry.offset = readU32(raw[4..8]);
    entry.size = readU32(raw[8..12]);
    @memcpy(entry.label[0..], raw[12..28]);
    var len: usize = 0;
    while (len < entry.label.len and entry.label[len] != 0) : (len += 1) {}
    entry.label_len = len;
    entry.flags = readU32(raw[28..32]);
    return entry;
}

fn reportPartitionTable(out: Out, data: []const u8) !bool {
    var entries: [partition_max_entries]PartitionEntry = undefined;
    var count: usize = 0;

    try out.print("format      : ESP partition table (magic 0xAA50)\n", .{});
    try out.print("file size   : {d} bytes (0x{x})\n", .{ data.len, data.len });

    var pos: usize = 0;
    while (count < partition_max_entries and pos + partition_entry_len <= data.len) {
        if (data[pos] != partition_magic[0] or data[pos + 1] != partition_magic[1]) break;
        entries[count] = parsePartitionEntry(data[pos..][0..partition_entry_len]);
        count += 1;
        pos += partition_entry_len;
    }
    if (count == 0) {
        return fail("no partition entry at offset 0: magic 0xAA50 missing", .{});
    }

    try out.print("\n[entries]\n", .{});
    try out.print("  #   label             type            subtype          offset      size        flags\n", .{});
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = entries[i];
        var name_buf: [16]u8 = undefined;
        const subtype = partitionSubtypeName(&name_buf, entry.ptype, entry.subtype);
        try out.print("  {d:<3} {s:<16}  {s:<14}  {s:<14}   0x{x:0>6}  0x{x:0>6}  0x{x:0>8}\n", .{
            i,
            entry.label[0..entry.label_len],
            partitionTypeName(entry.ptype),
            subtype,
            entry.offset,
            entry.size,
            entry.flags,
        });
    }

    // 对齐约束：app 分区 64 KB 对齐，其余分区 4 KB 对齐。
    i = 0;
    while (i < count) : (i += 1) {
        const entry = entries[i];
        const align: u32 = if (entry.ptype == 0x00) 0x10000 else 0x1000;
        if (entry.offset % align != 0) {
            try out.print(
                "  note: '{s}' at 0x{x} is not {d} KB aligned\n",
                .{ entry.label[0..entry.label_len], entry.offset, align / 1024 },
            );
        }
        if (@as(u64, entry.offset) + @as(u64, entry.size) > 0x1000000) {
            try out.print(
                "  note: '{s}' ends past 16 MB (0x{x})\n",
                .{ entry.label[0..entry.label_len], @as(u64, entry.offset) + @as(u64, entry.size) },
            );
        }
    }
    try out.print("  entries          : {d} (max {d})\n", .{ count, partition_max_entries });

    const entries_len = count * partition_entry_len;
    var ok = true;
    var md5_stored: [partition_md5_len]u8 = undefined;
    var md5_present = false;

    if (pos + partition_entry_len <= data.len and data[pos] == partition_md5_magic[0] and data[pos + 1] == partition_md5_magic[1]) {
        md5_present = true;
        @memcpy(md5_stored[0..], data[pos + 16 ..][0..partition_md5_len]);
    }

    if (md5_present) {
        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(data[0..entries_len]);
        var computed: [partition_md5_len]u8 = undefined;
        hasher.final(&computed);

        try out.print("\n[md5]\n", .{});
        try out.print("  offset           : 0x{x} (covers the {d} entry bytes)\n", .{ pos + 16, entries_len });
        try out.print("  stored           : ", .{});
        try out.hex(md5_stored[0..]);
        try out.print("\n  computed         : ", .{});
        try out.hex(computed[0..]);
        try out.print("\n", .{});
        if (std.mem.eql(u8, computed[0..], md5_stored[0..])) {
            try out.print("  result           : OK\n", .{});
        } else {
            try out.print("  result           : MISMATCH\n", .{});
            ok = false;
        }
        // 尾块以 0xEBEB 开头、后接 14 个 0xFF，再跟 16 字节摘要。
        pos += partition_entry_len;
    } else {
        try out.print("\n[md5]\n  present          : no (table built with --disable-md5sum?)\n", .{});
    }

    if (pos < data.len) {
        var printable: usize = 0;
        for (data[pos..]) |b| {
            if (b != 0xFF) printable += 1;
        }
        try out.print("\n[padding]\n  bytes after table: {d} (0xFF padding: {s})\n", .{
            data.len - pos,
            if (printable == 0) "yes" else "no",
        });
    }
    if (pos > partition_table_max) {
        return fail("parsed table occupies 0x{x} bytes, above the 0xC00 table area", .{pos});
    }
    return ok;
}

// ---------------------------------------------------------------- 入口

fn printUsage() void {
    std.debug.print(
        \\usage: s31-image-inspect <file>
        \\
        \\  <file>  ESP application image  (first byte 0xE9)
        \\          binary partition table (first bytes 0xAA 0x50)
        \\
        \\Host-only reader: parses headers, segments, checksum, SHA256 and the
        \\partition entries with their MD5. Exits non-zero when validation fails.
        \\
    , .{});
}

fn run() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        printUsage();
        std.process.exit(2);
    }
    const path = args[1];

    const data = std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes) catch |err| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(data);

    const out = Out{ .file = std.fs.File.stdout() };
    try out.print("file        : {s}\n", .{path});

    const kind = blk: {
        if (data.len >= 1 and data[0] == image_magic) break :blk Kind.app_image;
        if (data.len >= 2 and data[0] == partition_magic[0] and data[1] == partition_magic[1]) {
            break :blk Kind.partition_table;
        }
        return fail("unrecognized input: first bytes are neither 0xE9 (image) nor 0xAA 0x50 (partition table)", .{});
    };

    const ok = switch (kind) {
        .app_image => try reportAppImage(out, data),
        .partition_table => try reportPartitionTable(out, data),
    };

    try out.print("\nverdict: {s}\n", .{if (ok) "OK" else "FAILED"});
    if (!ok) std.process.exit(1);
}

pub fn main() void {
    run() catch |err| {
        // fail() 已经打印过具体原因，这里不再重复。
        if (err != error.Malformed) {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}
