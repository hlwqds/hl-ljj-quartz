# Chapter 3: Wire Format

## 3.1 QUIC Packets and UDP Datagrams

A QUIC connection runs inside UDP datagrams. Each QUIC packet is carried as the payload of a UDP datagram. This has a practical implication: the Maximum Transmission Unit (MTU) for QUIC is bounded by the UDP maximum (~65507 bytes for IPv4) minus IP/UDP headers (typically 40 bytes for IPv6), leaving roughly 64KB of payload space per datagram.

In practice, implementations use a maximum QUIC packet size of around 1200-1500 bytes to avoid fragmentation at the IP layer.

```
UDP Datagram:
  +------------------------------------------+
  | IP Header (20-40 bytes)                  |
  +------------------------------------------+
  | UDP Header (8 bytes)                     |
  +------------------------------------------+
  | QUIC Packet                              |
  |  +------------------------------------+  |
  |  | QUIC Header                        |  |
  |  +------------------------------------+  |
  |  | QUIC Frames (one or more)          |  |
  |  +------------------------------------+  |
  +------------------------------------------+
```

## 3.2 Packet Types: Long Header vs. Short Header

QUIC defines two packet types based on the first byte's high bits:

| First Byte (binary) | Packet Type | Used During |
|---|---|---|
| `00` | Initial | Connection establishment |
| `01` | 0-RTT | Early data (after initial) |
| `10` | Handshake | Post-handshake messages |
| `11` | Short Header | 1-RTT data transfer |

The first byte is also the Connection ID Length (first 2 bits) in long header packets, and version-specific flags in short header packets.

### Long Header Packets (Version Negotiation, Initial, Handshake, 0-RTT)

Long header packets share a common prefix:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Header Form    |   Version      |      Connection ID Length |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Connection ID (0..160 bits)               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Packet Number Length                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Token Length                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             Token                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Length                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Packet Number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Frames...                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Fields:**
- **Header Form** (1 bit): `1` = long header
- **Version** (32 bits): QUIC protocol version (e.g., `0x00000001` for v1)
- **DCID Len** (8 bits): Length of Destination Connection ID
- **SCID Len** (8 bits): Length of Source Connection ID
- **Connection IDs**: Variable-length, up to 160 bits (20 bytes) each
- **Packet Number Length** (2 bits): `00`=1 byte, `01`=2 bytes, `10`=3 bytes, `11`=4 bytes
- **Token Length** (variable-length integer): Present in Initial and 0-RTT packets
- **Token**: Opaque blob from server for future connections
- **Length** (variable-length integer): Present in long header packets; byte length of remainder of packet after Length field
- **Packet Number** (1-4 bytes): Actual packet number
- **Frames**: One or more frames

### Short Header Packet

Used for 1-RTT data. Only the destination Connection ID is included (since the client knows the server's CID):

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Header Form    |   Reserved    |   Packet Number Length     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Destination Connection ID                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Packet Number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Frames...                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Fields:**
- **Header Form** (1 bit): `0` = short header
- **Reserved** (2 bits): Must be zero (checked by receiver)
- **Packet Number Length** (2 bits): Same encoding as long header
- **DCID**: Variable-length Destination Connection ID
- **Packet Number**: 1-4 bytes
- **Frames**: Encrypted payload

### 3.3 Variable-Length Integers

QUIC uses a variable-length integer encoding for most numeric fields to reduce overhead:

| Prefix (2 bits) | Bytes Used | Range |
|---|---|---|
| `00` | 1 byte | 0 to 63 |
| `01` | 2 bytes | 0 to 16383 |
| `10` | 4 bytes | 0 to 2^31 - 1 |
| `11` | 8 bytes | 0 to 2^63 - 1 |

The first two bits encode the length, the remaining bits encode the value:

```
1-byte:  0xxxxxxx                           (7 bits of value)
2-byte:  01xxxxxx xxxxxxxx                  (14 bits of value)
4-byte:  10xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx (30 bits of value)
8-byte:  11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx ... (62 bits of value)
```

## 3.4 Frame Types

Frames are the unit of QUIC's protocol semantics. Each frame carries a specific protocol element. Frames are stacked inside QUIC packets.

### STREAM Frame

Carries application data on a stream:

```
STREAM Frame {
  Type (i = 0x08..0x0f),
  Stream ID (i),
  Off (i),
  Len (i),
  [Data]
}
```

The frame type byte `0x08` to `0x0f` encodes 4 boolean flags: `F`, `S`, `I`, `O` (off, len, and two others), allowing optimization for common cases like "offset 0, known length" or "continuation with known offset and length").

