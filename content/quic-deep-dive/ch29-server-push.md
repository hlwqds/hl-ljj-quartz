# Chapter 29: Server Push in HTTP/3

## 29.1 What is Server Push?

Server push allows a server to send resources to the client before the client explicitly requests them. Originally introduced in HTTP/2, server push is also available in HTTP/3.

```
Traditional HTTP Request:
  Client → Server: GET /index.html
  Server → Client: 200 OK + index.html
  Client parses index.html
  Client → Server: GET /style.css
  Server → Client: 200 OK + style.css
  ...

Server Push:
  Client → Server: GET /index.html
  Server → Client: 200 OK + index.html
  Server → Client: PUSH_PROMISE /style.css
  Server → Client: PUSH_PROMISE /app.js
  Server → Client: [pushed /style.css content]
  Server → Client: [pushed /app.js content]
  Client: already has pushed resources when needed
```

The server anticipates what the client will need based on the requested resource and proactively sends it.

### 29.1.1 Why Server Push?

```
Without push:
  RTT 1: Client requests index.html
  RTT 2: Server sends index.html (client discovers dependencies)
  RTT 3: Client requests style.css, app.js
  RTT 4: Server sends style.css, app.js
  Total: 4 RTTs

With push:
  RTT 1: Client requests index.html
  RTT 2: Server sends index.html + pushes style.css + app.js
  Total: 2 RTTs
```

Server push can eliminate multiple round trips for dependent resources.

## 29.2 Server Push in HTTP/3

HTTP/3 server push uses three frame types:

| Frame        | Direction       | Purpose                  |
| ------------ | --------------- | ------------------------ |
| PUSH_PROMISE | Server → Client | Announces intent to push |
| CANCEL_PUSH  | Client → Server | Cancels a push           |
| MAX_PUSH_ID  | Client → Server | Limits pushes            |

### 29.2.1 Push Stream

Server push uses **server-initiated bidirectional streams**. The server opens a new stream and sends:

```
Server → Client (push stream):
  PUSH_PROMISE frame (promised request headers)
  HEADERS frame (response headers for promised request)
  DATA frames (response body)
  STREAM FIN
```

## 29.3 PUSH_PROMISE Frame

The PUSH_PROMISE frame announces a promised resource:

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
  Stream 5 (server-initiated bidirectional):
    PUSH_PROMISE {
      Push ID = 0,
      Header Block = QPACK(:method: GET, :scheme: https,
                           :authority: example.com, :path: /style.css)
    }
