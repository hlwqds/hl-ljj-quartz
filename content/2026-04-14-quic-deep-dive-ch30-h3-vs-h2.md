# Chapter 30: HTTP/2 vs HTTP/3 Comparison

## 30.1 Overview

HTTP/2 (RFC 7540) and HTTP/3 (RFC 9114) are both designed to improve web performance over their predecessors. They share the same core semantics but differ significantly in their transport layers.

```
HTTP/1.1:  Plaintext, single request per connection
HTTP/2:   Binary framing, multiplexed streams over TCP+TLS
HTTP/3:   Binary framing, multiplexed streams over QUIC
```

This chapter compares HTTP/2 and HTTP/3 across multiple dimensions.

## 30.2 Connection Establishment

### 30.2.1 HTTP/2 Connection

HTTP/2 requires TCP + TLS handshakes before sending data:

```
TCP Handshake:
  SYN →          (RTT 1)
  ← SYN+ACK      (RTT 1)
  ACK →          (RTT 1)

TLS Handshake:
  ClientHello →
  ← ServerHello, Certificate, ...
  ClientKeyExchange, Finished →
  ← Finished

Total: 2-3 RTTs before HTTP/2 data
```

### 30.2.2 HTTP/3 Connection

HTTP/3 uses QUIC's combined handshake:

```
QUIC Handshake (combines transport + crypto):
  ClientHello →
  ← ServerHello, Certificate, Finished

Total: 1 RTT before HTTP/3 data (0-RTT if resumption available)
```

### 30.2.3 Comparison

| Metric | HTTP/2 | HTTP/3 |
|---|---|---|
| Connection establishment | 2-3 RTTs | 1 RTT (0-RTT with 0-RTT) |
| TLS version | TLS 1.2+ | TLS 1.3+ (bundled) |
| Handshake separation | TCP and TLS separate | QUIC combines transport+crypto |
| 0-RTT support | TLS 1.3 only | QUIC 0-RTT |

## 30.3 Multiplexing Architecture

### 30.3.1 HTTP/2 Multiplexing

HTTP/2 multiplexes multiple streams over a single TCP connection:

```
TCP Connection:
  Stream 1: HEADERS + DATA (request A)
  Stream 2: HEADERS + DATA (request B)
  Stream 3: HEADERS + DATA (request C)

Problem:
  Packet loss on Stream 2 →
  TCP retransmits packet →
  All streams blocked until retransmit arrives
  (Head-of-line blocking at TCP layer)
```

HTTP/2's head-of-line blocking problem:
- TCP delivers bytes in order
- A lost packet delays all subsequent packets
- All HTTP/2 streams stall waiting for retransmit

### 30.3.2 HTTP/3 Multiplexing

HTTP/3 runs streams over QUIC, which handles each stream independently:

```
QUIC Connection:
  Stream 1: Stream A data
  Stream 2: Stream B data
  Stream 3: Stream C data

Packet loss:
  Packet containing Stream B data lost →
  Stream B stalls (waits for QUIC retransmit)
  Streams A and C continue uninterrupted
  No head-of-line blocking across streams
```

QUIC's stream abstraction means packet loss only affects the stream that lost data, not other streams.

### 30.3.3 Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Transport | TCP | QUIC (over UDP) |
| Stream separation | HTTP/2 streams | QUIC streams |
| Cross-stream loss impact | All streams blocked | Only affected stream blocked |
| Head-of-line blocking | Yes (TCP layer) | No |
| Stream ordering | Per-stream, ordered | Per-stream, ordered |
| Flow control | Stream + connection | Stream + connection |

## 30.4 Stream Dependencies

### 30.4.1 HTTP/2 Stream Dependencies

HTTP/2 defines a priority tree using stream dependencies:

```
Stream 1 (root)
  ├── Stream 2 (dependent on 1)
  │   ├── Stream 5 (dependent on 2)
  │   └── Stream 6 (dependent on 2)
  └── Stream 3 (dependent on 1)
      └── Stream 4 (dependent on 3)
```

The PRIORITY frame (later repurposed as HEADERS flags) configures this tree.

### 30.4.2 HTTP/3 Stream Dependencies

HTTP/3 deliberately omits HTTP-level stream dependencies:

> "HTTP/3 does not define a mechanism for prioritizing one stream over another." -- RFC 9114

Rationale:
- QUIC provides connection-level flow control
- Transport-level prioritization is implementation-specific
- HTTP-level prioritization adds complexity with marginal gains

HTTP/3 relies on QUIC implementations to handle prioritization fairly across streams.

### 30.4.3 Dependency Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Stream dependencies | Yes (priority tree) | No |
| Exclusive dependencies | Yes | No |
| Weighted priority | Yes | No |
| Dynamic reprioritization | Yes (PRIORITY frame) | No |
| Recommendation | Implement priorities | Implementation-defined |

