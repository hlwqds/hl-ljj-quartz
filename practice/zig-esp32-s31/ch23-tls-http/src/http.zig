//! ch23-tls-http：HTTP/1.1 的最小解析与响应构造（RFC 9112）。
//!
//! 为什么在 TLS 章节里写 HTTP？因为 TLS 是**用的**：不解出一个请求、
//! 不造出一个响应，“能加密”就没有可验证的出口。本章把这条链的两端
//! 剥到最小：TLS 侧是记录层 + 密钥派生 + AEAD（都不需要报文），HTTP 侧是
//! 一条请求的解析与一条响应的拼装（都不需要 socket）。
//!
//! 解析器的边界（全部是**故意**的取舍，23.7 逐条展开）：
//!
//!   - 只认 `CRLF`（RFC 9112 §2.2 允许服务端接受单独的 `LF`，本章不接）；
//!   - 请求行三段：`method SP request-target SP HTTP-version`；
//!   - 首部最多 16 条、每条最多 256 字节（`.bss` 静态表）；
//!   - `Content-Length` 与 `Transfer-Encoding: chunked` 同时出现 → 拒绝
//!     （RFC 9112 §6.1 的请求走私防线）；
//!   - 不做 URL 解码、不做 query 参数解析、不读请求体（本章不解体，
//!     只报告长度）；
//!   - 不处理 obs-fold（行折叠，RFC 9112 §5.2 已废弃）。
//!
//! keep-alive 的判定（RFC 9112 §9.3）：
//!
//!   HTTP/1.1 默认持久连接，除非 `Connection: close`；
//!   HTTP/1.0 默认关闭，除非 `Connection: keep-alive`。
//!
//! 响应构造只写状态行 + 三个首部 + body：`Content-Length` 必须与 body
//! 长度一致（本章用同一个变量算两次），`Connection` 要与请求的判定一致，
//! 否则代理会按错误的边界拆包。

const std = @import("std");

pub const max_headers = 16;
pub const max_header_line = 256;
pub const max_target = 512;

pub const Error = error{
    Incomplete,
    BadRequestLine,
    BadMethod,
    BadVersion,
    TooManyHeaders,
    BadHeader,
    BadContentLength,
    AmbiguousFraming,
    BadChunkSize,
    BadChunkTerminator,
    NoSpace,
};

pub const Method = enum { get, head, post, put, delete, options, other };

pub const Version = enum { http_1_0, http_1_1 };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    method_text: []const u8,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    version: Version,
    headers: [max_headers]Header = undefined,
    header_len: usize = 0,
    content_length: ?usize = null,
    chunked: bool = false,
    keep_alive: bool = false,

    /// 大小写不敏感的首部查找（RFC 9110 §5.1）。
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_len]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

fn methodFromText(text: []const u8) Method {
    const names = [_]struct { n: []const u8, m: Method }{
        .{ .n = "GET", .m = .get },
        .{ .n = "HEAD", .m = .head },
        .{ .n = "POST", .m = .post },
        .{ .n = "PUT", .m = .put },
        .{ .n = "DELETE", .m = .delete },
        .{ .n = "OPTIONS", .m = .options },
    };
    for (names) |e| {
        if (std.mem.eql(u8, e.n, text)) return e.m;
    }
    return .other;
}

fn containsToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(item, token)) return true;
    }
    return false;
}

/// 解析一条请求的**首部区**（不含 body）。`data` 必须在 `CRLF CRLF` 处结束。
pub fn parseRequest(data: []const u8) Error!Request {
    // 找首部区结束标记：本章不接受裸 LF。
    const end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return Error.Incomplete;
    const head = data[0..end];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return Error.BadRequestLine;

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_text = parts.next() orelse return Error.BadRequestLine;
    const target = parts.next() orelse return Error.BadRequestLine;
    const version_text = parts.next() orelse return Error.BadRequestLine;
    if (parts.next() != null) return Error.BadRequestLine;
    if (method_text.len == 0 or method_text.len > 16) return Error.BadMethod;
    if (target.len == 0 or target.len > max_target) return Error.BadRequestLine;

    const version: Version = if (std.mem.eql(u8, version_text, "HTTP/1.1"))
        .http_1_1
    else if (std.mem.eql(u8, version_text, "HTTP/1.0"))
        .http_1_0
    else
        return Error.BadVersion;

    var req: Request = .{
        .method = methodFromText(method_text),
        .method_text = method_text,
        .target = target,
        .path = target,
        .query = "",
        .version = version,
    };

    // request-target 里 '?' 之后是 query。absolute-form（http://host/p）本章
    // 只按 '?' 切，不解析 authority——够自检用，不够当代理。
    if (std.mem.indexOfScalar(u8, target, '?')) |qpos| {
        req.path = target[0..qpos];
        req.query = target[qpos + 1 ..];
    }

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len > max_header_line) return Error.BadHeader;
        if (line[0] == ' ' or line[0] == '\t') return Error.BadHeader; // obs-fold
        if (req.header_len == max_headers) return Error.TooManyHeaders;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return Error.BadHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) return Error.BadHeader;
        req.headers[req.header_len] = .{ .name = name, .value = value };
        req.header_len += 1;
    }

    if (req.header("Content-Length")) |cl| {
        req.content_length = std.fmt.parseInt(usize, cl, 10) catch return Error.BadContentLength;
    }
    if (req.header("Transfer-Encoding")) |te| {
        req.chunked = containsToken(te, "chunked");
    }
    // RFC 9112 §6.1：两个 framing 首部同时出现时，请求必须被拒绝。
    if (req.chunked and req.content_length != null) return Error.AmbiguousFraming;

    req.keep_alive = keepAlive(version, req.header("Connection") orelse "");
    return req;
}

