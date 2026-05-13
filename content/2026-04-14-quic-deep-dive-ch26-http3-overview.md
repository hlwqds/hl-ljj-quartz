# Chapter 26: HTTP/3 Overview

## 26.1 HTTP/3: HTTP on QUIC

HTTP/3 is the third major version of the Hypertext Transfer Protocol, designed to run over QUIC instead of TCP. RFC 9114 defines HTTP/3, completing the standardization effort that began when Google proposed QUIC in 2012.

```
HTTP/3 Stack:
+-------------------+
|      HTTP/3       |  <- RFC 9114
+-------------------+
|       QUIC        |  <- RFC 9000
+-------------------+
|       UDP         |
+-------------------+
|      IP Layer     |
+-------------------+
```

HTTP/3 preserves the core HTTP semantics -- request/response model, methods, headers, status codes -- while replacing the transport layer from TCP to QUIC. The benefits flow directly from QUIC's properties:

- **0-RTT or 1-RTT connection establishment** (vs. 2-3 RTTs for TCP+TLS)
- **Head-of-line blocking elimination** at the transport layer
- **Connection migration** for mobile networks
- **Stream multiplexing** without TCP's head-of-line blocking

## 26.2 HTTP/3 Design Goals

HTTP/3 was designed around three key principles:

### 26.2.1 Parity with HTTP/2 Semantics

HTTP/3 must support the same features as HTTP/2: stream multiplexing, header compression, server push, flow control, and pipelining. The protocol mechanisms differ, but the visible behavior to applications should be equivalent.

### 26.2.2 QUIC-Optimized Mechanisms

Where HTTP/2 mechanisms don't map well to QUIC, HTTP/3 adopts better-suited approaches. For example, HTTP/2 uses stream IDs for multiplexing; HTTP/3 uses QUIC's native streams directly.

### 26.2.3 Minimizing Protocol Overhead

Every HTTP message should minimize bytes on the wire. HTTP/3 uses QPACK header compression (Chapter 27) to reduce header size, and leverages QUIC stream multiplexing to avoid framing overhead.

## 26.3 HTTP/3 Connection Establishment

### 26.3.1 Address Discovery

Before establishing an HTTP/3 connection, the client must discover that the server supports HTTP/3. This uses the **Alt-Svc** mechanism:

```
Client → Server (TCP/HTTP):
  Alt-Svc: h3=":443"

Client infers: server supports HTTP/3 on port 443
```

The `Alt-Svc` response header announces that HTTP/3 is available at a specific host/port. The client caches this information for future connections.

### 26.3.2 QUIC Handshake First

HTTP/3 connection establishment begins with the QUIC handshake:

```
Client → Server:
  Initial packet (with TLS ClientHello)
  QUIC: crypto frames, transport parameters

Server → Client:
  Initial packet (with TLS ServerHello)
  Handshake packet (with TLS certificates)
  Handshake packet (with Finished)

Client → Server:
  Handshake packet (with Finished verification)
  0-RTT data (if resumption ticket available)
```

After the QUIC handshake completes, both endpoints have:

- Agreed on cryptographic keys
- Validated each other's addresses
- Exchanged transport parameters

### 26.3.3 HTTP/3 SETTINGS Frame

Once QUIC handshake completes, the client sends an HTTP/3 SETTINGS frame:

```
Client → Server:
  STREAM Frame (Stream 0, Control Stream):
    SETTINGS {
      MAX_FIELD_SECTION_SIZE = 16384
      QPACK_MAX_TABLE_CAPACITY = 0
      QPACK_BLOCKED_STREAMS = 0
    }

Server → Client:
  STREAM Frame (Stream 0, Control Stream):
    SETTINGS {
      MAX_FIELD_SECTION_SIZE = 16384
      QPACK_MAX_TABLE_CAPACITY = 60
      QPACK_BLOCKED_STREAMS = 100
    }
```

Stream 0 is the **control stream** -- a bidirectional stream used for protocol control messages. The client sends SETTINGS immediately after connecting; the server responds with its own SETTINGS. Both endpoints MUST send SETTINGS before using any other stream.

## 26.4 HTTP/3 Stream Usage

QUIC provides independent, bidirectional streams. HTTP/3 assigns specific meaning to certain streams:

| Stream Type     | Stream ID                          | Use                      |
| --------------- | ---------------------------------- | ------------------------ |
| Control Stream  | 0 (client-initiated bidirectional) | SETTINGS, GOAWAY         |
| Push Streams    | Server-initiated odd IDs           | Server push (Chapter 29) |
| Request Streams | Client-initiated even IDs          | HTTP requests/responses  |
| Reserved        | Certain ID ranges                  | Protocol extensibility   |

### 26.4.1 Request Stream Flow

A complete HTTP request/response uses two streams:

```
Client → Server (Stream N, client-initiated even):
  HEADERS frame (request headers)
  Optionally: STREAM frame (body data)
  FIN flag (end of request)

Server → Client (Stream M, server-initiated):
  HEADERS frame (response headers)
  Optionally: STREAM frame (response body)
  FIN flag (end of response)
```