## 30.5 Header Compression

### 30.5.1 HTTP/2: HPACK

HPACK assumes ordered, reliable delivery:

```
HPACK works because:
  - TCP delivers bytes in order
  - Reference indices are stable
  - No need to track "acknowledged" entries
```

HPACK state is local to each direction; the encoder tracks what the decoder has received.

### 30.5.2 HTTP/3: QPACK

QPACK adapts HPACK for out-of-order delivery:

```
QPACK requires:
  - Dynamic table entries acknowledged before referencing
  - QPACK control stream for table synchronization
  - Blocked stream handling (STREAM_BLOCKED frames)
```

### 30.5.3 Compression Comparison

| Aspect | HPACK (HTTP/2) | QPACK (HTTP/3) |
|---|---|---|
| Delivery assumption | Ordered (TCP) | Unordered (QUIC) |
| Control channel | None (same stream) | Dedicated QPACK stream |
| Blocking | Implicit wait | Explicit via Required Insert Count |
| Encoder tracking | Insert count | Insert count + unacked entries |
| Memory bounds | Max table size | Max table size + capacity |
| Baseline efficiency | ~75% compression | Similar (~70-80%) |

## 30.6 Flow Control

### 30.6.1 HTTP/2 Flow Control

HTTP/2 implements stream-level and connection-level flow control:

```
SETTINGS frame:
  SETTINGS_MAX_CONCURRENT_STREAMS = 100

WINDOW_UPDATE frame:
  - Increments stream window
  - Increments connection window

Flow control is hop-by-hop (not end-to-end proxies)
```

### 30.6.2 HTTP/3 Flow Control

HTTP/3 flow control is similar but uses different frames:

```
SETTINGS_QPACK_MAX_TABLE_CAPACITY: Dynamic table memory
SETTINGS_MAX_FIELD_SECTION_SIZE: Header size limit

Flow control via QUIC:
  STREAM frames respect stream window
  Connection flow control limits total bytes
```

### 30.6.3 Flow Control Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Stream window | WINDOW_UPDATE | QUIC flow control |
| Connection window | WINDOW_UPDATE | QUIC flow control |
| Initial window | 65535 bytes | 1MB (typical) |
| Header table memory | SETTINGS_HEADER_TABLE_SIZE | SETTINGS_QPACK_MAX_TABLE_CAPACITY |
| Field section limit | N/A | SETTINGS_MAX_FIELD_SECTION_SIZE |
| Hop-by-hop | Yes | No (QUIC is end-to-end) |

## 30.7 Server Push

### 30.7.1 HTTP/2 Server Push

HTTP/2 uses PUSH_PROMISE on the same stream as the request:

```
Client → Server: GET /index.html (Stream 1)
Server → Client: HEADERS (Stream 1, response)
Server → Client: PUSH_PROMISE (Stream 1, promised request)
Server → Client: DATA (Stream 2, pushed response)
```

### 30.7.2 HTTP/3 Server Push

HTTP/3 uses server-initiated bidirectional streams:

```
Client → Server: GET /index.html
Server → Client: PUSH_PROMISE (on any stream)
Server → Client: HEADERS + DATA (on push stream, server-initiated)
```

### 30.7.3 Server Push Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Push announcement | PUSH_PROMISE (same stream) | PUSH_PROMISE (any stream) |
| Push response stream | Same stream as promise | Server-initiated stream |
| Client cancellation | N/A | CANCEL_PUSH frame |
| Push ID limit | None | MAX_PUSH_ID frame |
| Dependency tracking | Stream dependencies | None |

## 30.8 Framing Format

### 30.8.1 HTTP/2 Frame Format

HTTP/2 defines its own length-prefixed frames:

```
HTTP/2 Frame:
  +-----------------------------------------------+
  | Length (24 bits) | Type (8) | Flags (8)      |
  +-----------------------------------------------+
  |              Stream ID (31 bits)             |
  +-----------------------------------------------+
  |              Frame Payload                    |
  +-----------------------------------------------+
```

### 30.8.2 HTTP/3 Frame Format

HTTP/3 relies on QUIC's stream framing:

```
HTTP/3 Frame:
  +-----------------------------------------------+
  | QUIC STREAM Frame                            |
  |   Type (varint, first byte)                  |
  |   Length (varint)                            |
  |   Payload                                    |
  +-----------------------------------------------+
```

HTTP/3 doesn't need its own length prefix because QUIC STREAM frames include length.

### 30.8.3 Framing Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Self-describing frames | Yes (length prefix) | No (relies on QUIC) |
| Frame type field | 8 bits | varint |
| Stream identification | Frame field | QUIC stream ID |
| Stream association | Frame-based | Stream-based |
| Padding support | PADDING frame | QUIC PADDING frame |