```

### 29.3.1 Push ID

Each push is identified by a **Push ID** -- a monotonically increasing varint:

```
Push ID 0: First promised resource
Push ID 1: Second promised resource
Push ID 2: Third promised resource
...
```

Push IDs are scoped to the connection. The server MUST NOT push resources with the same Push ID twice.

### 29.3.2 Promised Request Headers

The PUSH*PROMISE contains the request headers the client \_would* have sent to request the resource:

```
Promised request:
  :method: GET
  :scheme: https
  :authority: example.com
  :path: /style.css
  user-agent: MyBrowser/1.0
  accept: text/css, */*
  accept-encoding: gzip, deflate, br
  accept-language: en-US,en;q=0.9
```

These headers tell the client what the push is for and allow the client to decide whether to accept or cancel the push.

## 29.4 Push Stream Lifecycle

A complete push sequence:

```
1. Server opens push stream (server-initiated bidirectional)

2. Server sends PUSH_PROMISE (on any bidirectional stream):
   PUSH_PROMISE { Push ID = 0, :path: /style.css }

3. Server sends response on the push stream:
   HEADERS { :status: 200, content-type: text/css }
   DATA { <style.css content> }
   STREAM FIN

4. Client receives PUSH_PROMISE, associates with Push ID

5. Client receives push stream with same Push ID

6. Client matches push stream data with earlier PUSH_PROMISE
```

### 29.4.1 PUSH_PROMISE on Any Stream

The PUSH_PROMISE can be sent on any bidirectional stream, not just the push stream itself. This allows the server to send promises early:

```
Server → Client:
  On Stream 0 (response to GET /):
    PUSH_PROMISE { Push ID = 0, :path: /style.css }
    PUSH_PROMISE { Push ID = 1, :path: /app.js }

  On Stream 3 (push stream):
    HEADERS { :status: 200, content-type: text/css }
    DATA { <style.css content> }
    STREAM FIN

  On Stream 5 (push stream):
    HEADERS { :status: 200, content-type: application/javascript }
    DATA { <app.js content> }
    STREAM FIN
```

## 29.5 Client Control: MAX_PUSH_ID

The client controls how many push streams the server can open by sending MAX_PUSH_ID:

```
Client → Server:
  MAX_PUSH_ID { Max Push ID = 5 }

Server:
  MUST NOT open push streams with Push ID > 5
  Push IDs 0-5 can be used
```

### 29.5.1 Default Limit

If the client doesn't send MAX_PUSH_ID, the default is 0 -- meaning no server push is permitted. The server MUST NOT push unless it has received a MAX_PUSH_ID larger than the Push ID it intends to use.

### 29.5.2 Reducing Push Limit

If the client wants to cancel all pending pushes, it sends a smaller MAX_PUSH_ID:

```
Previously sent: MAX_PUSH_ID { 10 }
New: MAX_PUSH_ID { 3 }

Server:
  Stops using Push IDs 4-10
  Cancels any in-progress pushes with those IDs
```

## 29.6 Client Cancellation: CANCEL_PUSH

The client can cancel a push at any time:

```
Client → Server:
  CANCEL_PUSH { Push ID = 3 }
```

### 29.6.1 When to Cancel

Common reasons for cancellation:

```
1. Resource already cached
   Client has /style.css in cache -> cancel push

2. User navigated away
   Client requested /page1, then immediately went to /page2
   -> cancel pending pushes for /page1

3. Disk space concerns
   Client is low on storage -> cancel large pushes

4. Custom prioritization
   Client wants different resources first -> cancel and re-request
```

### 29.6.2 Server Behavior on Cancel

```
Server receives CANCEL_PUSH { Push ID = 3 }:
  If push stream for ID 3 hasn't been created:
    Don't create it
  If push stream for ID 3 is in progress:
    Send STOP_SENDING on that stream
    Stop sending data
  If push stream for ID 3 is complete:
    Ignore (nothing to cancel)
```

## 29.7 Push Stream Matching

The client must match incoming push streams with earlier PUSH_PROMISE frames:

### 29.7.1 Implicit Matching

```
Client receives:
  1. PUSH_PROMISE { Push ID = 0, :path: /style.css } on Stream 0
  2. Push stream with Push ID = 0 on Stream 3

Client matches:
  Stream 3 -> Push ID 0 -> /style.css
  Resource is expected
```

### 29.7.2 Unmatched Push Streams

If a push stream arrives without a matching PUSH_PROMISE:

```
Client receives:
  Push stream with Push ID = 5
  Client never received PUSH_PROMISE for ID 5

Client behavior:
  -> H3_GENERAL_PROTOCOL_ERROR
  -> Reset stream with error
```

### 29.7.3 Duplicate PUSH_PROMISE

If the server sends PUSH_PROMISE for a push already being sent:

```
Server → Client:
  PUSH_PROMISE { Push ID = 0, :path: /style.css }
  ... later ...
  PUSH_PROMISE { Push ID = 0, :path: /different.css }  // Duplicate!

Client:
  -> H3_GENERAL_PROTOCOL_ERROR
```

## 29.8 Push Stream Dependency

HTTP/3 doesn't have explicit push stream dependencies (unlike HTTP/2's prioritized streams). Push streams compete for connection bandwidth via QUIC's own stream prioritization mechanisms.

### 29.8.1 Implicit Ordering

The order of PUSH_PROMISE frames implies intent:

```
Server sends:
  PUSH_PROMISE { Push ID = 0 } first
  PUSH_PROMISE { Push ID = 1 } second

This suggests Push ID 0 is more important
```

But HTTP/3 doesn't mandate client behavior based on this ordering. The client can process pushes in any order.

### 29.8.2 QUIC Stream Priority

QUIC doesn't define stream priority; all streams compete equally by default. HTTP/3 push prioritization relies on:

- Server sending order
- Client receive buffer processing order
- Implementation-specific optimizations

## 29.9 Caching and Push

### 29.9.1 Pushed Response Cacheability

Pushed responses are cacheable if they have a `cache-control` header:

```
Server → Client:
  HEADERS {
    :status: 200
    content-type: text/css
    cache-control: max-age=3600
    etag: "abc123"
  }
  DATA { <style.css> }

Client:
  Stores in cache with key: (host, path, vary-headers)
  Can serve from cache for subsequent requests
```

### 29.9.2 Vary Header and Push

If the pushed response has a `vary` header, the cache key includes those fields:

```
Pushed response:
  vary: accept-encoding

Cache key includes:
  path: /style.css
  accept-encoding: gzip

Client's actual request might have different accept-encoding:
  If mismatch, pushed response cannot be used
```

### 29.9.3 Stale Cache and Push

```
Client has stale /style.css in cache
Server pushes fresh /style.css
Client:
  Uses pushed response
  (Push overrides stale cache)
```

## 29.10 Push and Flow Control

Push streams consume connection flow control credit just like regular streams:

```
Connection flow control: 10MB
Server pushes 5MB:
  -> 5MB credit used
  -> 5MB remaining for client requests

If client has no credit:
  Server cannot push until client ACKs and frees credit
```

### 29.10.1 Server-Side Flow Control

```
Server's receive buffer: 1MB per stream
Push stream receives 2MB:
  -> STOP_SENDING
  -> Server stops sending
```

## 29.11 PUSH_PROMISE and QPACK

The PUSH_PROMISE contains QPACK-encoded request headers. This means the decoder needs the dynamic table entries to decode the promise.

### 29.11.1 Decoder Requirements

```
Server sends PUSH_PROMISE with QPACK reference to dynamic entry 65:
  Server must ensure client has dynamic entry 65
  -> Entry 65 must have been sent on QPACK control stream
  -> Entry 65 must have been ACKed
```

### 29.11.2 Push Promise Blocking

If the client's QPACK decoder is blocked on entry 65:

```
Client: blocked waiting for dynamic entry 65
Server: PUSH_PROMISE references entry 65

Client:
  Sends QPACK_STREAM_BLOCKED frame

Server:
  Receives STREAM_BLOCKED
  Sends entry 65 on QPACK control stream (duplicate)

Client:
  Receives entry 65
  Can now decode PUSH_PROMISE
```

## 29.12 Push and Error Handling

### 29.12.1 Server Push Errors

```
If server encounters error mid-push:
  Server sends STOP_SENDING
  Client resets stream

Error codes:
  H3_REQUEST_CANCELLED (0x010c): Push was cancelled
  H3_INTERNAL_ERROR (0x0102): Server bug
  H3_GENERAL_PROTOCOL_ERROR (0x0101): Protocol violation
```

### 29.12.2 Malformed Push Promise

```
If PUSH_PROMISE has invalid headers:
  Client: H3_FRAME_ERROR
  Connection error

If PUSH_PROMISE for unsafe resource:
  Client: H3_GENERAL_PROTOCOL_ERROR
  (e.g., pushing POST resource that isn't idempotent)
```

### 29.12.3 Security: Push Cache Poisoning

Malicious server could push resources to poison client's cache:

```
Attacker (MITM):
  Intercepts connection
  Pushes /login.css (containing credential-stealing JS)

Client:
  Caches malicious /login.css
  Later requests /login
  Serves attacker-controlled CSS -> XSS
```

HTTP/3 mitigates this by requiring push promises to use the same origin and be acknowledged via SETTINGS. Clients can disable push entirely.

## 29.13 Server Push vs. Resource Hints

Server push competes with client-side resource hints:

```
<link rel="preload" href="/style.css">
  Client tells server: "I'll need this soon"
  Client initiates request (but doesn't block)

<link rel="prefetch" href="/next-page.js">
  Client tells browser: "Speculatively fetch this"
  Lower priority than preload
```

| Mechanism   | Initiator | Timing             | Cancellation |
| ----------- | --------- | ------------------ | ------------ |
| Server Push | Server    | Immediate          | CANCEL_PUSH  |
| Preload     | Client    | On link processing | Stop fetch   |
| Prefetch    | Client    | Idle time          | Stop fetch   |

## 29.14 Common Push Patterns

### 29.14.1 Inline Resources

```
Server pushes resources embedded in HTML:
  GET /index.html
  Server sends index.html
  Server pushes style.css, app.js (referenced in HTML)
```

### 29.14.2 Brotli-Pushed Compression

```
Client sends: accept-encoding: gzip, br
Server pushes: br-compressed version (saves bandwidth)
```

### 29.14.3 Authenticated Push

```
Push promise includes authentication headers:
  PUSH_PROMISE {
    :path: /user-avatar.jpg
    authorization: Bearer abc123
  }

Push response tailored to user's session
```

## 29.15 Server Push Summary

Server push in HTTP/3:

```
1. Client sends MAX_PUSH_ID (enables push, sets limit)

2. Server sends PUSH_PROMISE (announces push intent)
   - On any bidirectional stream
   - Contains Push ID + promised request headers

3. Server opens push stream
   - PUSH_PROMISE must precede response
   - HEADERS + DATA + FIN

4. Client can cancel with CANCEL_PUSH

5. Pushed responses are cacheable with proper headers
```

Key differences from HTTP/2:

- HTTP/3 uses QUIC streams (no HEADERS frame with flag bits)
- HTTP/3 has MAX_PUSH_ID for explicit push limits
- HTTP/3 PUSH_PROMISE can be on any stream
- HTTP/3 has CANCEL_PUSH for client cancellation

## 29.16 Summary

Server push enables proactive resource delivery in HTTP/3. The server announces pushes via PUSH_PROMISE, sends responses on dedicated push streams, and the client can cancel via CANCEL_PUSH or limit via MAX_PUSH_ID.

While server push can eliminate round trips, it's not always beneficial:

- If the client already has the resource, push wastes bandwidth
- Push competes with critical resources for bandwidth
- Cache validation after push can add overhead

Modern approaches often prefer the client using `<link rel="preload">` hints, giving the client more control over fetch timing and priority. The next chapter compares HTTP/2 and HTTP/3 in detail.
