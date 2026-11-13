//! S31 生产化切片 B：生产清单校验的主机侧测试（`zig build test` 的第二个根）。
//!
//! 这些测试只在 x86_64 主机上跑，不打开串口、不写 flash、不接触 IDF。
//! **本次交付未执行**；断言按契约写死，留给主线统一跑。
//!
//! 覆盖 SPEC §3.5 的验收：坏 magic、短头、`image_len` 不符、同版本/降级、
//! verifier 拒绝、verifier 收到原始尾随签名；并额外锁定“结构/版本失败时
//! 绝不调用 verifier”的顺序契约。

const std = @import("std");
const manifest = @import("manifest.zig");

const blob_len = manifest.header_len + manifest.min_signature_len;

fn putU32Le(out: []u8, v: u32) void {
    out[0] = @intCast(v & 0xFF);
    out[1] = @intCast((v >> 8) & 0xFF);
    out[2] = @intCast((v >> 16) & 0xFF);
    out[3] = @intCast((v >> 24) & 0xFF);
}

/// 造一份合法的“44 B 头 + 64 B 签名”。
/// 头：magic 正确、版本/长度按参数、摘要填 `0x5A`。
/// 签名：不透明字节，从 `0x80` 起逐字节递增，用来证明透传时不改写。
fn makeBlob(buf: []u8, version: u32, image_len: u32) void {
    @memcpy(buf[0..4], &manifest.magic);
    putU32Le(buf[4..8], version);
    putU32Le(buf[8..12], image_len);
    @memset(buf[12..manifest.header_len], 0x5A);

    var i: usize = manifest.header_len;
    while (i < buf.len) : (i += 1) {
        buf[i] = @truncate(0x80 + (i - manifest.header_len));
    }
}

fn expectBytes(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqual(e, a);
    }
}

/// 测试替身：记录调用次数、各切片长度、头前 4 B 与完整签名字节。
/// 真正的 SHA-256 / Ed25519 由主线后续切片实现，本切片只验证接线。
const Spy = struct {
    accept: bool = true,
    calls: u32 = 0,
    header_seen: usize = 0,
    image_seen: usize = 0,
    signature_seen: usize = 0,
    signature: [manifest.min_signature_len]u8 = undefined,
    head4: [4]u8 = undefined,

    fn call(
        ctx: ?*anyopaque,
        header: []const u8,
        image: []const u8,
        signature: []const u8,
    ) bool {
        const self: *Spy = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.header_seen = header.len;
        self.image_seen = image.len;
        self.signature_seen = signature.len;

        const n = @min(signature.len, self.signature.len);
        @memcpy(self.signature[0..n], signature[0..n]);
        @memcpy(&self.head4, header[0..4]);
        return self.accept;
    }

    fn verifier(self: *Spy) manifest.Verifier {
        const raw: *anyopaque = self;
        return .{ .ctx = raw, .verifyFn = call };
    }
};

test "header decode exposes version, image_len and raw digest" {
    var buf: [blob_len]u8 = undefined;
    makeBlob(buf[0..], 7, 1234);

    const header = try manifest.decodeHeader(buf[0..]);
    try std.testing.expectEqual(@as(u32, 7), header.version);
    try std.testing.expectEqual(@as(u32, 1234), header.image_len);

    var expected_digest: [32]u8 = undefined;
    @memset(&expected_digest, 0x5A);
    try expectBytes(&expected_digest, &header.digest);

    const parts = try manifest.split(buf[0..]);
    try std.testing.expectEqual(manifest.header_len, parts.header.len);
    try std.testing.expectEqual(manifest.min_signature_len, parts.signature.len);

    // `decodeHeader` 只看头，签名缺失也能读元数据。
    try manifest.decodeHeader(buf[0..manifest.header_len]);
}