### ACK Frame

Reports which packets were received and which are still missing. ACKs are the foundation of QUIC's loss detection:

```
ACK Frame {
  Type (i = 0x1a..0x1b),
  Largest Acknowledged (i),
  ACK Delay (i),
  ACK Range Count (i),
  First ACK Range (i),
  ACK Range (..),
  ECN Counts (..)
}
```

The `ACK_MAYBE_DUPLICATE` frame type (0x1b) signals that the peer may have sent duplicate packets.

### CRYPTO Frame

Carries TLS handshake data. Unlike STREAM, CRYPTO frames are not flow-controlled per-stream -- they use connection-level flow control:

```
CRYPTO Frame {
  Type (i = 0x18),
  Offset (i),
  Length (i),
  Crypto Data (..)
}
```

### PING / PADDING Frames

- `PING` (0x01): Forces an ACK (used for keepalive / path MTU probing)
- `PADDING` (0x00): Expands a packet to meet minimum size requirements or conceal the true payload size

### CONNECTION_CLOSE Frame

Gracefully terminates a connection:

```
CONNECTION_CLOSE Frame {
  Type (i = 0x1c or 0x1d),
  Error Code (i),
  Frame Type (i),    // which frame type triggered close (application only)
  Reason Phrase (..)
}
```

### NEW_CONNECTION_ID / RETIRE_CONNECTION_ID

Manage Connection IDs (Chapter 5 covers these in detail):

```
NEW_CONNECTION_ID Frame {
  Type (i = 0x18),
  Sequence Number (i),
  Retire Prior To (i),
  Connection ID Length (i),
  Connection ID (...),
  Stateless Reset Token (128 bits)
}

RETIRE_CONNECTION_ID Frame {
  Type (i = 0x19),
  Sequence Number (i)
}
```

### PATH_CHALLENGE / PATH_RESPONSE

Used for connection migration path validation:

```
PATH_CHALLENGE Frame {
  Type (i = 0x1e),
  Data (64 bits)
}

PATH_RESPONSE Frame {
  Type (i = 0x1f),
  Data (64 bits)
}
```

### NEW_TOKEN Frame

Server provides a token to the client for use in future Initial packets:

```
NEW_TOKEN Frame {
  Type (i = 0x07),
  Token Length (i),
  Token (...)
}
```

### DATAGRAM Frame (RFC 9221)

For unreliable, unreliable-ordered delivery outside the stream abstraction:

```
DATAGRAM Frame {
  Type (i = 0x30..0x31),
  [Length (i)],
  Datagram Data (..)
}
```

## 3.5 Packet Number Space and Encryption

QUIC uses different keys for different packet types to prevent key compromise of one phase from affecting another:

```
Initial packets      → Initial secrets (derived from Destination CID)
Handshake packets    → Handshake keys (derived from TLS handshake secrets)
0-RTT packets        → 0-RTT keys (derived from early_data secret)
1-RTT (short header) → 1-RTT keys (derived from handshake secret)
```

This is called **packet protection key hierarchy**. Each phase gets fresh keys, and compromise of, say, 0-RTT keys cannot be used to decrypt 1-RTT traffic.

## 3.6 Sample Packet Hex Dump

A short header 1-RTT packet might look like:

```
0x06                           # Header form=0, reserved=0, pn_len=01 (2 bytes)
0xf0 0x5a 0x3b 0x2a 0x4c 0x8d  # Destination Connection ID (6 bytes)
0x1a 0x2b                      # Packet number (2 bytes, because pn_len=01)
0x12 0x34 0x56 0x78 ...        # Encrypted payload (AEAD output)
```

## 3.7 Summary

QUIC's wire format is designed for extensibility (variable-length integers, unknown frame tolerance), encryption (short header packets hide almost everything), and efficiency (packet number length encoding, stream-optimized STREAM frames). The long header / short header distinction maps directly to the two phases of a QUIC connection: establishment (long headers, multiple packet types) and data transfer (short headers, single packet type).
