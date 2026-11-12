#!/usr/bin/env python3
"""ch26-wifi-connection-wpa2-wpa3 / 交叉实现向量生成器。

本脚本**不是**被测代码，它是被测代码的对照实现：用 CPython 的
`hashlib.pbkdf2_hmac` / `hmac` / `hashlib.sha256`（与 Zig 的
`std.crypto.pwhash.pbkdf2`、`std.crypto.auth.hmac` 完全独立的一份实现）
把本工程的每一条密码学判据的期望值算一遍。

`src/selftest.zig` 与 `src/host_tests.zig` 里的每个十六进制常数因此有两个
来源之一：

  1. 公开标准向量：RFC 6070 §2 的 PBKDF2-HMAC-SHA1 四条；
     passphrase "password" / SSID "IEEE" 的 WPA2 PSK 向量（802.11i Annex H.4 的
     PSK 派生，被 hostap/wpa_supplicant 的测试文档沿用）；
  2. 本脚本为「本工程固定输入」算出的值（PTK、EAPOL MIC、SAE 派生）。
     这些值的权威性来自**两套独立实现逐字节一致**，不来自标准文本：
     Zig 实现写错了，两边就对不上。

SAE 部分刻意照抄 hostap 的字段布局（本机 IDF
`components/wpa_supplicant/src/common/sae.c`）：pwd-seed 用
HMAC-SHA256(MAX(addr)||MIN(addr), password||LE16(counter))，pwd-value 用
`sha256_prf_bits`，KCK/PMK 用 `sha256_prf_bits(keyseed, "SAE KCK and PMK", ...)`，
confirm 用 `HMAC-SHA256(KCK, LE16(send-confirm)||scalar||element||...)`。

用法：
    python3 tools/vectors.py            # 打印全部常数
    python3 tools/vectors.py --zig      # 追加 Zig 常量块
"""

from __future__ import annotations

import hashlib
import hmac
import sys

# ---------------------------------------------------------------------------
# 固定输入：章节点名，全部是十六进制或 ASCII，读者可逐字节复现
# ---------------------------------------------------------------------------

PASSPHRASE = b"password"
SSID = b"IEEE"

AP_MAC = bytes.fromhex("021122334455")
STA_MAC = bytes.fromhex("02aabbccddee")

ANONCE = bytes(range(0x00, 0x20))
SNONCE = bytes(range(0x20, 0x40))

# 标准 WPA2-PSK CCMP 的 RSN IE（22 字节），msg2 的 key data 就用它。
RSN_IE = bytes.fromhex("30140100000fac040100000fac040100000fac020000")

# 802.11i 8.5.1.1 的 PRF label：PMK 派生的 PTK 用这一条。
PTK_LABEL = b"Pairwise key expansion"


def hx(data: bytes) -> str:
    return data.hex()


def u16be(v: int) -> bytes:
    return v.to_bytes(2, "big")


def u16le(v: int) -> bytes:
    return v.to_bytes(2, "little")


# ---------------------------------------------------------------------------
# 1) PBKDF2-HMAC-SHA1（RFC 2898 / RFC 6070；802.11i Annex H.4 的 PSK 派生）
# ---------------------------------------------------------------------------


def pbkdf2(password: bytes, salt: bytes, rounds: int, dk_len: int) -> bytes:
    return hashlib.pbkdf2_hmac("sha1", password, salt, rounds, dk_len)


# RFC 6070 §2 的四条向量（本脚本只是复算，不是它的出处）
RFC6070 = [
    ("c1", b"password", b"salt", 1, 20),
    ("c2", b"password", b"salt", 2, 20),
    ("c4096", b"password", b"salt", 4096, 20),
    (
        "long",
        b"passwordPASSWORDpassword",
        b"saltSALTsaltSALTsaltSALTsaltSALTsalt",
        4096,
        25,
    ),
]


# ---------------------------------------------------------------------------
# 2) PRF（802.11i 8.5.1.1 / IEEE 802.11-2020 12.7.1.2）
#
#    PRF(K, A, B, len) = HMAC-SHA1(K, A || 0x00 || B || i) 逐块拼接后截断
# ---------------------------------------------------------------------------


def prf(key: bytes, label: bytes, data: bytes, out_len: int) -> bytes:
    out = b""
    i = 0
    while len(out) < out_len:
        out += hmac.new(key, label + b"\x00" + data + bytes([i]), hashlib.sha1).digest()
        i += 1
        assert i <= 256, "PRF 计数器只有 1 字节"
    return out[:out_len]


def wpa2_ptk(pmk: bytes, out_len: int) -> bytes:
    # Min/Max 按字节序比较，不是 MAC 数值比较。
    aa_spa = min(AP_MAC, STA_MAC) + max(AP_MAC, STA_MAC)
    anonce_snonce = min(ANONCE, SNONCE) + max(ANONCE, SNONCE)
    return prf(pmk, PTK_LABEL, aa_spa + anonce_snonce, out_len)


