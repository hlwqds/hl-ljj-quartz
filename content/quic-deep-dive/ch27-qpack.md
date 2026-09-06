# Chapter 27: QPACK Header Compression

## 27.1 Why Header Compression Matters

HTTP headers are repeated on every request and response. A typical HTTP request might have 10-15 headers totaling 500-1000 bytes. For a page with 50 resources loaded sequentially, header overhead becomes significant.

HTTP/1.1 used raw text headers with minor compression. HTTP/2 introduced **HPACK** (RFC 7541), which achieved ~75% header size reduction. HTTP/3 uses **QPACK**, a variant of HPACK adapted for QUIC's out-of-order delivery model.

### 27.1.1 Header Compression Requirements

Header compression must satisfy:

- **Contextual compression**: Headers that repeat across requests (e.g., `host`, `user-agent`) should compress extremely well
- **Random access**: The decoder must be able to decode any header field without processing prior ones (for out-of-order delivery)
- **Memory efficiency**: Bounded memory usage even with adversarial input
- **Forward compatibility**: New header fields should compress without requiring protocol changes

## 27.2 QPACK Overview

QPACK is HPACK's successor, redesigned for QUIC. The key difference: **HPACK assumed ordered delivery** (as TCP provides), while **QPACK handles out-of-order delivery** (as QUIC streams provide).

```
HPACK (HTTP/2):
  Assumes: All frames arrive in order
  Encoder: References previous entries by index
  Problem: If entry #5 hasn't arrived yet, reference fails

QPACK (HTTP/3):
  Assumes: Stream data may arrive out of order
  Encoder: References entries only after they're acknowledged
  Solution: Track which entries the decoder has received
```

## 27.3 QPACK Data Structures

QPACK uses two data structures shared between encoder and decoder:

### 27.3.1 Static Table

A predefined table of 98 commonly-used HTTP header fields. Entries like `method: GET`, `:status: 200`, `content-type: application/json` are always available without transmission.

```
Static Table (selected entries):
+----+----------------------------+---------------+
| n  | Name                      | Value         |
+----+----------------------------+---------------+
|  0 | :authority                |               |
|  1 | :method                   | GET           |
|  2 | :method                   | POST          |
|  3 | :scheme                   | http          |
|  4 | :scheme                   | https         |
|  5 | :path                     | /             |
|  6 | :path                     | /index.html   |
|  7 | :status                   | 200           |
| 8  | :status                   | 204           |
|  9  | :status                   | 206           |
| 10 | :status                   | 304           |
| 11 | :status                   | 400           |
| 12 | :status                   | 404           |
| 13 | :status                   | 500           |
| 14 | accept                    |               |
| 15 | accept-encoding           | gzip, deflate |
| 16 | accept-language           |               |
...
+----+----------------------------+---------------+
```

The static table is protocol-defined; both encoder and decoder know all entries.

### 27.3.2 Dynamic Table

A table of header fields learned during the connection. Entries from requests and responses are added dynamically and shared between endpoints.

```
Dynamic Table (example after a few requests):
+--------+----------------------------+---------------+
| Base Index = 62 (starts after static table)      |
+--------+----------------------------+---------------+
| 63     | x-request-id              | abc123        |
| 64     | x-session-token          | sess_xyz      |
| 65     | content-type              | text/html     |
+--------+----------------------------+---------------+
```

Entries are referenced by their **relative index** from the largest index in the table.

### 27.3.3 Index Space

QPACK combines static and dynamic tables into a single addressable space:

```
Index 0-97:     Static table entries (n = 0-97)
Index 98+:      Dynamic table entries (n = 98, 99, ...)
```

The dynamic table grows "upward" from the static table base.

## 27.4 QPACK Instructions

QPACK defines four primitive instructions for encoding headers:

### 27.4.1 Indexed Header Field

References a previously seen entry (static or dynamic):

```
Indexed Header Field (index 7):
  0  1  2  3  4  5  6  7
  +--+--+--+--+--+--+--+--+
  | 1 |      7 (index)   |
  +--+--+--+--+--+--+--+--+

Decodes to: :status: 200
```

