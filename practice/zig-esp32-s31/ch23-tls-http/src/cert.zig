//! ch23-tls-http：X.509 证书的 DER 子集 —— 构造、解析、验签。
//!
//! **只做最小的、能被自检钉死的那一部分**：
//!
//!   构造（`buildSelfSigned`）：用一个固定 seed 派生 P-256 密钥，把
//!     version/serial/signatureAlgorithm/issuer/validity/subject/
//!     subjectPublicKeyInfo/extensions(SAN + basicConstraints) 写成一串
//!     DER，然后用 ECDSA-P256-SHA256 签 tbsCertificate。没有随机数：
//!     seed 固定、签名 noise 固定，所以产物逐字节可复现（`zig build
//!     gen-fixture` 写出的 `src/testdata/sample-cert.der` 就是它）。
//!
//!   解析（`parse`）：只认这几个标签——SEQUENCE(0x30)、SET(0x31)、
//!     INTEGER(0x02)、OID(0x06)、BIT STRING(0x03)、OCTET STRING(0x04)、
//!     BOOLEAN(0x01)、UTCTime(0x17)、PrintableString(0x13)、
//!     UTF8String(0x0C)、context [0](0xA0)、[3](0xA3)、SAN 的
//!     dNSName(0x82)/iPAddress(0x87)。其余标签一律当“跳过”处理，
//!     不认识的扩展直接忽略——真实证书里 90% 的字节我们不需要看懂。
//!
//!   验签（`verifySignature`）：把 tbsCertificate 原始字节交给
//!     `std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.verify`，
//!     公钥从 subjectPublicKeyInfo 的 BIT STRING 里取（uncompressed
//!     SEC1，65 字节）。
//!
//! 边界（章节 23.6/23.11 展开）：
//!   - 不校验证书链（没有 CA store，也没有信任锚），只验“这一张证书的
//!     签名与它自己的公钥自洽”；
//!   - 不检查有效期与当前时间（板上没有可信时钟，ch05 的时钟章节只管
//!     系统定时器）；
//!   - 不支持 RSA / Ed25519 / 压缩点 / 多段 RDN / TeletexString；
//!   - DER 的构造侧只用于**造 fixture**，不是通用编码器。
//!
//! 所有解析结果都借用输入切片（`[]const u8` 指向 DER 缓冲），
//! 不分配、不拷贝。因此 DER 缓冲必须比 `Cert` 活得久——板侧两者都是
//! `.bss` 静态对象，主机测试里 DER 来自 `@embedFile`（.rodata）。

const std = @import("std");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// 本章 fixture 与板侧缓冲的统一上限。真实证书动辄 1–2 KiB；
/// 本章只需要“能装下一个 P-256 自签证书”。
pub const max_cert_len = 768;
/// SAN 条目上限（本工程 fixture 有 3 条：两个 DNS + 一个 IP）。
pub const max_san = 4;

pub const Error = error{
    Truncated,
    BadLength,
    BadTag,
    BadDer,
    MissingField,
    TooManySan,
    NoSpace,
    UnsupportedAlgorithm,
};

pub const UtcTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const Cert = struct {
    /// 整个 tbsCertificate 的原始 DER（签名的输入）。
    tbs: []const u8,
    /// tbs 里 signature 算法的 OID 内容（不含 06/长度）。
    tbs_sig_oid: []const u8,
    /// 外层 signatureAlgorithm 的 OID 内容。
    sig_oid: []const u8,
    /// ECDSA-Sig-Value 的 DER（BIT STRING 去掉 unused-bits 字节之后）。
    sig: []const u8,
    subject_cn: []const u8,
    issuer_cn: []const u8,
    not_before: UtcTime,
    not_after: UtcTime,
    /// subjectPublicKeyInfo 里的曲线 OID 内容。
    spki_curve_oid: []const u8,
    /// uncompressed SEC1 公钥（65 字节，0x04 || X || Y）。
    spki_point: []const u8,
    san: [max_san][]const u8,
    san_len: usize,

    /// 只看 DNS 类型 SAN 的便捷视图（与 `san` 同一批切片）。
    pub fn sanAt(self: *const Cert, i: usize) []const u8 {
        return self.san[i];
    }
};

// ---------------------------------------------------------------------------
// TLV 读取
// ---------------------------------------------------------------------------