# ---------------------------------------------------------------------------
# 3) EAPOL-Key msg2 + MIC（802.1X-2010 §11.9；802.11i 8.5.2 的 KCK）
#
#    EAPOL 头（4 B）+ Key descriptor（95 B）+ key data（RSN IE，22 B）
#    MIC = HMAC-SHA1(KCK, EAPOL 帧，MIC 字段填 0)[0..16]
# ---------------------------------------------------------------------------


def eapol_key_frame(
    key_info: int, replay: int, nonce: bytes, key_data: bytes, mic: bytes
) -> bytes:
    body = (
        bytes([2])  # descriptor type = RSN
        + u16be(key_info)
        + u16be(0)  # key length（CCMP 的 TK 不在这一帧里下发）
        + replay.to_bytes(8, "big")
        + nonce
        + bytes(16)  # IV（CCMP 用不到）
        + bytes(8)  # RSC
        + bytes(8)  # key ID
        + mic
        + u16be(len(key_data))
        + key_data
    )
    return bytes([2, 3]) + u16be(len(body)) + body


def eapol_mic(kck: bytes, frame: bytes) -> bytes:
    # EAPOL 头 4 B + descriptor type 1 + key_info 2 + key_len 2 + replay 8 +
    # nonce 32 + IV 16 + RSC 8 + key_id 8 = 偏移 81；MIC 占 81..97。
    # 计算时该字段全 0（802.1X-2010 §11.9.1）。
    zeroed = frame[:81] + bytes(16) + frame[97:]
    assert len(zeroed) == len(frame)
    return hmac.new(kck, zeroed, hashlib.sha1).digest()[:16]


# ---------------------------------------------------------------------------
# 4) SAE（802.11-2020 12.4；字段布局照 hostap 的 common/sae.c）
# ---------------------------------------------------------------------------

P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_Q = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

P256_P_BE = P256_P.to_bytes(32, "big")


