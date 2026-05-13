# Chapter 28: HTTP Frames in QUIC

## 28.1 Framing in HTTP/3

HTTP/3 maps its framing layer onto QUIC streams. Unlike HTTP/2, which defines its own length-prefixed frame format, HTTP/3 relies on QUIC stream semantics for framing:

```
HTTP/2 Frame:
  +-----------------------------------------------+
  | Length (24 bits) | Type (8) | Flags (8)      |
  +-----------------------------------------------+
  |              Stream ID (31 bits)             |
  +-----------------------------------------------+
  |              Frame Payload (variable)         |
  +-----------------------------------------------+

HTTP/3 Frame:
  +-----------------------------------------------+
  |              QUIC STREAM Frame                |
  |   (Type encoded in first byte of payload)   |
  +-----------------------------------------------+
```

The QUIC layer provides:
- Stream identification (which stream the frame belongs to)
- Length delimitation (QUIC STREAM frame includes length)
- Delivery ordering within a stream (QUIC delivers stream data in order)

HTTP/3 only needs to define the frame *types* and their payload formats.

## 28.2 HTTP/3 Frame Types

RFC 9114 defines the following frame types:

| Frame Type | Value | Use |
|---|---|---|
| DATA | 0x00 | Request/response body |
| HEADERS | 0x01 | Compressed header block |
| CANCEL_PUSH | 0x03 | Cancel server push |
| SETTINGS | 0x04 | Connection configuration |
| PUSH_PROMISE | 0x05 | Server push initiation |
| GOAWAY | 0x07 | Graceful connection close |
| MAX_PUSH_ID | 0x0D | Limit push streams |
| DUPLICATE_PUSH | 0x0E | Duplicate a push promise |
| RESERVED | 0x09, 0x0F | (formerly HEADERS, keep-alive) |

### 28.2.1 Frame Type Registry

Additional frame types can be registered via IANA. Unknown frame types MUST be ignored (forward compatibility).

## 28.3 DATA Frame

The DATA frame carries HTTP message body data.

```
DATA Frame {
  Type = 0x00,
  Length (varint),
  Data (Length bytes),
}
```

```
Example:
  Client → Server (request body):
    STREAM Frame (Stream N):
      DATA { Length = 1024, Data = "..." }

    STREAM Frame (Stream N):
      DATA { Length = 512, Data = "..." }

    STREAM Frame (Stream N) + FIN:
      DATA { Length = 256, Data = "..." }
```

DATA frames MUST NOT appear on the control stream (Stream 0).

## 28.4 HEADERS Frame

The HEADERS frame carries a QPACK-encoded header block.

```
HEADERS Frame {
  Type = 0x01,
  Length (varint),
  Header Block (Length bytes, QPACK encoded),
}
```

```
Example:
  Client → Server (request headers):
    STREAM Frame (Stream N):
      HEADERS {
        Length = 64,
        Header Block = QPACK(:method: GET, :path: /api/users, ...)
      }

    STREAM Frame (Stream N) + FIN:
      HEADERS { Length = 0 }  // Empty header block means "end of headers"
```

The HEADERS frame contains the QPACK-encoded header list. Multiple HEADERS frames may be sent for a single request if the header block is large, but typically one frame suffices.

### 28.4.1 Request Header Sequence

A complete HTTP request consists of:

```
Client → Server:
  HEADERS frame (request headers, QPACK encoded)
  DATA frames (optional request body)
  STREAM FIN (end of request)

Server → Client:
  HEADERS frame (response headers, QPACK encoded)
  DATA frames (optional response body)
  STREAM FIN (end of response)
```

## 28.5 SETTINGS Frame

The SETTINGS frame conveys connection configuration. Both endpoints MUST send SETTINGS; the client sends immediately after the QUIC handshake, and the server sends after receiving the client's SETTINGS.

```
SETTINGS Frame {
  Type = 0x04,
  Length (varint),
  Setting (Length/6 bytes each) [
    Identifier (varint),
    Value (varint),
  ]...
}
```

### 28.5.1 SETTINGS Parameters

Defined SETTINGS parameters:

| Setting | ID | Default | Description |
|---|---|---|---|
| SETTINGS_MAX_FIELD_SECTION_SIZE | 0x06 | 16384 | Max header section size |
| SETTINGS_QPACK_MAX_TABLE_CAPACITY | 0x03 | 0 | Dynamic table capacity |
| SETTINGS_QPACK_BLOCKED_STREAMS | 0x07 | 0 | Max blocked streams |
| SETTINGS_ENABLE_H3_DATAGRAM | 0x33 | 0 | Enable HTTP Datagram |
| (reserved) | 0x09 | | Formerly MAX_FRAME_SIZE |