pub const Tlv = struct {
    tag: u8,
    /// 含 tag 与长度字节的完整编码（签名要的正是这个）。
    raw: []const u8,
    /// 只含内容。
    body: []const u8,
};

/// 从 `der[pos.*]` 读一个 TLV，并前移 `pos`。
pub fn nextTlv(der: []const u8, pos: *usize) Error!Tlv {
    var p = pos.*;
    if (p + 2 > der.len) return Error.Truncated;
    const tag = der[p];
    p += 1;
    var len: usize = der[p];
    p += 1;
    if (len & 0x80 != 0) {
        const n = len & 0x7F;
        // 本章上限 768 字节，长度最多两字节就够了；三字节也接受。
        if (n == 0 or n > 3) return Error.BadLength;
        if (p + n > der.len) return Error.Truncated;
        len = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) len = (len << 8) | der[p + i];
        p += n;
    }
    if (p + len > der.len) return Error.Truncated;
    const raw = der[pos.* .. p + len];
    pos.* = p + len;
    return .{ .tag = tag, .raw = raw, .body = der[p .. p + len] };
}

fn expectTag(tlv: Tlv, tag: u8) Error!Tlv {
    if (tlv.tag != tag) return Error.BadTag;
    return tlv;
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

const oid_cn = [_]u8{ 0x55, 0x04, 0x03 }; // 2.5.4.3 commonName
const oid_san = [_]u8{ 0x55, 0x1D, 0x11 }; // 2.5.29.17 subjectAltName
const oid_ec_pubkey = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 }; // 1.2.840.10045.2.1
const oid_prime256v1 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 }; // 1.2.840.10045.3.1.7
const oid_ecdsa_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 }; // 1.2.840.10045.4.3.2

pub fn parse(der: []const u8) Error!Cert {
    var pos: usize = 0;
    const root = try expectTag(try nextTlv(der, &pos), 0x30);
    if (pos != der.len) return Error.BadDer; // 尾部有多余字节

    var p: usize = 0;
    const tbs = try expectTag(try nextTlv(root.body, &p), 0x30);
    const sig_alg = try expectTag(try nextTlv(root.body, &p), 0x30);
    const sig_bits = try expectTag(try nextTlv(root.body, &p), 0x03);
    if (p != root.body.len) return Error.BadDer;
    // BIT STRING 的第一个字节是「未使用位数」，ECDSA 签名必须为 0。
    if (sig_bits.body.len < 2 or sig_bits.body[0] != 0) return Error.BadDer;

    var out: Cert = .{
        .tbs = tbs.raw,
        .tbs_sig_oid = undefined,
        .sig_oid = undefined,
        .sig = sig_bits.body[1..],
        .subject_cn = "",
        .issuer_cn = "",
        .not_before = undefined,
        .not_after = undefined,
        .spki_curve_oid = undefined,
        .spki_point = undefined,
        .san = @splat(""),
        .san_len = 0,
    };

    out.sig_oid = try algorithmOid(sig_alg);

    // tbsCertificate 的子元素：可选的 [0] version，然后是
    // serial / signature / issuer / validity / subject / spki / [3] extensions。
    var t: usize = 0;
    var children: [8]Tlv = undefined;
    var n: usize = 0;
    while (t < tbs.body.len) {
        if (n == children.len) return Error.BadDer;
        children[n] = try nextTlv(tbs.body, &t);
        n += 1;
    }
    var i: usize = 0;
    if (n > 0 and children[0].tag == 0xA0) i = 1; // version
    if (n < i + 6) return Error.MissingField;

    const serial = try expectTag(children[i], 0x02);
    _ = serial;
    const tbs_alg = try expectTag(children[i + 1], 0x30);
    out.tbs_sig_oid = try algorithmOid(tbs_alg);
    if (!std.mem.eql(u8, out.tbs_sig_oid, &oid_ecdsa_sha256)) return Error.UnsupportedAlgorithm;

    out.issuer_cn = try nameCn(children[i + 2]);
    try validity(children[i + 3], &out.not_before, &out.not_after);
    out.subject_cn = try nameCn(children[i + 4]);
    try spki(children[i + 5], &out.spki_curve_oid, &out.spki_point);

    if (n > i + 6 and children[i + 6].tag == 0xA3) {
        try extensions(children[i + 6], &out);
    }
    return out;
}

/// AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY OPTIONAL }
fn algorithmOid(alg: Tlv) Error![]const u8 {
    var p: usize = 0;
    const oid = try expectTag(try nextTlv(alg.body, &p), 0x06);
    return oid.body;
}

/// Name ::= SEQUENCE OF RelativeDistinguishedName(SET OF AttributeTypeAndValue)
fn nameCn(name: Tlv) Error![]const u8 {
    var p: usize = 0;
    while (p < name.body.len) {
        const rdn = try expectTag(try nextTlv(name.body, &p), 0x31);
        var q: usize = 0;
        while (q < rdn.body.len) {
            // SET 里理论上可以有多值；本章只按「每 SET 一个属性」处理。
            const atv = try expectTag(try nextTlv(rdn.body, &q), 0x30);
            var r: usize = 0;
            const oid = try expectTag(try nextTlv(atv.body, &r), 0x06);
            if (std.mem.eql(u8, oid.body, &oid_cn)) {
                const value = try nextTlv(atv.body, &r);
                return value.body;
            }
        }
    }
    return Error.MissingField;
}

fn validity(v: Tlv, not_before: *UtcTime, not_after: *UtcTime) Error!void {
    var p: usize = 0;
    const nb = try expectTag(try nextTlv(v.body, &p), 0x17);
    const na = try expectTag(try nextTlv(v.body, &p), 0x17);
    not_before.* = try parseUtcTime(nb.body);
    not_after.* = try parseUtcTime(na.body);
}

/// UTCTime 的 DER 形式固定 13 字节：YYMMDDhhmmssZ。
pub fn parseUtcTime(t: []const u8) Error!UtcTime {
    if (t.len != 13 or t[12] != 'Z') return Error.BadDer;
    var digits: [12]u8 = undefined;
    for (t[0..12], 0..) |c, i| {
        if (c < '0' or c > '9') return Error.BadDer;
        digits[i] = c - '0';
    }
    const yy = @as(u16, digits[0]) * 10 + digits[1];
    return .{
        // RFC 5280 §4.1.2.5.1：YY < 50 记 20YY，否则 19YY。
        .year = if (yy < 50) 2000 + yy else 1900 + yy,
        .month = digits[2] * 10 + digits[3],
        .day = digits[4] * 10 + digits[5],
        .hour = digits[6] * 10 + digits[7],
        .minute = digits[8] * 10 + digits[9],
        .second = digits[10] * 10 + digits[11],
    };
}

fn spki(seq: Tlv, curve_oid: *[]const u8, point: *[]const u8) Error!void {
    var p: usize = 0;
    const alg = try expectTag(try nextTlv(seq.body, &p), 0x30);
    const bits = try expectTag(try nextTlv(seq.body, &p), 0x03);

    var q: usize = 0;
    const key_oid = try expectTag(try nextTlv(alg.body, &q), 0x06);
    if (!std.mem.eql(u8, key_oid.body, &oid_ec_pubkey)) return Error.UnsupportedAlgorithm;
    const curve = try expectTag(try nextTlv(alg.body, &q), 0x06);
    if (!std.mem.eql(u8, curve.body, &oid_prime256v1)) return Error.UnsupportedAlgorithm;
    curve_oid.* = curve.body;

    if (bits.body.len < 2 or bits.body[0] != 0) return Error.BadDer;
    const sec1 = bits.body[1..];
    // uncompressed SEC1：65 字节，首字节 0x04。
    if (sec1.len != 65 or sec1[0] != 0x04) return Error.UnsupportedAlgorithm;
    point.* = sec1;
}

fn extensions(wrapper: Tlv, out: *Cert) Error!void {
    // [3] EXPLICIT Extensions ::= SEQUENCE OF Extension
    var p: usize = 0;
    const list = try expectTag(try nextTlv(wrapper.body, &p), 0x30);
    var q: usize = 0;
    while (q < list.body.len) {
        const ext = try expectTag(try nextTlv(list.body, &q), 0x30);
        var r: usize = 0;
        const oid = try expectTag(try nextTlv(ext.body, &r), 0x06);
        // 可选 critical BOOLEAN 出现在 OID 之后。
        var value = try nextTlv(ext.body, &r);
        if (value.tag == 0x01) value = try nextTlv(ext.body, &r);
        if (value.tag != 0x04) return Error.BadTag;
        if (std.mem.eql(u8, oid.body, &oid_san)) {
            try parseSan(value.body, out);
        }
    }
}