## 30.9 Connection Management

### 30.9.1 HTTP/2 Connection Management

TCP connection is the unit of management:
- All streams on one TCP connection
- Network change = connection break
- Connection coalescing possible (same IP/port)

### 30.9.2 HTTP/3 Connection Management

QUIC connection is the unit of management:
- All streams on one QUIC connection
- Network change = connection migration (no break)
- Connection ID enables migration

### 30.9.3 Connection Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Connection identifier | None (4-tuple) | Connection ID |
| Network change | Connection breaks | Connection migrates |
| Connection reuse | Limited (IP:port) | Multiple CIDs |
| Port reuse | Yes | Yes (via Alt-Svc) |
| 0-RTT data | TLS 1.3 resumption | QUIC 0-RTT |

## 30.10 Error Handling

### 30.10.1 HTTP/2 Error Handling

HTTP/2 uses error codes in RST_STREAM and GOAWAY:

```
Error codes:
  0x0 - NO_ERROR
  0x1 - PROTOCOL_ERROR
  0x2 - INTERNAL_ERROR
  0x3 - FLOW_CONTROL_ERROR
  0x4 - SETTINGS_TIMEOUT
  0x5 - STREAM_CLOSED
  0x6 - FRAME_SIZE_ERROR
  0x7 - REFUSED_STREAM
  0x8 - CANCEL
  0x9 - COMPRESSION_ERROR
  0xa - CONNECT_ERROR
  0xb - ENHANCE_YOUR_CALM
  0xc - INADEQUATE_SECURITY
  0xd - HTTP_1_1_REQUIRED
```

### 30.10.2 HTTP/3 Error Handling

HTTP/3 has distinct error spaces:

```
HTTP/3 error codes (0x0100-0x01ff):
  0x0100 - H3_NO_ERROR
  0x0101 - H3_GENERAL_PROTOCOL_ERROR
  0x0102 - H3_INTERNAL_ERROR
  0x0103 - H3_STREAM_CREATION_ERROR
  0x0104 - H3_CLOSED_CRITICAL_STREAM
  0x0105 - H3_FRAME_UNEXPECTED
  0x0106 - H3_FRAME_ERROR
  0x0107 - H3_EXCESSIVE_LOAD
  0x0108 - H3_ID_ERROR
  0x0109 - H3_SETTINGS_ERROR
  ...

QUIC error codes (different space):
  Transport errors, crypto errors
```

### 30.10.3 Error Handling Comparison

| Feature | HTTP/2 | HTTP/3 |
|---|---|---|
| Error code space | Single (stream + connection) | Separate HTTP + QUIC |
| Stream errors | RST_STREAM | QUIC RST_STREAM |
| Connection errors | GOAWAY | QUIC CONNECTION_CLOSE |
| Unknown error handling | Undefined | Ignore (forward compat) |
| Framing errors | FRAME_SIZE_ERROR | H3_FRAME_ERROR |

## 30.11 Middlebox Compatibility

### 30.11.1 HTTP/2 Middlebox Behavior

HTTP/2 uses ALPN negotiation over TLS:
```
TLS Extension: ALPN = "h2"
```

HTTP/2 typically passes through middleboxes because:
- Port 443 (HTTPS) is open
- TLS inspection can see HTTP/2 frames
- TCP is universally understood

### 30.11.2 HTTP/3 Middlebox Behavior

HTTP/3 may face UDP filtering:
```
Problem:
  - Some firewalls block UDP port 443
  - Some NATs don't handle QUIC correctly
  - TLS 1.3 Encrypted Client Hello may obscure detection
```

HTTP/3 discovery via Alt-Svc:
```
Client first tries HTTP/2 over TCP:443
Server responds: Alt-Svc: h3=":443"
Client switches to QUIC:443 (HTTP/3)
```

### 30.11.3 Middlebox Comparison

| Factor | HTTP/2 | HTTP/3 |
|---|---|---|
| Transport | TCP (widely supported) | UDP (may be filtered) |
| Firewall traversal | Excellent | Variable |
| NAT compatibility | Excellent | May have issues |
| Connection establishment | Predictable | Variable |
| Fallback | N/A (TCP always works) | Can fall back to HTTP/2 |

## 30.12 Performance Characteristics

### 30.12.1 Latency

```
HTTP/2:
  - 2-3 RTTs for new connection
  - Single RTT for cached connection (TLS resumption)

HTTP/3:
  - 1 RTT for new connection
  - 0 RTT for cached connection (0-RTT data)
```

HTTP/3 has a latency advantage, especially for 0-RTT resumption.