test "short header is rejected before the verifier" {
    var buf: [blob_len]u8 = undefined;
    makeBlob(buf[0..], 3, 2);
    var spy = Spy{};

    try std.testing.expectError(
        error.ShortHeader,
        manifest.validateCandidate(spy.verifier(), buf[0 .. manifest.header_len - 1], "ab", 1),
    );
    try std.testing.expectEqual(@as(u32, 0), spy.calls);
}

test "bad magic is rejected before the verifier" {
    var buf: [blob_len]u8 = undefined;
    makeBlob(buf[0..], 3, 2);
    buf[0] = 'X';
    var spy = Spy{};

    try std.testing.expectError(
        error.BadMagic,
        manifest.validateCandidate(spy.verifier(), buf[0..], "ab", 1),
    );
    try std.testing.expectEqual(@as(u32, 0), spy.calls);
}

test "signature shorter than 64 B is rejected before the verifier" {
    var buf: [blob_len]u8 = undefined;
    makeBlob(buf[0..], 3, 2);
    var spy = Spy{};

    // 63 B 签名：结构不合规，即使头合法也不进入验签。
    try std.testing.expectError(
        error.SignatureTooShort,
        manifest.validateCandidate(
            spy.verifier(),
            buf[0 .. manifest.header_len + manifest.min_signature_len - 1],
            "ab",
            1,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), spy.calls);
}

test "image_len mismatch is rejected before the verifier" {
    var buf: [blob_len]u8 = undefined;
    const image = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    makeBlob(buf[0..], 3, image.len + 1);
    var spy = Spy{};

    try std.testing.expectError(
        error.LengthMismatch,
        manifest.validateCandidate(spy.verifier(), buf[0..], image[0..], 1),
    );
    try std.testing.expectEqual(@as(u32, 0), spy.calls);
}

test "equal and lower versions are rejected before the verifier" {
    var buf: [blob_len]u8 = undefined;
    const image = [_]u8{ 1, 2, 3, 4 };
    var spy = Spy{};

    makeBlob(buf[0..], 9, image.len);
    try std.testing.expectError(
        error.Downgrade,
        manifest.validateCandidate(spy.verifier(), buf[0..], image[0..], 9),
    );

    makeBlob(buf[0..], 8, image.len);
    try std.testing.expectError(
        error.Downgrade,
        manifest.validateCandidate(spy.verifier(), buf[0..], image[0..], 9),
    );

    try std.testing.expectEqual(@as(u32, 0), spy.calls);
}

test "verifier rejection surfaces as Rejected after structure and version pass" {
    var buf: [blob_len]u8 = undefined;
    const image = [_]u8{ 1, 2, 3, 4 };
    makeBlob(buf[0..], 9, image.len);
    var spy = Spy{ .accept = false };

    try std.testing.expectError(
        error.Rejected,
        manifest.validateCandidate(spy.verifier(), buf[0..], image[0..], 8),
    );
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
    try std.testing.expectEqual(manifest.min_signature_len, spy.signature_seen);
}

test "verifier receives the original header, image and trailing signature" {
    var buf: [blob_len]u8 = undefined;
    const image = [_]u8{ 0xCA, 0xFE, 0xBA, 0xBE };
    makeBlob(buf[0..], 42, image.len);
    var spy = Spy{};

    const header = try manifest.validateCandidate(spy.verifier(), buf[0..], image[0..], 41);
    try std.testing.expectEqual(@as(u32, 42), header.version);
    try std.testing.expectEqual(@as(u32, 4), header.image_len);
    try std.testing.expectEqual(@as(u32, 1), spy.calls);

    // 头必须恰好 44 B，且原样传递。
    try std.testing.expectEqual(manifest.header_len, spy.header_seen);
    try std.testing.expectEqual(@as(usize, 4), spy.image_seen);
    try expectBytes(buf[0..4], &spy.head4);

    // 签名是原始尾字节，不被裁剪或重编码。
    try std.testing.expectEqual(manifest.min_signature_len, spy.signature_seen);
    try expectBytes(buf[manifest.header_len..], spy.signature[0..]);
}