fn parseSan(octets: []const u8, out: *Cert) Error!void {
    var p: usize = 0;
    const list = try expectTag(try nextTlv(octets, &p), 0x30);
    var q: usize = 0;
    while (q < list.body.len) {
        const name = try nextTlv(list.body, &q);
        switch (name.tag) {
            // GeneralName 的 context-specific primitive 标签：
            //   dNSName      [2] IA5String -> 0x82
            //   iPAddress    [7] OCTET STRING -> 0x87
            0x82, 0x87 => {
                if (out.san_len == max_san) return Error.TooManySan;
                if (name.body.len == 0) return Error.BadDer;
                out.san[out.san_len] = name.body;
                out.san_len += 1;
            },
            else => continue,
        }
    }
}

// ---------------------------------------------------------------------------
// 验签
// ---------------------------------------------------------------------------

/// 验签可能返回的错误：本模块的错误 + std 的编码/曲线/点判定错误。
pub const VerifyError = Error || std.crypto.errors.Error;

/// 用证书自带的公钥验 tbsCertificate 的签名。
///
/// 这是**自洽校验**：证明 DER 里三段（tbs / 公钥 / 签名）互相匹配，
/// 不证明“这个公钥被谁信任”。信任锚不在本章范围内。
pub fn verifySignature(cert: *const Cert) VerifyError!void {
    if (!std.mem.eql(u8, cert.sig_oid, &oid_ecdsa_sha256)) return Error.UnsupportedAlgorithm;
    const sig = try Ecdsa.Signature.fromDer(cert.sig);
    const pk = try Ecdsa.PublicKey.fromSec1(cert.spki_point);
    try sig.verify(cert.tbs, pk);
}

