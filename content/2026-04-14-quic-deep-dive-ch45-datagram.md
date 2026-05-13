# Chapter 45: QUIC Datagram Extension

## 45.1 Motivation: When You Don't Want Streams

QUIC's core design centers on reliable, ordered stream delivery. But many real-world applications don't need this guarantee:

- **DNS queries**: Fire and forget, fast retries
- **VoIP/Real-time communication**: Late data is worthless
- **Gaming**: State updates that quickly become stale
- **IoT sensor data**: Occasional readings where loss is acceptable

The QUIC Datagram Extension (RFC 9221) adds support for unreliable, unreferenced datagram delivery within an established QUIC connection. This gives you the best of both worlds: QUIC's encryption, congestion control, and connection setup combined with UDP-like semantics.

## 45.2 How Datagrams Fit Into QUIC

In QUIC, everything is a frame inside a packet. Datagrams are no exception:

```
QUIC Packet (UDP payload)
+--------------------------------------------------+
|  QUIC Header                                     |
|  +--------------------------------------------+  |
|  | Frame Type: DATAGRAM (0x30)                |  |
|  +--------------------------------------------+  |
|  | Datagram Payload (opaque bytes)            |  |
|  +--------------------------------------------+  |
+--------------------------------------------------+
```

The `DATAGRAM` frame carries opaque application data with no ordering or reliability guarantees.

## 45.3 DATAGRAM Frame Format

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Type (0x30)  |              Datagram ID (optional)           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Payload (*)                            ...
+---------------------------------------------------------------+
```

- **Type**: `0x30` for datagrams with length, `0x31` without length
- **Datagram ID**: Optional 0-3 byte identifier for demultiplexing
- **Payload**: Variable length opaque data

## 45.4 Flow Control and Datagrams

Here's the tricky part: QUIC's connection-level and stream-level flow control doesn't apply to datagrams. Instead, datagrams have their own flow control mechanism:

```
+----------------------------------------------------------+
|                    QUIC Connection                        |
|                                                          |
|  +------------------+    +----------------------------+  |
|  | Stream 1         |    | DATAGRAM flow             |  |
|  | Flow Control:    |    | Congestion Controlled     |  |
|  | credit-based     |    | via connection CC         |  |
|  +------------------+    +----------------------------+  |
|                                                          |
|  +------------------+                                    |
|  | Stream 2         |    +----------------------------+  |
|  | Flow Control:    |    | DATAGRAM flow              |  |
|  | credit-based     |    | No per-datagram ACKs       |  |
|  +------------------+    | (unless acknowledged)       |  |
|                          +----------------------------+  |
+----------------------------------------------------------+
```

Datagrams are subject to:
1. **Connection-level congestion control** - They share the congestion window with streams
2. **Application-level flow control** - via the `DATAGRAM_GIVE_CRE` frame (if supported)

## 45.5 Acknowledgment Semantics

Unlike streams, datagrams are **not** individually acknowledged by default. This is intentional -- acknowledging every datagram would create overhead.

However, senders can request acknowledgment:

```c
// Pseudocode: sending a datagram with ACK request
quic_frame_t frame;
frame.type = 0x30;  // DATAGRAM with length
frame.datagram_id = 42;
frame.payload = "Hello";
frame.ack_requested = true;

send_quic_frame(connection, frame);
```

When the receiver acknowledges the containing QUIC packet, the sender learns the datagram **was received** (not that it was processed by the application).

## 45.6 The DATAGRAM_GIVE_CRE Frame

For applications that need application-level flow control, RFC 9221 defines `DATAGRAM_GIVE_CRE`:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Type (0x33)  |          Maximum Datagram Payload Size      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

This tells the peer the maximum datagram size you're willing to receive.

## 45.7 Use Case: DNS over QUIC

DNS is the canonical use case for QUIC datagrams:

```
Client                                          Server
   |                                               |
   |---[Initial Packet: CRYPTO + STREAM]--------->|  // Connection setup
   |<--[Reply Packet: CRYPTO + STREAM]------------|  // Connection established
   |                                               |
   |---[DATAGRAM: DNS Query]--------------------->|  // Fast, no ACK needed
   |---[DATAGRAM: DNS Query]--------------------->|  // Retry if no response
   |<--[DATAGRAM: DNS Response]-------------------|  // Response
   |                                               |
```

Benefits:
- **0-RTT potential** on repeat queries
- **Better encryption** than classic DNS over UDP
- **No head-of-line blocking** with other DNS queries
- **Connection migration** works seamlessly

## 45.8 Interaction with Connection Migration

When a connection migrates (see Chapter 19), datagrams continue to work transparently. The QUIC stack simply re-routes them to the new address/connection tuple.

However, datagrams in flight during migration may be lost, since they were sent to the old path.

## 45.9 Implementation Considerations

### Sending Side
- Buffer datagrams for retransmission only if reliability is needed
- Track datagrams in flight for congestion control
- Apply per-packet pacing

### Receiving Side
- Deliver datagrams immediately to the application (no reordering)
- Handle datagrams that arrive after connection migration
- Apply congestion control feedback via `ACK` frames

### Application Layer
- Don't assume delivery (design for loss)
- Size datagrams to fit in a single QUIC packet (MTU considerations)
- Use datagram IDs for correlation if needed

## 45.10 Summary

RFC 9221's QUIC Datagram extension provides unreliable, unordered message delivery within QUIC's encrypted, congestion-controlled connection framework:

- Use `DATAGRAM` frames (0x30/0x31) for unreliable delivery
- Datagrams share congestion control but not stream flow control
- No per-datagram ACKs by default
- Perfect for DNS, VoIP, gaming, and IoT
- Connection migration works seamlessly with datagrams

Datagrams complement QUIC streams rather than replacing them. The protocol choice depends on your application's needs: streams for reliable, ordered delivery; datagrams for low-latency, loss-tolerant communication.