def hmac_sha256(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def sha256_prf_bits(key: bytes, label: bytes, data: bytes, out_bits: int) -> bytes:
    """sha256-prf.c:sha256_prf_bits —— HMAC-SHA256(K, LE16(i)||label||data||LE16(bits))"""
    out_len = (out_bits + 7) // 8
    out = b""
    counter = 1
    while len(out) < out_len:
        mac = hmac_sha256(key, u16le(counter) + label + data + u16le(out_bits))
        take = min(len(mac), out_len - len(out))
        out += mac[:take]
        counter += 1
    if out_bits % 8:
        out = out[:-1] + bytes([out[-1] & ((0xFF << (8 - out_bits % 8)) & 0xFF)])
    return out


SAE_PASSWORD = b"correct horse battery staple"


def sae_pwd_seed(counter: int) -> bytes:
    # HMAC-SHA256(key = MAX(addr)||MIN(addr), msg = password||LE16(counter))
    key = max(STA_MAC, AP_MAC) + min(STA_MAC, AP_MAC)
    return hmac_sha256(key, SAE_PASSWORD + u16le(counter))


def sae_pwd_value(seed: bytes) -> bytes:
    # sha256_prf_bits(pwd-seed, "SAE Hunting and Pecking", prime, 256)
    return sha256_prf_bits(seed, b"SAE Hunting and Pecking", P256_P_BE, 256)


def mod_reduce(x: bytes, modulus: int) -> bytes:
    return (int.from_bytes(x, "big") % modulus).to_bytes(32, "big")


def mod_q_add(a: bytes, b: bytes) -> bytes:
    return ((int.from_bytes(a, "big") + int.from_bytes(b, "big")) % P256_Q).to_bytes(
        32, "big"
    )


# 本章的「椭圆曲线替身」：K 的 x 坐标、两个 commit 标量与两个 commit 元素
# 都是固定字节串。真实实现里它们来自 EC 点乘，本章不做那一步（见章节 26.5）。
SAE_K = bytes.fromhex(
    "8f2c1d4b7a9e63550c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d"
)
SAE_SCALAR_OWN = bytes.fromhex(
    "7b1f4c2a9d3e50618273a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9"
)
SAE_ELEMENT_OWN = bytes.fromhex(
    "3c6ef372fe94f82be5a1d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a29180e"
    "9d0c1b2a3f4e5d6c7b8a99887766554433221100ffeeddccbbaa998877665544"
)
SAE_SCALAR_PEER = bytes.fromhex(
    "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f801"
)
SAE_ELEMENT_PEER = bytes.fromhex(
    "5a4b3c2d1e0f00112233445566778899aabbccddeeff00112233445566778899"
    "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
)

SAE_LABEL_KCK_PMK = b"SAE KCK and PMK"


def sae_derive(k: bytes) -> dict[str, bytes]:
    # keyseed = HKDF-Extract(salt = 0^32, ikm = k) = HMAC-SHA256(0^32, k)
    keyseed = hmac_sha256(bytes(32), k)
    # KCK || PMK = KDF-Hash-Length(keyseed, "SAE KCK and PMK",
    #                              (own-scalar + peer-scalar) mod r)
    scalar_sum = mod_q_add(SAE_SCALAR_OWN, SAE_SCALAR_PEER)
    kck_pmk = sha256_prf_bits(keyseed, SAE_LABEL_KCK_PMK, scalar_sum, 64 * 8)
    kck, pmk = kck_pmk[:32], kck_pmk[32:]
    pmkid = scalar_sum[:16]
    # confirm = CN(KCK, send-confirm, own-scalar, own-element,
    #              peer-scalar, peer-element)
    confirm_own = hmac_sha256(
        kck,
        u16le(1)
        + SAE_SCALAR_OWN
        + SAE_ELEMENT_OWN
        + SAE_SCALAR_PEER
        + SAE_ELEMENT_PEER,
    )
    confirm_peer = hmac_sha256(
        kck,
        u16le(2)
        + SAE_SCALAR_PEER
        + SAE_ELEMENT_PEER
        + SAE_SCALAR_OWN
        + SAE_ELEMENT_OWN,
    )
    return {
        "keyseed": keyseed,
        "scalar_sum": scalar_sum,
        "kck": kck,
        "pmk": pmk,
        "pmkid": pmkid,
        "confirm_own": confirm_own,
        "confirm_peer": confirm_peer,
    }


# 基域归约的边界用例：P-256 的 p 与 2^256 只差 2^224 量级，随机 256 位
# 几乎总在 [0, p) 里，所以必须专门用「≥ p」的输入测归约。
MODP_CASES = [
    (
        "all_ff",
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
    ),
    ("p", P256_P),
    ("p_plus_1", P256_P + 1),
    ("p_plus_x", P256_P + 0x123456789ABCDEF),
    ("two_255", 1 << 255),  # 2^255 < p，原样返回
]


def main() -> None:
    pmk = pbkdf2(PASSPHRASE, SSID, 4096, 32)
    ptk48 = wpa2_ptk(pmk, 48)
    ptk64 = wpa2_ptk(pmk, 64)

    msg2 = eapol_key_frame(0x010A, 1, SNONCE, RSN_IE, bytes(16))
    mic = eapol_mic(ptk48[:16], msg2)
    msg2_signed = msg2[:81] + mic + msg2[97:]

    seed1 = sae_pwd_seed(1)
    seed2 = sae_pwd_seed(2)
    value1 = sae_pwd_value(seed1)
    sae = sae_derive(SAE_K)

    print("# ---- PBKDF2-HMAC-SHA1（RFC 6070 §2 复算）----")
    for name, p, s, c, n in RFC6070:
        print(f"rfc6070[{name}] rounds={c} dk_len={n} -> {hx(pbkdf2(p, s, c, n))}")

    print("\n# ---- WPA2-PSK（802.11i Annex H.4：passphrase/SSID -> PMK）----")
    print(f"pmk = {hx(pmk)}")

    print(f"\n# ---- PTK（PRF，label={PTK_LABEL.decode()!r}）----")
    print(f"ptk48 = {hx(ptk48)}")
    print(f"ptk64 = {hx(ptk64)}")
    print(f"kck16 = {hx(ptk48[:16])}")

    print("\n# ---- EAPOL-Key msg2（key_info=0x010a replay=1）----")
    print(f"eapol_frame_len = {len(msg2)}")
    print(f"eapol_msg2     = {hx(msg2_signed)}")
    print(f"mic            = {hx(mic)}")

    print("\n# ---- SAE（固定输入，见脚本顶部常量）----")
    print(f"pwd_seed_1 = {hx(seed1)}")
    print(f"pwd_seed_2 = {hx(seed2)}")
    print(f"pwd_value_1 = {hx(value1)}  (< prime: {int.from_bytes(value1,'big') < P256_P})")
    for key in (
        "scalar_sum",
        "keyseed",
        "kck",
        "pmk",
        "pmkid",
        "confirm_own",
        "confirm_peer",
    ):
        print(f"{key:12s} = {hx(sae[key])}")

    print("\n# ---- P-256 基域归约（输入 >= p 才真正走到减法）----")
    for name, x in MODP_CASES:
        print(f"modp[{name}] in={x:064x} out={x % P256_P:064x}")

    # 标量加法溢出 256 位的用例：a + b = 2^256，carry 进第 257 位。
    # 这是 reduceWide 唯一会「从 r[0] 借位」的路径。
    all_ff = b"\xff" * 32
    one = b"\x00" * 31 + b"\x01"
    print("\n# ---- F_q 加法的溢出用例（sum = 2^256）----")
    print(f"scalar_add[all_ff+1] = {hx(mod_q_add(all_ff, one))}")
    print(f"scalar_add[sum]      = {(2**256 % P256_Q):064x}")

    if "--zig" in sys.argv:
        print("\n// ---- Zig 常量 ----")
        print(f"// pmk  = {hx(pmk)}")
        print(f"// ptk64 = {hx(ptk64)}")
        print(f"// mic  = {hx(mic)}")


if __name__ == "__main__":
    main()