```
Example:
  Client → Server:
    SETTINGS {
      SETTINGS_MAX_FIELD_SECTION_SIZE = 65535
      SETTINGS_QPACK_MAX_TABLE_CAPACITY = 4096
    }
```

### 28.5.2 SETTINGS Rules

- SETTINGS MUST NOT contain duplicate identifiers
- Unknown settings MUST be ignored
- SETTINGS can only be sent on Stream 0 (control stream)
- SETTINGS must be sent as the first frame on Stream 0
- After sending SETTINGS, endpoints MUST validate: `1/2 * MAX_FIELD_SECTION_SIZE >= 16384` or reject

### 28.5.3 SETTINGS ACK

HTTP/3 uses QUIC's `ACK` mechanism (QUIC-level) to acknowledge SETTINGS frames. There's no application-level SETTINGS ACK frame.

## 28.6 PUSH_PROMISE Frame

The PUSH_PROMISE frame initiates server push (Chapter 29). It can only appear on server-initiated bidirectional streams.

```
PUSH_PROMISE Frame {
  Type = 0x05,
  Push ID (varint),
  Length (varint),
  Header Block (QPACK encoded),
}
```

```
Server → Client:
  PUSH_PROMISE {
    Push ID = 3,
    Header Block = QPACK(:method: GET, :path: /style.css, ...)
  }
```

## 28.7 CANCEL_PUSH Frame

The client uses CANCEL_PUSH to indicate it no longer needs a pushed resource (e.g., because the client already has it cached).

```
CANCEL_PUSH Frame {
  Type = 0x03,
  Push ID (varint),
}
```

```
Client → Server:
  CANCEL_PUSH { Push ID = 3 }
```

The server receives CANCEL_PUSH and MUST stop sending data for that push ID if it hasn't already completed.

## 28.8 GOAWAY Frame

GOAWAY initiates graceful connection shutdown.

```
GOAWAY Frame {
  Type = 0x07,
  Length (varint) = 12,
  Stream ID (64 bits),
  Application Error Code (32 bits),
}
```

```
Server → Client:
  GOAWAY {
    Stream ID = 0xFFFFFFFFFFFFFFFF,  // No specific stream
    Error Code = H3_NO_ERROR (0x0100)
  }

  "Client: stop creating new streams, I'll finish processing existing ones"
```

### 28.8.1 GOAWAY Semantics

GOAWAY means: "I received your request but may not have fully processed it. Stop sending more requests."

- Streams with ID < GOAWAY Stream ID: safely processed
- Streams with ID >= GOAWAY Stream ID: possibly not processed
- The peer should stop creating new streams with ID >= GOAWAY Stream ID

## 28.9 MAX_PUSH_ID Frame

The client sends MAX_PUSH_ID to limit how many push streams the server can open.

```
MAX_PUSH_ID Frame {
  Type = 0x0D,
  Max Push ID (varint),
}
```

```
Client → Server:
  MAX_PUSH_ID { Max Push ID = 5 }

Server:
  Can only open push streams with Push ID 0-5
```

This gives the client control over server push resource commitment.

## 28.10 DUPLICATE_PUSH Frame

The server can duplicate a previous push promise with a new Push ID:

```
DUPLICATE_PUSH Frame {
  Type = 0x0E,
  Stream ID (varint),
  Push ID (varint),
}
```

```
Server → Client:
  DUPLICATE_PUSH {
    Stream ID = 5,    // Same request headers as push stream 5
    Push ID = 10      // But with new Push ID
  }
```

This reuses the same promised response for a different request context.

## 28.11 WebTransport Frames

HTTP/3 also supports WebTransport (RFC 9298), which defines additional frame types:

| Frame Type | Value | Use |
|---|---|---|
| WT_DATA | 0x00 | WebTransport data |
| WT_HEADERS | 0x01 | WebTransport headers |
| WT_ACKNOWLEDGE | 0x02 | WebTransport ACK |
| WT_CLOSE | 0x03 | WebTransport session close |

## 28.12 Frame Ordering Rules

HTTP/3 has strict rules about frame ordering:

### 28.12.1 Control Stream Frames

On Stream 0 (control stream), frames MUST appear in this order:

```
1. SETTINGS (client's SETTINGS, must be first)
2. SETTINGS (server's SETTINGS)
3. Other control frames (GOAWAY, etc.)
```

### 28.12.2 Request/Response Frames

