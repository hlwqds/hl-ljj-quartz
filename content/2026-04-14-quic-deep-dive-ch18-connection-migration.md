# Chapter 18: Flow Control

## 18.1 Why Flow Control?

Flow control prevents a fast sender from overwhelming a slow receiver. Without it, the receiver's buffer would overflow, causing packet loss and retransmission waste.

TCP has flow control (via the receive window), but HTTP/2's stream multiplexing revealed a problem: TCP's receive window is connection-wide. If one HTTP/2 stream receives data faster than the application can consume it, the TCP window fills, blocking ALL HTTP/2 streams -- even streams whose applications are ready to consume data immediately.

QUIC implements **two-level flow control**:

1. **Connection-level flow control**: Total data across all streams
2. **Stream-level flow control**: Data on a specific stream

This ensures that one stream's slow consumer doesn't block other streams.

## 18.2 QUIC Flow Control Mechanism

QUIC uses a **credit-based** flow control system. Both endpoints advertise how much data they're willing to receive:

- **MAX_DATA**: Connection-level flow control limit
- **MAX_STREAM_DATA**: Stream-level flow control limit

```
Endpoint A                              Endpoint B
    |                                       |
    |  ←── MAX_DATA (connection limit) ──  |
    |  ←── MAX_STREAM_DATA (per stream) ──  |
    |                                       |
    |  STREAM frames (up to limits) ──→    |
    |                                       |
```

The sender tracks:

- How much data it has sent on each stream
- How much data the peer has advertised it can receive
- How much connection-level data the peer can receive

## 18.3 Connection-Level Flow Control

### 18.3.1 MAX_DATA Frame

```
MAX_DATA Frame {
  Type           = 0x10,
  Maximum Data   (i)
}
```

The `Maximum Data` value is a cumulative byte offset. It tells the peer: "You can send me up to N bytes total on this connection."

### 18.3.2 How It Works

```
Initial MAX_DATA: 0

Receiver application reads 10KB from OS socket
Receiver sends: MAX_DATA = 10240

Sender can now send up to 10KB total on connection
Sender sends 8KB
Sender has sent 8KB, limit is 10KB, can send 2KB more

Sender sends 2KB
Sender has sent 10KB, limit is 10KB, CANNOT send more
Wait for next MAX_DATA
```

### 18.3.3 Connection Flow Control at a Glance

```
Connection credit tracking:
  LOCAL_MAX_DATA:      10240 bytes (advertised limit)
  DATA_SENT:           0 bytes
  DATA_SENT_AND_ACKED: 0 bytes

Sender operations:
  1. Write 8000 bytes to streams
  2. DATA_SENT = 8000
  3. DATA_SENT (8000) <= LOCAL_MAX_DATA (10240) → allowed
  4. Send STREAM frames

  5. Write 3000 more bytes
  6. DATA_SENT = 11000
  7. DATA_SENT (11000) > LOCAL_MAX_DATA (10240) → blocked
  8. Wait for MAX_DATA update
```

## 18.4 Stream-Level Flow Control

### 18.4.1 MAX_STREAM_DATA Frame

```
MAX_STREAM_DATA Frame {
  Type           = 0x11,
  Stream ID      (i),
  Maximum Stream Data (i)
}
```

Unlike `MAX_DATA`, `MAX_STREAM_DATA` is per-stream. An endpoint sends this when its receive buffer for a specific stream has space.

### 18.4.2 Stream Credit Tracking

```
For each stream, sender tracks:
  STREAM_MAX_DATA:      5000 bytes (advertised by receiver)
  STREAM_DATA_SENT:      0 bytes

  1. Write 3000 bytes to Stream 5
  2. STREAM_DATA_SENT = 3000
  3. 3000 <= 5000 → allowed

  4. Write 3000 more bytes (total 6000)
  5. STREAM_DATA_SENT = 6000
  6. 6000 > 5000 → blocked on this stream
  7. Can still send on other streams
```

## 18.5 Credit-Based vs. Window-Based

QUIC uses credit-based flow control, not sliding window (like TCP). The difference:

| Aspect           | TCP Sliding Window       | QUIC Credit-Based          |
| ---------------- | ------------------------ | -------------------------- |
| Advertisement    | Window size in ACK       | Explicit credit (MAX_DATA) |
| Credits consumed | By sent data             | By sent data               |
| Credits restored | By ACK increasing window | By MAX_DATA frames         |
| Per-stream       | No                       | Yes                        |

Credit-based is more flexible because:

- Credits can be updated independently of data acknowledgment
- The peer can pre-advertise buffer space before it's used
- Stream-level credits are independent

## 18.6 DATA怴 rame Flow Control Interaction

When sending STREAM frames, the sender must respect BOTH limits:

```
To send STREAM frame on Stream N:
  1. Check connection-level credit:
     - DATA_SENT <= MAX_DATA? If no, connection blocked
  2. Check stream-level credit:
     - STREAM_DATA_SENT[N] <= MAX_STREAM_DATA[N]? If no, stream blocked
  3. Both satisfied → send data (up to both limits)
```