/// RFC 9112 §9.3 的持久连接判定。
pub fn keepAlive(version: Version, connection: []const u8) bool {
    return switch (version) {
        .http_1_1 => !containsToken(connection, "close"),
        .http_1_0 => containsToken(connection, "keep-alive"),
    };
}

/// 解码 `Transfer-Encoding: chunked`（RFC 9112 §7.1）。
///
/// 返回写入 `out` 的字节数。坏输入的三种形态各自报错：
/// 长度行不是合法十六进制、数据后面缺 CRLF、缺少 0 长度终止块。
pub fn decodeChunked(in: []const u8, out: []u8) Error!usize {
    var pos: usize = 0;
    var written: usize = 0;
    while (true) {
        const line_rel = std.mem.indexOf(u8, in[pos..], "\r\n") orelse return Error.Incomplete;
        const line_end = pos + line_rel;
        const size_text = std.mem.trim(u8, in[pos..line_end], " \t");
        // 允许 `1a;ext=1` 这种扩展，本章只取 ';' 之前。
        const size_part = if (std.mem.indexOfScalar(u8, size_text, ';')) |semi| size_text[0..semi] else size_text;
        if (size_part.len == 0) return Error.BadChunkSize;
        const size = std.fmt.parseInt(usize, size_part, 16) catch return Error.BadChunkSize;
        pos = line_end + 2;

        if (size == 0) {
            // 终止块后可能有 trailer；本章要求立刻是 CRLF 或 trailer 结束。
            if (pos + 2 > in.len) return Error.Incomplete;
            if (std.mem.eql(u8, in[pos..][0..2], "\r\n")) return written;
            // 有 trailer：必须能找到它自己的结束空行。
            if (std.mem.indexOf(u8, in[pos..], "\r\n\r\n") == null) return Error.BadChunkTerminator;
            return written;
        }

        if (pos + size + 2 > in.len) return Error.Incomplete;
        if (written + size > out.len) return Error.NoSpace;
        @memcpy(out[written..][0..size], in[pos..][0..size]);
        written += size;
        pos += size;
        if (!std.mem.eql(u8, in[pos..][0..2], "\r\n")) return Error.BadChunkTerminator;
        pos += 2;
    }
}

/// 构造一条响应：状态行 + Content-Length/Content-Type/Connection + body。
/// 返回整个响应（含 body）的切片。
pub fn buildResponse(
    out: []u8,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
    keep: bool,
) Error![]const u8 {
    const head = std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n", .{
        status,
        reason,
        content_type,
        body.len,
        if (keep) "keep-alive" else "close",
    }) catch return Error.NoSpace;
    if (head.len + body.len > out.len) return Error.NoSpace;
    @memcpy(out[head.len..][0..body.len], body);
    return out[0 .. head.len + body.len];
}

test "parse a GET request" {
    const data = "GET /index.html?x=1 HTTP/1.1\r\nHost: ch23.local\r\nUser-Agent: s31\r\nAccept: */*\r\n\r\n";
    const req = try parseRequest(data);
    try std.testing.expectEqual(Method.get, req.method);
    try std.testing.expectEqualStrings("/index.html", req.path);
    try std.testing.expectEqualStrings("x=1", req.query);
    try std.testing.expectEqual(Version.http_1_1, req.version);
    try std.testing.expectEqual(@as(usize, 3), req.header_len);
    try std.testing.expectEqualStrings("ch23.local", req.header("host").?);
    try std.testing.expect(req.keep_alive);
}

test "chunked decoding" {
    const body = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    const n = try decodeChunked(body, &out);
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqualStrings("Wikipedia", out[0..n]);
    try std.testing.expectError(Error.BadChunkSize, decodeChunked("zz\r\n", &out));
}
