# Chapter 17: Stream States and Lifecycle

## 17.1 Two Sides of Every Stream

Every QUIC stream has two independent halves: the **send side** (where the application writes data) and the **receive side** (where the application reads data). For bidirectional streams, both sides exist. For unidirectional streams, one side is unused.

This is a critical distinction: a stream's send side and receive side have independent state machines. A stream can be in a more advanced state on one side than the other.

## 17.2 Send Stream State Machine

The send side tracks what data has been sent, acknowledged, or is pending retransmission:

```
                    1
    ┌───────────────▼───────────────┐
    │           OPEN                │
    │  Data written, not all sent   │
    └───────────────┬───────────────┘
                    │
          ┌─────────┴─────────┐
          │                   │
          ▼                   ▼
    ┌───────────┐       ┌───────────┐
    │  SEND     │       │  SEND     │
    │  (Ready)  │       │  (Data    │
    │  Stream   │       │   Pending)│
    │  Has data │       │           │
    └─────┬─────┘       └─────┬─────┘
          │                   │
          │                   └────────────────┐
          │                                        │
          ▼                                        ▼
    ┌─────────────────────────────────┐      ┌───────────┐
    │         Data Sent               │      │   DATA    │
    │  All data sent, awaiting ACK    │      │  RECVD    │
    └─────────────┬───────────────────┘      └───────────┘
                  │
                  ▼
    ┌─────────────────────────────────┐
    │       DATA ACKed (Ready)        │
    │  All data acknowledged          │
    └─────────────────────────────────┘
```

### 17.2.1 Send States Explained

| State | Description |
|---|---|
| **OPEN** | Initial state. Application has data to send but flow control may prevent transmission. |
| **SEND (Ready)** | Stream has data ready to send. The send-side is ready to send but waiting for flow control credit or transmission opportunity. |
| **SEND (Data Pending)** | Data has been written to the stream and is queued for transmission. |
| **Data Sent** | All stream data has been transmitted (in STREAM frames) but not all has been acknowledged. |
| **Data Recvd** | All data has been transmitted and at least some is acknowledged. |
| **DATA ACKed** | All stream data has been fully acknowledged by the peer. Terminal state for send side. |

### 17.2.2 State Transitions

1. **OPEN → SEND (Ready)**: Application writes data to the stream. If the stream was previously empty, it transitions to ready state.

2. **SEND (Ready) → SEND (Data Pending)**: Data is transmitted in a STREAM frame. The offset and length are recorded for retransmission tracking.

3. **SEND (Data Pending) → Data Sent**: The packet containing the STREAM frame is transmitted.

4. **Data Sent → Data Recvd**: An ACK is received indicating at least some of the data was acknowledged.

5. **Data Recvd → DATA ACKed**: ACK is received for all data. Terminal state.

6. **Any state → Reset**: Application abandons the stream via `STREAM_RESET` frame, or a connection error occurs. This terminates the send side.

## 17.3 Receive Stream State Machine

The receive side tracks what data has been received, delivered to the application, and what gaps exist:

```
              │
              ▼
    ┌─────────────────────┐
    │      RECV           │
    │  Receiving data     │
    └──────────┬──────────┘
               │
               ▼
    ┌─────────────────────┐
    │   RECV DATA RECVD   │
    │  All data received  │
    │  (no gaps)          │
    └──────────┬──────────┘
               │
               ▼
    ┌─────────────────────┐
    │      DATA READ       │
    │  All data delivered │
    │  to application     │
    └─────────────────────┘
```

### 17.3.1 Receive States Explained

| State | Description |
|---|---|
| **RECV** | Initial state. Receiving STREAM frames, buffering out-of-order data. |
| **RECV DATA RECVD** | All expected data has been received (no gaps in offset sequence). |
| **DATA READ** | All received data has been delivered to the application. Terminal state for receive side. |

### 17.3.2 Receive-Side Gap Handling

Because QUIC can deliver STREAM frames out of order (due to packet loss and retransmission), the receive side must handle gaps:

```
Received frames:
  Stream 5, offset 0-999:  ✓ (received)
  Stream 5, offset 1000-1099: ✓ (received)
  Stream 5, offset 2000-2099: ✗ (gap! offset 1200-1999 missing)

State: RECV (waiting for offset 1200-1999)
```

When a gap is detected, the receive side:
1. Buffers received data (in memory or disk)
2. Waits for retransmission of missing data
3. Does NOT deliver any data past the gap to the application

## 17.4 Stream-Level Reset

Streams can be aborted before all data is sent or received. The `STREAM_RESET` frame (0x04 for receive reset, 0x05 for both directions) signals this:

```
STREAM_RESET Frame {
  Type           = 0x04 or 0x05,
  Stream ID      (i),
  Application Error Code (i),
  Final Offset   (i)
}
```

### 17.4.1 Why Reset?

- Application no longer needs the data (e.g., user cancelled a request)
- Error condition that makes remaining data meaningless
- Stream ID space needs to be reclaimed

### 17.4.2 Final Offset

The `Final Offset` field is critical: it tells the receiver how much data the sender will actually send. This prevents the receiver from waiting indefinitely for data that will never arrive.

