# Chapter 16: Stream Multiplexing Architecture

## 16.1 The Head-of-Line Blocking Problem

TCP provides a single ordered byte stream between two endpoints. This sounds simple, but it creates a fundamental problem: **head-of-line blocking (HOL blocking)**. If segment #50 is lost in transit, TCP cannot deliver any data past segment #50 to the application -- even if that data belongs to a completely unrelated part of your application.

Consider a web browser fetching a page with images, CSS, and JavaScript. If a TCP segment carrying part of the CSS is lost, the entire HTTP/2 connection stalls. The images and JavaScript, which are already received and waiting in the kernel buffer, cannot be delivered to the application until the CSS segment is retransmitted and received.

```
TCP HOL Blocking:
Stream:  [A][A][A][LOST][A][A][A][A][A]  <- blocked waiting for retransmit
         ↓   ↓   ↓    ↓    ↓   ↓   ↓   ↓   ↓
App receives: A A A                          <- nothing else until LOST arrives
```

HTTP/1.1 tried to work around this by opening 6-8 parallel TCP connections. Each connection got its own independent HOL blocking domain. But this created new problems: connection setup overhead, TCP congestion competition between connections, and server-side resource fragmentation.

HTTP/2 improved this by multiplexing multiple HTTP "streams" onto a single TCP connection. But HTTP/2 still suffers from TCP HOL blocking at the transport layer. A lost TCP segment delays ALL HTTP/2 streams, regardless of their independence.

## 16.2 QUIC's Solution: Independent Stream Delivery

QUIC moves stream multiplexing to the transport layer, below HTTP. Each QUIC stream is an independent ordered byte channel. When a packet is lost, only the stream that packet belongs to pauses -- all other streams continue normally.

```
QUIC Stream Multiplexing:
Stream 1:  [B][B][B][LOST][B][B][B][B][B]  <- stream 1 blocked
Stream 2:  [C][C][C][C][C][C][C][C][C][C]  <- stream 2 continues
Stream 3:  [D][D][D][D][D][D][D][D][D][D]  <- stream 3 continues

App receives from stream 1: B B B
App receives from stream 2: C C C C C C C C C C
App receives from stream 3: D D D D D D D D D D
```

This is possible because QUIC implements its own reliability mechanism per-stream, rather than relying on TCP's connection-level reliability.

## 16.3 Stream Anatomy

A QUIC stream is identified by a **Stream ID** (a variable-length integer). The stream ID uniquely identifies which logical channel data belongs to.

### 16.3.1 Stream ID Encoding

Stream IDs are odd or even, client or server initiated:

```
Stream ID format:
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Stream Type  |0|                 Stream Number                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Stream Type (2 bits):
  00 - Client-initiated, bidirectional
  01 - Server-initiated, bidirectional
  10 - Client-initiated, unidirectional
  11 - Server-initiated, unidirectional
```

| Stream Type | Stream ID (binary) | Description |
|---|---|---|
| Client bidirectional | `0x00` | 0, 4, 8, 12, ... |
| Server bidirectional | `0x01` | 1, 5, 9, 13, ... |
| Client unidirectional | `0x02` | 2, 6, 10, 14, ... |
| Server unidirectional | `0x03` | 3, 7, 11, 15, ... |

The stream number increments by 1 for each new stream of the same type. Stream 0 is always the first client-initiated bidirectional stream (used for HTTP/3 control).

### 16.3.2 Stream Data Ordering

Each stream delivers bytes in order. The **Stream Offset** field in STREAM frames specifies where the data begins within the stream. This allows QUIC to:

1. Detect missing data (holes in the offset sequence)
2. Reassemble stream data correctly even if frames arrive out of order
3. Identify duplicate data

```
STREAM Frame {
  Type           = 0x08..0x0f,
  Stream ID      (i),
  Offset         (i),
  [Length        (i)],
  Stream Data    (...)
}
```

The combination of `Stream ID + Offset + Length` uniquely identifies any chunk of stream data.

## 16.4 How Streams Share the Connection

QUIC multiplexes streams onto a single UDP datagram. Multiple STREAM frames from different streams can appear in the same QUIC packet. This is fundamentally different from HTTP/2, where HEADERS and DATA frames were interleaved within a single TCP connection's bytestream.