### 27.4.2 Indexed Header Field with Post-Base Index

References an entry in the dynamic table using post-base index (for entries added by the encoder, referenced by the decoder's "after" position):

```
Post-Base Indexed:
  0  1  2  3  4  5  6  7  8  9
  +--+--+--+--+--+--+--+--+--+
  | 1 | 1 |    index         |
  +--+--+--+--+--+--+--+--+--+

Note: The post-base index bit (bit 1) indicates post-base addressing
```

### 27.4.3 Literal Header Field with Name Reference

Uses a name from the static or dynamic table, with a literal value:

```
Literal with Name Reference (index 14, value "text/html"):
  0  1  2  3  4  5  6  7  8  9 ...
  +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
  | 0 | 1 |      14 (name index)    | Huffman |
  +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
  |          Length (variable)                     |
  +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
  |          Value (variable)                     |
  +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

### 27.4.4 Literal Header Field with Literal Name

Both name and value are transmitted literally:

```
Literal with Literal Name:
  0  1  2  3  4  5  6  7  8 ...
  +--+--+--+--+--+--+--+--+--+--+
  | 0 | 0 | 1 | 1 |    0      |
  +--+--+--+--+--+--+--+--+--+--+
  | H |    Name Length        |
  +--+--+--+--+--+--+--+--+--+
  |          Name             |
  +--+--+--+--+--+--+--+--+--+
  | H |    Value Length       |
  +--+--+--+--+--+--+--+--+--+
  |          Value            |
  +--+--+--+--+--+--+--+--+--+
```

The `H` bit indicates Huffman-coded string.

## 27.5 QPACK Tables in Detail

### 27.5.1 Dynamic Table Entry Structure

Each dynamic table entry stores:

```c
struct qpack_entry {
    char *name;           // e.g., "x-request-id"
    char *value;          // e.g., "abc123"
    size_t name_len;
    size_t value_len;
};
```

The dynamic table is bounded by the `SETTINGS_QPACK_MAX_TABLE_CAPACITY` setting.

### 27.5.2 Table Capacity vs. Size

QPACK distinguishes between:

- **Table capacity**: Maximum memory allocated for the table
- **Table size**: Current actual memory used

```
Table capacity: 4096 bytes
Current entries: 3 entries using 200 bytes

New entry arrives (500 bytes):
  If 200 + 500 <= 4096: Add entry
  Otherwise: Evict oldest entries until space available
```

## 27.6 The QPACK State Machine

QPACK requires careful coordination between encoder and decoder. The encoder tracks the **dynamic table context** -- which entries the decoder has acknowledged.

### 27.6.1 Encoder and Decoder State

```
Encoder tracks:
  - Dynamic table entries (local copy)
  - Largest known decoder table capacity
  - Entries the decoder has acknowledged
  - Unacknowledged entries pending

Decoder tracks:
  - Dynamic table entries received
  - Acknowledged entries list
  - Blocked streams waiting for specific entries
```

### 27.6.2 Insert Count

The **insert count** tracks total entries in the dynamic table:

```
Insert Count = static entries + dynamic entries added
            = 98 + number_of_dynamic_entries
```

Both endpoints track the same insert count once entries are acknowledged.

## 27.7 Out-of-Order Decoding

The critical innovation in QPACK is handling out-of-order header blocks.

### 27.7.1 Header Block and Insert Count

A header block consists of:

1. Encoded header field instructions
2. An absolute **Insert Count** value
3. A **Largest Reference** (the highest entry index referenced)

```
Header Block:
  +--------------------------------------------------+
  | Prefixed Insert Count (6 bits + 1 bit)            |
  +--------------------------------------------------+
  | Encoded Header Fields (variable)                 |
  +--------------------------------------------------+
```

### 27.7.2 Required Insert Count

The **Required Insert Count** is the number of table entries the decoder needs to process the header block:

```
Required Insert Count = Largest Reference + 1
```

If the decoder has fewer than Required Insert Count entries, it is **blocked** and must wait.

### 27.7.3 Blocked Streams

When a decoder receives a header block with a required insert count it doesn't have:

```
Decoder receives header block:
  Largest Reference = 5
  Required Insert Count = 6
  Decoder has entries 0-3 in dynamic table
  -> BLOCKED, wait for entries 4-5
```

The decoder sends a **QPACK decoder capacity** in SETTINGS to tell the encoder its buffer size. The encoder MUST NOT assume the decoder can process entries beyond this limit.

### 27.7.4 QPACK_STREAM_BLOCKED Frame

If the decoder is blocked, it sends a QPACK_STREAM_BLOCKED frame:

```
QPACK_STREAM_BLOCKED Frame {
  Type = 0x13,
  Stream ID (64 bits),
}
```

This tells the encoder: "I'm blocked on this stream because I need more entries." The encoder responds by sending the needed entries (or a duplicate) on the **QPACK stream**.

## 27.8 QPACK Control Stream

QPACK data (dynamic table updates) flows on a dedicated **QPACK control stream** distinct from request streams.

```
QPACK Control Stream:
  +---------------------------------------------------+
  | QPACK Dynamic Table Section Update               |
  |   - Insert entries into dynamic table           |
  +---------------------------------------------------+
  | QPACK Stream Cancellations                       |
  |   - Indicate blocked streams                     |
  +---------------------------------------------------+
```

### 27.8.1 Table State Sync

When the encoder adds entries to the dynamic table, it sends **Table State Sync** instructions on the QPACK control stream:

```
Encoder adds entry to dynamic table:
  Sends on QPACK control stream:
    +--------------------------------------------------+
    | 0 | 0 | 1 | 0 |      0 (dynamic table entry)      |
    +--------------------------------------------------+
    | H | Name Length          | Name                   |
    +--------------------------------------------------+
    | H | Value Length        | Value                   |
    +--------------------------------------------------+
```

Decoder receives, adds to its dynamic table. Tables stay synchronized.

### 27.8.2 Dynamic Table Capacity

The encoder can change the dynamic table capacity via **Set Dynamic Table Capacity**:

```
Set Dynamic Table Capacity:
  0  1  2  3  4  5  6  7
  +--+--+--+--+--+--+--+--+
  | 0 | 1 | 1 | 1 | capacity (6 bits)              |
  +--+--+--+--+--+--+--+--+
```

If capacity is reduced below current size, oldest entries are evicted.

## 27.9 Encoding Example

Consider encoding this request:

```
GET /api/users HTTP/1.1
Host: api.example.com
User-Agent: MyClient/1.0
Accept: application/json
```

Encoding with QPACK:

```
Step 1: Static table lookups
  - :method: GET      -> Static table index 1
  - :path: /api/users -> Literal (not in static table)
  - :authority: api.example.com -> Static table index 0 (with literal value)
  - user-agent: MyClient/1.0    -> Literal (not in static table)
  - accept: application/json    -> Static table index 14 (with literal value)

Step 2: Generate encoded header block
  - Indexed: :method = GET (index 1)
  - Literal with name reference: :path (literal "/api/users")
  - Literal with name reference: :authority (index 0, literal "api.example.com")
  - Literal with name reference: user-agent (index 14, literal "MyClient/1.0")
  - Literal with name reference: accept (index 14, literal "application/json")

Step 3: Add dynamic table entries if needed
  - Store :path and user-agent in dynamic table for future use
```

## 27.10 QPACK and QUIC Stream Ordering

QPACK's design accommodates QUIC's fundamental property: streams are independent and may deliver data out of order.

### 27.10.1 Problem: Missing Dynamic Table Entry

```
Scenario:
  Stream 1: Encoder sends header referencing dynamic entry 65
  Stream 2: Decoder hasn't received dynamic entry 65 yet

  If HPACK: Stream 2 header decode fails
  If QPACK: Stream 2 blocked until entry 65 arrives
```

### 27.10.2 Solution: Pre-emptive Table Updates

The encoder MUST send dynamic table updates on the QPACK control stream _before_ referencing them in header blocks:

```
1. Encoder learns :path = /api/v1/users from response
2. Encoder adds to dynamic table (index 63)
3. Encoder sends Table State Sync on QPACK control stream
4. Wait for decoder ACK
5. Encoder can now reference index 63 in request headers
```

This ensures the decoder has the entry before it's needed.

### 27.10.3 Tracking Unacknowledged Entries

The encoder maintains a list of unacknowledged entries:

```
Unacknowledged Entries:
  - Index 63: :path = /api/v1/users (pending ACK)
  - Index 64: x-request-id = abc123 (pending ACK)

Once decoder ACKs:
  - Entry marked as acknowledged
  - Encoder knows decoder has it
```

If the encoder doesn't receive timely ACK, it retransmits the entry (via the QPACK control stream, duplicating the necessary data).

## 27.11 Memory Safety

QPACK's dynamic table is a potential attack surface. Attackers could send headers designed to fill the table with garbage, evicting useful entries.

### 27.11.1 Table Capacity Limits

```
SETTINGS_QPACK_MAX_TABLE_CAPACITY:
  Default: 0 (no dynamic table)
  Typical: 4096 bytes
  Maximum: Implementation-defined
```

The SETTINGS negotiation includes the maximum table capacity each endpoint will accept.

### 27.11.2 Entry Eviction

When adding a new entry would exceed capacity:

```
Current dynamic table:
  - Index 63: :path = /api/v1/users
  - Index 64: x-request-id = abc123
  Total size: 200 bytes, Capacity: 4096 bytes

New entry: 5000 bytes (e.g., huge cookie value)
  200 + 5000 > 4096

Solution: Evict oldest entries until space available
  - Evict index 63 (100 bytes)
  - Evict index 64 (100 bytes)
  - Still need space: capacity insufficient -> reject entry or increase capacity
```

### 27.11.3 Empty Dynamic Table Mode

Clients that don't need dynamic compression can set `QPACK_MAX_TABLE_CAPACITY = 0`. This disables dynamic table entirely, eliminating memory attack surface. All headers are encoded using static table references or literals.

## 27.12 QPACK Frame Types

QPACK defines several frame types on the QPACK control stream:

```
QPACK Frame Types:
  0x00  - QPACK_DYNAMIC_TABLE_CAPACITY (Set capacity)
  0x80  - QPACK_DYNAMIC_TABLE_SIZE_UPDATE (Resize)
  0xC0  - QPACK_STREAM_CANCELLATION (Stream blocked indicator)
```

These frames coordinate the dynamic table between encoder and decoder.

## 27.13 Comparison: HPACK vs QPACK

```
| Feature              | HPACK              | QPACK                    |
|----------------------|--------------------|--------------------------|
| Delivery assumption  | Ordered (TCP)      | Unordered (QUIC)         |
| Blocking             | Implicit            | Explicit via RIC/RIS     |
| Dynamic table sync   | Immediate           | Requires acknowledgment  |
| Control stream       | N/A (HPACK over     | Separate QPACK control   |
|                      |   same stream)      |   stream                 |
| Encoder state        | Tracks insert count| Tracks required insert   |
|                      |                     |   count + unacked entries|
| Decoder blocked      | Implicit wait       | Sends STREAM_BLOCKED     |
| Memory model         | Reference counting  | Capacity-based eviction  |
```

## 27.14 Summary

QPACK is HTTP/3's header compression scheme, derived from HPACK but redesigned for QUIC's unordered stream delivery:

- **Static table**: 98 predefined header field entries
- **Dynamic table**: Learned entries shared between endpoints
- **Out-of-order handling**: Required Insert Count and blocked stream signaling
- **Control stream**: Dedicated stream for dynamic table synchronization
- **Capacity limits**: Bounded memory usage via capacity negotiation
- **Literal encoding**: Full literal support when dynamic table isn't used

QPACK ensures headers compress well (saving bandwidth) while supporting QUIC's independent stream model. The decoder can be blocked waiting for table entries, but the encoder ensures this rarely happens via pre-emptive table updates.