```
Sender writes 1000 bytes, then resets with Final Offset = 500

Receiver:
  - Already received offsets 0-499: deliver to app
  - Waiting for offsets 500-999: DON'T wait, stream is done
  - Any frames arriving for offset >= 500: discard as malformed
```

## 17.5 Opening and Closing Streams

### 17.5.1 Opening a Stream

Streams are implicitly opened when the first STREAM frame for that Stream ID is sent or received. There is no explicit OPEN frame -- streams are bidirectionally created by usage.

```
Client wants to open Stream 4:
  - Write to Stream 4 → STREAM frame sent with Stream ID 4
  - Stream 4 now exists

Server receives STREAM frame with Stream ID 4:
  - Creates receive side for Stream 4
  - Stream 4 now exists bidirectionally
```

### 17.5.2 Closing a Stream

Streams close when both sides have delivered all data and acknowledged completion. There is no explicit CLOSE frame for streams -- they close by mutual acknowledgment:

1. Sender writes all data, sends STREAM frame with FIN flag
2. Receiver gets FIN, delivers all data, sends ACK
3. Sender receives ACK for data+FIN
4. Stream is semantically closed

```
Sender Side:                              Receiver Side:
  Write all data                           Receive data frames
  Send STREAM (FIN)                        Deliver to app
  Receive ACK (data+FIN)                   Send ACK
  Stream closed                            Stream closed
```

## 17.6 STOP_SENDING Frame

The `STOP_SENDING` frame (0x05) is sent by the receive side when it wants to tell the sender to stop transmitting on a stream:

```
STOP_SENDING Frame {
  Type           = 0x05,
  Stream ID      (i),
  Application Protocol Error Code (i)
}
```

Use cases:
- Application received enough data and doesn't need the rest
- Application encountered an error processing stream data
- Stream is not needed but the sender hasn't reset it

This is different from `STREAM_RESET` -- `STOP_SENDING` tells the sender to stop sending, while `STREAM_RESET` resets the stream entirely.

## 17.7 Stream ID Allocation and Limits

QUIC limits the number of concurrent streams. The `MAX_STREAMS` frame advertises how many streams the peer can open:

```
Client sends MAX_STREAMS (bidirectional):
  Maximum Streams: 100

Server can now have up to 100 open bidirectional streams
```

### 17.7.1 Per-Type Limits

Limits are per stream type:
- Client-initiated bidirectional (0, 4, 8, ...)
- Server-initiated bidirectional (1, 5, 9, ...)
- Client-initiated unidirectional (2, 6, 10, ...)
- Server-initiated unidirectional (3, 7, 11, ...)

Each type has its own limit. You could have 100 bidirectional streams but only 10 unidirectional streams.

## 17.8 Stream Priority and Scheduling

QUIC leaves stream priority to the application layer (HTTP/3). However, the send side must decide which stream's data to send when multiple streams have pending data.

### 17.8.1 Scheduling Strategies

Common implementations:
- **Round-robin**: Fair sharing across streams
- **Priority-based**: Some streams get more bandwidth
- **Head-of-line**: Single stream gets all until blocked

Most implementations use a variant of **deficit round-robin (DRR)** or similar fair-queuing algorithm to balance throughput fairness with priority.

### 17.8.2 Frame Selection

When building a packet, the sender may include frames from multiple streams. The packet number space is shared, but each stream's data is independent. Implementations typically:
1. Fill packets with STREAM frames from ready streams
2. Include CRYPTO frames first (handshake progress)
3. Include ACK frames when needed
4. Include PING/PADDING as needed for PMTU/probing

## 17.9 Stream Limits in HTTP/3

In HTTP/3, stream 0 is reserved for HTTP control messages (QPACK encoded headers). The remaining streams (4, 8, 12, ...) carry HTTP request/response bodies.

HTTP/3 imposes additional semantics:
- Server can close streams 0-3 (reserved) → CONNECTION_CLOSE
- Clients cannot open more than the advertised `MAX_STREAMS`
- Servers can send `STREAM_STOPPING` errors

## 17.10 Stream States Summary

| Send State | Description |
|---|---|
| OPEN | Initial state, application can write |
| SEND Ready | Has data, waiting for transmission opportunity |
| SEND Data Pending | Data queued, waiting for packet transmission |
| Data Sent | All data transmitted, awaiting ACK |
| Data Recvd | Some data acknowledged |
| DATA ACKed | All data acknowledged (terminal) |

| Receive State | Description |
|---|---|
| RECV | Receiving and buffering data |
| RECV DATA RECVD | All data received (gap-free) |
| DATA READ | All data delivered to application (terminal) |

Stream resets (`STREAM_RESET`) and stop-sending (`STOP_SENDING`) provide asymmetric stream termination when the application no longer needs the stream's data.

## 17.11 Summary

QUIC streams have independent send and receive side state machines. The send side tracks data through writing, transmission, acknowledgment, and completion. The receive side tracks data through reception, gap detection, in-order delivery, and consumption.

Streams are implicitly opened and closed through usage rather than explicit signaling. Reset frames (`STREAM_RESET`, `STOP_SENDING`) provide asymmetric termination when needed.

The per-stream reliability in QUIC means that a stream's packet loss only affects that stream -- no cross-stream HOL blocking. Combined with connection-level congestion and flow control (Chapter 18), QUIC provides fine-grained resource management while maintaining independent stream semantics.