```
UDP Datagram containing QUIC Packet:
+------------------------------------------+
| QUIC Header (with DCID)                  |
+------------------------------------------+
| STREAM Frame (Stream 1, offset 0-999)    |
+------------------------------------------+
| STREAM Frame (Stream 3, offset 0-499)    |
+------------------------------------------+
| STREAM Frame (Stream 1, offset 1000-1999)|
+------------------------------------------+
| CRYPTO Frame (Handshake data)            |
+------------------------------------------+
```

Key insight: QUIC's reliability is per-STREAM, not per-packet. A lost packet containing STREAM frames for Stream 1 does not block Stream 2, even if both streams' frames were in the same UDP datagram.

## 16.5 Stream vs. Connection: Shared Resources

While streams are independent for ordering and reliability purposes, they share the connection's resources:

### 16.5.1 Shared Congestion Control

All streams on a connection share the same congestion window. If one stream floods the connection, it affects all other streams. This is intentional -- it prevents a single application from monopolizing the network path.

```
Connection congestion window: 100 packets
Stream 1 sends:     40 packets
Stream 2 sends:     35 packets
Stream 3 sends:     25 packets
Total:              100 packets (window full)
```

### 16.5.2 Shared Connection-Level Flow Control

While each stream has its own send/receive flow control, the sum of all stream data is bounded by connection-level flow control. Chapter 18 covers this in detail.

### 16.5.3 Shared Packet Number Space for Retransmission

QUIC uses a single packet number space for the entire connection (after the Initial phase). Lost packets are retransmitted with new packet numbers, and the offset system allows the receiver to deduplicate.

```
Original packet #10: STREAM frame (Stream 1, offset 1000-1099)
Retransmitted as packet #15: Same STREAM frame data

Receiver: "I already have offset 1000-1099 for Stream 1, discard duplicate"
```

## 16.6 Maximum Streams

QUIC doesn't allow unlimited streams. The `MAX_STREAMS` frame advertises how many streams of each type the peer can open:

```
MAX_STREAMS Frame {
  Type              = 0x12 or 0x13,
  Maximum Streams   (i)
}
```

- Type `0x12`: Maximum bidirectional streams
- Type `0x13`: Maximum unidirectional streams

If a peer attempts to open more streams than allowed, the remote peer sends a `STREAMS_BLOCKED` frame (0x14 or 0x15) indicating it cannot open more streams at this time.

## 16.7 Stream Priority (HTTP/3 Relationship)

QUIC itself does not define stream priority. This is intentionally left to the application layer (HTTP/3). HTTP/3 uses the `WEBTRANSPORT` and QPACK header compression to handle prioritization separately from the transport layer.

The rationale: different applications have different priority needs. A video streaming app might prioritize the current segment over the next; a file download might treat all chunks equally. Putting priority in QUIC would either limit applications or require complex priority signaling that QUIC doesn't need for its core function.

## 16.8 Comparison: QUIC Streams vs. HTTP/2 Streams

| Aspect | HTTP/2 Streams | QUIC Streams |
|---|---|---|
| HOL blocking | TCP-level (all streams) | None (transport-level per-stream) |
| Delivery guarantee | Ordered byte stream | Ordered byte stream per stream |
| Loss handling | TCP retransmit stalls all | Per-stream retransmit |
| Flow control | Connection + stream level | Connection + stream level |
| Priority | Defined in protocol | Delegated to application |
| Frame types | HEADERS, DATA, etc. | STREAM frame (data only) |

## 16.9 Summary

QUIC's stream multiplexing is its most impactful feature for performance. By implementing reliability at the stream level rather than connection level, QUIC eliminates head-of-line blocking across streams. Each stream:

- Has an independent ordered byte delivery channel
- Carries its own Stream ID and Offset for reassembly
- Is independently flow-controlled
- Can suffer packet loss without affecting other streams

Streams share the connection's congestion controller and packet number space, ensuring fair resource usage while maintaining independence for ordering and reliability. This architecture enables HTTP/3 to multiplex multiple HTTP transactions over a single QUIC connection without the HOL blocking penalties that plagued HTTP/2 over TCP.