### 30.12.2 Loss Resilience

```
HTTP/2:
  Loss on any stream blocks all streams
  Tail loss probe affects all streams

HTTP/3:
  Loss blocks only the affected stream
  Other streams continue
```

HTTP/3 is more resilient to packet loss, especially on lossy networks (mobile, WiFi with interference).

### 30.12.3 Throughput

```
HTTP/2:
  - BBR/CUBIC at TCP layer
  - Good throughput when connection is stable
  - Throughput drops on network change

HTTP/3:
  - BBR/CUBIC at QUIC layer
  - Similar throughput when stable
  - Better on unstable paths due to loss isolation
```

## 30.13 Implementation Complexity

### 30.13.1 HTTP/2 Implementation

HTTP/2 over TCP is relatively straightforward:
- OS provides TCP (kernel)
- TLS library handles crypto
- Application implements HTTP/2 framing

```
HTTP/2 stack:
  App → HPACK → HTTP/2 framing → TLS → TCP → IP
```

### 30.13.2 HTTP/3 Implementation

HTTP/3 requires a userspace QUIC implementation:
- No OS kernel support for QUIC (yet)
- Full transport layer in application
- More code = more bugs potential

```
HTTP/3 stack:
  App → QPACK → HTTP/3 framing → QUIC → UDP → IP
```

### 30.13.3 Complexity Comparison

| Component | HTTP/2 | HTTP/3 |
|---|---|---|
| Transport | TCP (kernel) | QUIC (userspace) |
| Encryption | TLS (library) | QUIC crypto (integrated) |
| Head-of-line blocking | Kernel TCP | Userspace QUIC |
| Connection migration | App doesn't handle | App must handle |
| CPU overhead | Lower | Higher (per-packet crypto) |

## 30.14 Feature Comparison Summary

| Feature | HTTP/2 | HTTP/3 | Winner |
|---|---|---|---|
| Connection establishment latency | 2-3 RTT | 1 RTT (0-RTT) | HTTP/3 |
| Head-of-line blocking | Yes (TCP) | No | HTTP/3 |
| Connection migration | No | Yes | HTTP/3 |
| Loss resilience | Poor | Good | HTTP/3 |
| Header compression | HPACK | QPACK | Tie |
| Stream priorities | Yes | No | HTTP/2 |
| Server push | Yes | Yes (enhanced) | Tie |
| Middlebox compatibility | Excellent | Variable | HTTP/2 |
| Implementation complexity | Lower | Higher | HTTP/2 |
| QUIC 0-RTT | N/A | Yes | HTTP/3 |
| Flow control | WINDOW_UPDATE | QUIC | HTTP/3 |

## 30.15 When to Use HTTP/3

HTTP/3 is beneficial when:
- Mobile clients on lossy networks
- Applications benefit from connection migration
- 0-RTT resumption is valuable (return visits)
- Multiple streams compete for bandwidth

HTTP/2 may be preferred when:
- UDP is blocked/filtered in the network
- CPU constraints (QUIC is more CPU-intensive)
- Server push with complex dependencies is needed
- Maximum compatibility is required

## 30.16 Protocol Evolution

### 30.16.1 HTTP/2 Extensions

HTTP/2 can be extended via:
- New frame types (registered via IANA)
- New SETTINGS parameters
- New HTTP error codes

### 30.16.2 HTTP/3 Extensions

HTTP/3 extensions similar to HTTP/2:
- WebTransport over HTTP/3
- Extended frame types
- Datagram support (HTTP Datagrams)

### 30.16.3 Future Directions

HTTP/2 and HTTP/3 may eventually converge:
- HTTP/2 over QUIC is theoretically possible
- Alternative transports for HTTP/3 (not just QUIC)
- Unified HTTP semantics across transport layers

## 30.17 Summary

HTTP/2 and HTTP/3 represent two approaches to improving HTTP:

**HTTP/2** built on TCP+TLS to add multiplexed streams, header compression, and server push. Its main weakness is TCP's head-of-line blocking.

**HTTP/3** built on QUIC to eliminate transport-level head-of-line blocking, enable connection migration, and reduce connection establishment latency. Its main weakness is UDP filtering in some networks.

Key takeways:
- HTTP/3 wins on mobile/unreliable networks
- HTTP/2 wins on CPU-constrained servers
- Both support the same HTTP semantics
- HTTP/3 adoption is growing as UDP filtering decreases

The choice between HTTP/2 and HTTP/3 should consider:
- Network conditions (loss rate, middlebox behavior)
- Server capabilities (QUIC implementation quality)
- Client mix (desktop vs mobile)
- Application characteristics (stream competition, return visits)

In practice, supporting both protocols (via Alt-Svc) and letting clients choose provides the best experience.