/// fixture 的 SHA-256 指纹（用来在自检里打印“验的是哪张证书”）。
pub fn fingerprint(der: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(der, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// 构造（只在生成 fixture / 自检里用）
// ---------------------------------------------------------------------------

/// 反向写 DER：从缓冲尾部往前写。写内容时还不知道自己的长度，
/// 写完一层再补 tag+长度头。这样不需要两遍扫描，也不需要分配。
///
/// 约定：
///   - `mark = r.pos`（写这批内容**之前**的缓冲下标）；
///   - 内容写完后 `content_len = mark - r.pos`；
///   - 一个容器的子元素必须**倒序**写（先写最后一个孩子）；
///   - `put(slice)` 保持 slice 内部顺序，所以「A || B」是「先 put(B) 再 put(A)」。
const Rev = struct {
    buf: []u8,
    pos: usize,

    fn init(buf: []u8) Rev {
        return .{ .buf = buf, .pos = buf.len };
    }

    fn put(self: *Rev, bytes: []const u8) Error!void {
        if (bytes.len > self.pos) return Error.NoSpace;
        self.pos -= bytes.len;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
    }

    /// 给「从 mark 之后写到现在」的内容补上 tag + 长度。
    fn endTag(self: *Rev, mark: usize, tag: u8) Error!void {
        if (mark < self.pos) return Error.BadDer;
        const content_len = mark - self.pos;
        var hdr: [6]u8 = undefined;
        hdr[0] = tag;
        var n: usize = 2;
        if (content_len < 0x80) {
            hdr[1] = @intCast(content_len);
        } else {
            const count: usize = if (content_len <= 0xFF) 1 else if (content_len <= 0xFFFF) 2 else 3;
            hdr[1] = 0x80 | @as(u8, @intCast(count));
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const shift: u6 = @intCast(8 * (count - 1 - i));
                hdr[2 + i] = @intCast((content_len >> shift) & 0xFF);
            }
            n = 2 + count;
        }
        try self.put(hdr[0..n]);
    }

    fn slice(self: *const Rev) []u8 {
        return self.buf[self.pos..];
    }
};

/// 单个 primitive TLV：内容在缓冲里已经是正序，头补在前面。
fn putPrim(r: *Rev, tag: u8, content: []const u8) Error!void {
    const mark = r.pos;
    try r.put(content);
    try r.endTag(mark, tag);
}

fn putOid(r: *Rev, oid: []const u8) Error!void {
    try putPrim(r, 0x06, oid);
}

/// AlgorithmIdentifier ::= SEQUENCE { algorithm OID }
fn putAlgorithm(r: *Rev, oid: []const u8) Error!void {
    const mark = r.pos;
    try putOid(r, oid);
    try r.endTag(mark, 0x30);
}

/// BIT STRING 的内容必须以 unused-bits=0 开头。
fn putBitString(r: *Rev, content: []const u8) Error!void {
    const mark = r.pos;
    try r.put(content); // 先写右半部分
    try r.put(&[_]u8{0}); // 再把 0x00 补到它前面
    try r.endTag(mark, 0x03);
}

/// Name 的一层 SET：SET { SEQUENCE { OID, value } }
fn putAtvSet(r: *Rev, oid: []const u8, value_tag: u8, value: []const u8) Error!void {
    const set_mark = r.pos;
    const atv_mark = r.pos;
    // 倒序：value 在前？不是——DER 里 OID 在前，所以先写 value。
    try putPrim(r, value_tag, value);
    try putOid(r, oid);
    try r.endTag(atv_mark, 0x30);
    try r.endTag(set_mark, 0x31);
}

const oid_country = [_]u8{ 0x55, 0x04, 0x06 }; // 2.5.4.6
const oid_org = [_]u8{ 0x55, 0x04, 0x0A }; // 2.5.4.10
const fixture_cn = "ch23-stub.local";

/// Name ::= SEQUENCE OF SET。DER 里字段顺序 CN、O、C，倒着写。
fn putName(r: *Rev) Error!void {
    const mark = r.pos;
    try putAtvSet(r, &oid_country, 0x13, "CN"); // PrintableString
    try putAtvSet(r, &oid_org, 0x0C, "Zig x S31 Lab"); // UTF8String
    try putAtvSet(r, &oid_cn, 0x0C, fixture_cn);
    try r.endTag(mark, 0x30);
}

/// Extension { OID 2.5.29.17, OCTET STRING { GeneralNames } }
fn putSanExtension(r: *Rev) Error!void {
    const ext_mark = r.pos;
    const value_mark = r.pos;
    const names_mark = r.pos;
    // GeneralNames 的 DER 顺序是 apex、www、IP；倒着写。
    try putPrim(r, 0x87, &[_]u8{ 0x7F, 0x00, 0x00, 0x01 }); // iPAddress
    try putPrim(r, 0x82, "www.ch23.local"); // dNSName
    try putPrim(r, 0x82, "ch23.local");
    try r.endTag(names_mark, 0x30);
    try r.endTag(value_mark, 0x04); // OCTET STRING 包住 GeneralNames
    try putOid(r, &oid_san);
    try r.endTag(ext_mark, 0x30);
}

/// subjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }
fn putSpki(r: *Rev, sec1: *const [65]u8) Error!void {
    const mark = r.pos;
    try putBitString(r, sec1);
    const alg_mark = r.pos;
    try putOid(r, &oid_prime256v1); // 曲线参数在后
    try putOid(r, &oid_ec_pubkey); // 算法 OID 在前
    try r.endTag(alg_mark, 0x30);
    try r.endTag(mark, 0x30);
}

/// Validity ::= SEQUENCE { notBefore, notAfter }
fn putValidity(r: *Rev) Error!void {
    const mark = r.pos;
    try putPrim(r, 0x17, "270101000000Z");
    try putPrim(r, 0x17, "260101000000Z");
    try r.endTag(mark, 0x30);
}

/// [3] EXPLICIT Extensions ::= SEQUENCE OF Extension
fn putExtensions(r: *Rev) Error!void {
    const explicit_mark = r.pos;
    const list_mark = r.pos;
    try putSanExtension(r);
    try r.endTag(list_mark, 0x30);
    try r.endTag(explicit_mark, 0xA3);
}

fn putTbs(r: *Rev, sec1: *const [65]u8) Error!void {
    const mark = r.pos;
    // tbsCertificate 的字段顺序：version, serial, sigAlg, issuer, validity,
    // subject, spki, extensions。倒着写。
    try putExtensions(r);
    try putSpki(r, sec1);
    try putName(r); // subject
    try putValidity(r);
    try putName(r); // issuer（自签：与 subject 相同）
    try putAlgorithm(r, &oid_ecdsa_sha256);
    try putPrim(r, 0x02, &[_]u8{ 0x01, 0x23, 0x45, 0x67 }); // serialNumber
    const ver_mark = r.pos;
    try putPrim(r, 0x02, &[_]u8{0x02}); // v3
    try r.endTag(ver_mark, 0xA0); // [0] EXPLICIT
    try r.endTag(mark, 0x30);
}

/// 构造自签证书。seed 固定 => 密钥固定；ECDSA 的 k 由 noise=0 固定，
/// 所以同一份源码永远产出同一串字节（`zig build gen-fixture` 依赖这一点）。
pub fn buildSelfSigned(buf: []u8) Error![]u8 {
    const seed: [32]u8 = @splat(0x23);
    const kp = Ecdsa.KeyPair.generateDeterministic(seed) catch return Error.BadDer;
    const sec1 = kp.public_key.toUncompressedSec1();

    // 1) tbsCertificate 先落在自己的缓冲里：签名要它的原始字节。
    var tbs_buf: [640]u8 = undefined;
    var tr = Rev.init(&tbs_buf);
    try putTbs(&tr, &sec1);
    const tbs = tr.slice();

    // 2) 签 tbs。
    const noise: [32]u8 = @splat(0);
    const sig = kp.sign(tbs, noise) catch return Error.BadDer;
    var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&sig_buf);

    // 3) Certificate ::= SEQUENCE { tbs, AlgorithmIdentifier, BIT STRING }
    var r = Rev.init(buf);
    const cert_mark = r.pos;
    try putBitString(&r, sig_der);
    try putAlgorithm(&r, &oid_ecdsa_sha256);
    try r.put(tbs); // tbs 已自带 SEQUENCE 头
    try r.endTag(cert_mark, 0x30);
    return r.slice();
}