On request streams, frames can appear in any order (except:

```
Request:
  HEADERS must appear before any DATA
  HEADERS may be split across multiple frames

Response:
  HEADERS must appear before any DATA
  Response body may be interleaved with PUSH_PROMISE on server push streams
```

### 28.12.3 Stream Final Bytes

The end of a logical HTTP message is signaled by the QUIC STREAM FIN, not by a special frame type. A zero-length HEADERS frame can be sent to indicate "end of headers."

## 28.13 Frame Validation

Each endpoint validates frames received:

### 28.13.1 Frame Type Validation

```
On wrong stream type:
  - SETTINGS on non-control stream -> H3_FRAME_UNEXPECTED
  - PUSH_PROMISE on client-initiated stream -> H3_FRAME_UNEXPECTED

On unexpected frame type:
  - Ignore (forward compatibility)
```

### 28.13.2 Frame Size Validation

```
If frame exceeds MAX_FIELD_SECTION_SIZE:
  - H3_EXCESSIVE_LOAD error
  - Connection closed

If frame is malformed:
  - H3_FRAME_ERROR
  - Stream reset
```

### 28.13.3 Stream Dependency Validation

```
If frame references non-existent stream:
  - H3_STREAM_CREATION_ERROR

If GOAWAY Stream ID is invalid:
  - H3_ID_ERROR
```

## 28.14 Frame Size Limits

HTTP/3 uses variable-length integers (varint) for all length fields:

```
Varint encoding:
  1 byte:   0-127
  2 bytes:  128-16383
  4 bytes:  16384-1073741823
  8 bytes:  1073741824-4611686018427387903
```

The SETTINGS_MAX_FIELD_SECTION_SIZE limits the uncompressed header section size, not the compressed frame size.

## 28.15 Frame Processing Rules

### 28.15.1 Unknown Frames

Unknown frame types MUST be ignored:

```
Decoder receives frame type 0xFF:
  - Skip frame (using length field)
  - Continue processing next frame
  - No error signaled
```

This enables extension frames without breaking backward compatibility.

### 28.15.2 Duplicate Frames

Duplicate frames on the same stream are processed twice (unless semantics say otherwise):

```
Server receives two identical HEADERS:
  - Process first HEADERS
  - Error on second HEADERS (duplicate request headers)
```

Some frames (like SETTINGS) explicitly allow duplicates; others don't.

### 28.15.3 Frame Interleaving

Multiple frame types can interleave on the same stream:

```
Server → Client (one response stream):
  HEADERS frame (response headers)
  DATA frame (first chunk of body)
  PUSH_PROMISE frame (promising related resource)
  DATA frame (second chunk of body)
  DATA frame + FIN (end of body)
```

## 28.16 Stream Cancellation

HTTP requests can be cancelled. The mechanism differs from HTTP/2:

### 28.16.1 Client-Initiated Cancellation

```
Client → Server:
  STREAM Frame with RESET_STREAM (at QUIC layer)
```

The QUIC `RESET_STREAM` frame indicates the client is abandoning the request. The error code can indicate whether the cancellation was intentional (user pressed stop) or due to error.

### 28.16.2 Server-Initiated Cancellation

```
Server → Client:
  STREAM Frame with STOP_SENDING (at QUIC layer)
```

The QUIC `STOP_SENDING` frame tells the client to stop sending request data. The server may have already sent a partial response.

## 28.17 Flow Control and Frames

HTTP/3 flow control operates at two levels:

### 28.17.1 QUIC Stream Flow Control

Each stream has its own flow control window (default: 1MB in most implementations). DATA frames must respect the window.

```
Stream receive window: 1MB
Received DATA: 500KB
Remaining: 500KB

Sender can send up to 500KB more on this stream
```

### 28.17.2 Connection Flow Control

The total bytes received on all streams is bounded by the connection flow control window.

```
Connection receive window: 10MB
Sum of all stream bytes received: 6MB
Remaining: 4MB

Clients collectively can only send 4MB more
```

## 28.18 Frame Size Recommendations

For efficient transmission:

```
Single-frame requests: HEADERS fits in one STREAM frame
Large bodies: Split DATA across multiple STREAM frames
Compressed bodies: Consider content-encoding (gzip, brotli)
```

HTTP/3 frames don't have built-in padding. Use QUIC's `PADDING` frame if needed for probing path MTU.

## 28.19 Summary

HTTP/3 frames are carried on QUIC streams:

| Frame | Purpose | Stream |
|---|---|---|
| DATA | Message body | Request/response |
| HEADERS | QPACK-encoded headers | Request/response |
| SETTINGS | Connection configuration | Stream 0 |
| PUSH_PROMISE | Server push initiation | Server push |
| CANCEL_PUSH | Cancel server push | Request |
| GOAWAY | Graceful shutdown | Stream 0 |
| MAX_PUSH_ID | Limit push streams | Request |
| DUPLICATE_PUSH | Duplicate push promise | Request/response |

Key differences from HTTP/2:
- No explicit length-prefixed framing (relies on QUIC STREAM)
- SETTINGS is first frame on Stream 0
- HEADERS no longer carries stream dependency info (not needed with QUIC streams)
- WebTransport frames integrated into HTTP/3 frame space

The next chapter covers server push in HTTP/3, including how PUSH_PROMISE and related frames coordinate push delivery.