Each request/response pair uses a pair of streams: the client writes request headers on its own initiated stream, and the server responds on its own initiated stream. This is different from HTTP/2, where responses returned on the same stream as the request.

### 26.4.2 WebTransport Streams

HTTP/3 also supports WebTransport (RFC 9298), a protocol building on HTTP/3 that provides bidirectional transport with unreliable, unordered delivery. WebTransport uses regular QUIC streams beyond the reserved stream IDs.

## 26.5 HTTP/3 vs HTTP/2 Connection Lifecycle

```
HTTP/2 Connection:
  TCP connection established
  TLS handshake
  HTTP/2 SETTINGS exchanged
  Request 1 on Stream 1
  Request 2 on Stream 2
  Response 1 on Stream 1
  Response 2 on Stream 2
  [Streams multiplexed on single TCP connection]

HTTP/3 Connection:
  QUIC connection established
  HTTP/3 SETTINGS exchanged
  Request 1 on Stream A
  Request 2 on Stream B
  Response 1 on Stream C
  Response 2 on Stream D
  [Streams multiplexed via QUIC, no TCP head-of-line blocking]
```

## 26.6 HTTP/3 Error Handling

### 26.6.1 Stream Errors

Stream errors are handled at the QUIC layer:

- Stream receiving `STOP_SENDING`: no more data will be accepted
- Stream receiving `RESET_STREAM`: stream cancelled entirely
- Stream error codes defined in the HTTP/3 specification

### 26.6.2 Application Protocol Errors

HTTP/3 defines error codes for application-level failures:

```
H3_NO_ERROR            = 0x0100  // Clean closure
H3_GENERAL_PROTOCOL_ERROR = 0x0101
H3_INTERNAL_ERROR      = 0x0102  // Implementation bug
H3_STREAM_CREATION_ERROR = 0x0103
H3_CLOSED_CRITICAL_STREAM = 0x0104
H3_FRAME_UNEXPECTED    = 0x0105
H3_FRAME_ERROR         = 0x0106
H3_EXCESSIVE_LOAD      = 0x0107
H3_ID_ERROR            = 0x0108  // Stream ID misuse
H3_SETTINGS_ERROR      = 0x0109
H3_MISSING_SETTINGS    = 0x010a  // SETTINGS not received
H3_REQUEST_REJECTED    = 0x010b
H3_REQUEST_CANCELLED   = 0x010c
H3_REQUEST_INCOMPLETE   = 0x010d
H3_MESSAGE_ERROR       = 0x010e
H3_TRANSPORT_ERRORS     = 0x01XX  // QUIC error codes
```

### 26.6.3 GOAWAY Frame

Like HTTP/2, HTTP/3 supports the GOAWAY frame for graceful connection shutdown:

```
GOAWAY Frame {
  Type = 0x07,
  Stream ID (64 bits),
  Application Error Code (32 bits),
}
```

The GOAWAY frame tells the peer to stop creating new streams. In-flight streams complete normally. This enables server administrators to drain connections gracefully.

## 26.7 HTTP/3 Extension Points

HTTP/3 can be extended via:

### 26.7.1 Extended Frame Types

Additional frame types can be registered via the IANA registry. Extensions should define their own frame type and semantics, similar to how WebTransport defines additional frame types.

### 26.7.2 SETTINGS Extension

New SETTINGS parameters can be defined to negotiate capabilities. Unrecognized SETTINGS MUST be ignored by implementations (forward compatibility).

### 26.7.3 WebTransport

WebTransport (RFC 9298) runs atop HTTP/3 and provides:

- Bidirectional streams
- Datagrams (unordered, unreliable message delivery)
- Session termination signaling

## 26.8 HTTP/3 Limitations

HTTP/3 is not universally beneficial:

### 26.8.1 QUIC Connection Establishment Overhead

For very short-lived connections where QUIC handshake overhead exceeds the time saved by eliminating head-of-line blocking, HTTP/3 may be slower than HTTP/2.

### 26.8.2 Middlebox Interference

Some firewalls and NAT devices process UDP poorly or block it entirely. HTTP/3 cannot be used in environments where UDP is filtered.

### 26.8.3 CPU overhead

QUIC encryption is more CPU-intensive than TCP+TLS 1.3 because QUIC performs encryption per-packet (not per-connection) and manages its own retry logic. Server CPU usage may be higher.

## 26.9 Summary

HTTP/3 is HTTP semantics running over QUIC transport. Key characteristics:

- QUIC handshake provides 0-RTT or 1-RTT connection establishment
- Stream 0 carries the control stream for SETTINGS/GOAWAY
- Request/response uses bidirectional stream pairs
- Head-of-line blocking eliminated at transport layer
- Error handling via QUIC stream mechanisms and HTTP/3 error codes
- GOAWAY enables graceful shutdown

The next chapter covers QPACK, HTTP/3's header compression mechanism.