This two-level check ensures:

- The connection as a whole doesn't overflow the receiver
- Individual streams can't hog all connection credit

## 18.7 Flow Control During Connection Migration

When a connection migrates (Chapter 19), flow control state carries over:

- The new path starts with whatever credit was last advertised
- The receiver's buffer state is preserved (not tied to 4-tuple)
- This is critical: migration shouldn't cause unexpected flow control blocking

```
Before migration:
  Connection has sent 50KB, MAX_DATA = 100KB
  Stream 3 has sent 20KB, MAX_STREAM_DATA[3] = 30KB

After migration to new IP:
  Same limits apply
  Sender continues from where it left off
```

## 18.8 Flow Control and Loss Recovery

QUIC's per-stream loss tracking interacts with flow control:

```
Scenario:
  - Stream 1 sends data in packet #10, #11, #12
  - Packet #11 (Stream 1 data) is lost
  - Packet #12 contains Stream 2 data

Loss handling:
  - Retransmit Stream 1 data in new packet #15
  - Stream 2 data in packet #12 was already sent
  - Flow control credit for Stream 1 is consumed by retransmit

Key insight:
  Retransmitted data CONSUMES flow control credit again
  This prevents unbounded credit usage through retransmission
```

## 18.9 Flow Control and Retransmission

When data is retransmitted, the offset stays the same but the packet number is new. The receiver must:

1. Recognize the offset (already received)
2. Discard duplicate data
3. Not deliver duplicate data to application

This is correct behavior -- retransmission is for reliability, not for extra credit.

## 18.10 Initial Connection Flow Control

Initial packets (Initial, Handshake) are not flow-controlled by MAX_DATA/MAX_STREAM_DATA. They use connection-level limits only for CRYPTO frames (via the crypto buffer).

However, 1-RTT packets ARE flow-controlled. Before the handshake completes, the client and server have limited crypto data they can exchange.

```
Special crypto flow control:
  - Initial/Handshake CRYPTO frames: not subject to MAX_STREAM_DATA
  - But limited by version-specific crypto buffer sizes
  - Prevents excessive crypto data before encryption is established
```

## 18.11 FLOW_CONTROL Error Handling

If an endpoint receives more data than it advertised in MAX_DATA:

```
FLOW_CONTROL_ERROR:
  - Peer sent more connection data than MAX_DATA allowed
  - Connection must be closed with error code FLOW_CONTROL_ERROR
```

Similarly for stream-level:

```
FLOW_CONTROL_ERROR:
  - Peer sent more data on Stream N than MAX_STREAM_DATA[N] allowed
  - Connection must be closed
```

This is strict enforcement -- you cannot silently ignore flow control violations.

## 18.12 Interaction with Congestion Control

Flow control and congestion control are separate mechanisms:

| Mechanism          | What it controls | Triggered by               |
| ------------------ | ---------------- | -------------------------- |
| Flow control       | Receiver buffer  | Receiver advertised limits |
| Congestion control | Network capacity | Observed packet loss, ECN  |

A sender can be blocked by:

1. **Flow control**: Receiver can't receive more (peer advertised limits)
2. **Congestion control**: Network can't carry more (loss/ECT signals)

Both must allow transmission for data to be sent:

```
Check before sending:
  1. cwnd allows sending? If no → congestion blocked
  2. Connection MAX_DATA allows sending? If no → connection flow control blocked
  3. Stream MAX_STREAM_DATA allows sending? If no → stream flow control blocked
  4. All satisfied → send data
```

## 18.13 Zero-Length STREAM Data and Flow Control

A STREAM frame can have zero-length data (just the FIN). Such frames still consume flow control credit for the FIN offset.

```
STREAM frame with FIN but no data:
  Offset = 1000
  Length = 0
  FIN = 1

This means: "Stream data ends at offset 999, FIN indicates end"
MAX_STREAM_DATA must be >= 1000 to send this frame
```

## 18.14 Flow Control Summary

QUIC's two-level flow control prevents both receiver overflow and individual stream monopolization:

| Frame           | Level      | Purpose                        |
| --------------- | ---------- | ------------------------------ |
| MAX_DATA        | Connection | Total bytes across all streams |
| MAX_STREAM_DATA | Per-stream | Bytes on specific stream       |

Credit-based flow control allows flexible buffer advertising without sliding window constraints. The sender must check both connection-level and stream-level limits before sending.

Flow control state persists across connection migration and interacts with loss recovery through retransmission credit accounting. Violations are fatal errors, ensuring both endpoints strictly respect advertised limits.

## 18.15 Summary

QUIC's flow control is credit-based with two levels: connection-wide (`MAX_DATA`) and per-stream (`MAX_STREAM_DATA`). This design ensures that:

1. A slow consumer on one stream doesn't block other streams
2. The total receive buffer is protected from overflow
3. Credits can be advertised independently of data acknowledgment
4. Flow control state survives connection migration

The strict enforcement (flow control violations cause connection termination) ensures protocol correctness. Combined with congestion control, flow control provides end-to-end backpressure that prevents QUIC from overwhelming either the receiver or the network.