// ---------------------------------------------------------------------------
// 落盘 fixture
// ---------------------------------------------------------------------------

/// `zig build gen-fixture` 写出的那份 DER。
///
/// 它由 `buildSelfSigned` 生成（固定 seed + 固定 noise ⇒ 逐字节确定），
/// 并用 OpenSSL 3.6.4（`ssl._ssl._test_decode_cert`）交叉验证过：subject /
/// issuer / SAN / 有效期 / 版本 / serial 都与本文件的构造字段一致。
/// 下面的 test 会把「重新构造的字节」与它逐字节比对——fixture 一旦漂移，
/// 单测立刻失败。
pub const fixture_der = @embedFile("testdata/sample-cert.der");

test "fixture parses to the fields we constructed" {
    const c = try parse(fixture_der);
    try std.testing.expectEqualStrings("ch23-stub.local", c.subject_cn);
    try std.testing.expectEqualStrings("ch23-stub.local", c.issuer_cn);
    try std.testing.expectEqual(@as(usize, 3), c.san_len);
    try std.testing.expectEqualStrings("ch23.local", c.sanAt(0));
    try std.testing.expectEqualStrings("www.ch23.local", c.sanAt(1));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x7F, 0x00, 0x00, 0x01 }, c.sanAt(2));
    try std.testing.expectEqual(@as(u16, 2026), c.not_before.year);
    try std.testing.expectEqual(@as(u8, 1), c.not_before.month);
    try std.testing.expectEqual(@as(u16, 2027), c.not_after.year);
    try std.testing.expectEqual(@as(usize, 65), c.spki_point.len);
    try std.testing.expectEqual(@as(u8, 0x04), c.spki_point[0]);
    try std.testing.expectEqualSlices(u8, &oid_prime256v1, c.spki_curve_oid);
}

test "fixture signature verifies with its own public key" {
    const c = try parse(fixture_der);
    try verifySignature(&c);
}

test "rebuilding the certificate reproduces the fixture bytes" {
    var buf: [max_cert_len]u8 = undefined;
    const der = try buildSelfSigned(&buf);
    try std.testing.expectEqualSlices(u8, fixture_der, der);
}

test "tampered tbs fails verification" {
    var buf: [max_cert_len]u8 = undefined;
    @memcpy(buf[0..fixture_der.len], fixture_der);
    // 翻掉 subject CN 里的一个字符（'c' -> 'd'）：DER 结构与公钥都没变，
    // 只有签名不再成立。
    const idx = std.mem.indexOf(u8, buf[0..fixture_der.len], "ch23-stub.local").?;
    buf[idx] = 'd';
    const c = try parse(buf[0..fixture_der.len]);
    try std.testing.expectError(error.SignatureVerificationFailed, verifySignature(&c));
}
