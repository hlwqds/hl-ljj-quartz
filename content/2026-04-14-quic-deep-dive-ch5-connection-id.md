# Chapter 5: Connection IDs

## 5.1 The Problem with 4-Tuple Addresses

A TCP connection is identified by the 4-tuple: `(src IP, src port, dst IP, dst port)`. This creates a fundamental problem: if any of these four values change, the connection breaks. In mobile networks, clients switch between WiFi and cellular, or move between cell towers. Each change can cause the client's IP address or port to change, and the TCP connection dies.

QUIC solves this by introducing **Connection IDs (CIDs)** -- opaque, variable-length byte sequences that serve as the primary identity of a QUIC connection, independent of the network address.

```
TCP Connection = f(src IP, src port, dst IP, dst port)
                 // changes when IP/port changes → connection breaks

QUIC Connection = f(Connection ID)
                  // independent of IP/port → connection survives network changes
```

## 5.2 Anatomy of a Connection ID

A Connection ID is an opaque byte sequence of 0 to 20 bytes. The maximum length is 20 bytes (160 bits) to fit in the QUIC header's CID field encoding and to provide sufficient entropy for unobservability.

```
Connection ID: 0 to 20 bytes (variable length, per CID)
```

**CID Length Field:** The first two bits of a long header packet encode the CID length using the same variable-length integer scheme (with a 2-bit prefix).

| Prefix | Length |
|---|---|
| `00` | 0 bytes (CID-less packet) |
| `01` | 1 byte |
| `10` | 2 bytes |
| `11` | 3 bytes |

(For long header packets; short header CIDs are encoded differently in the header.)

**CID Zero Length:** A CID of length zero is valid. In this case, the packet header contains no CID bytes at all. This is allowed for short header packets, meaning a packet with a zero-length CID is identified purely by the 4-tuple. However, zero-length CIDs prevent connection migration.

## 5.3 Why 20 Bytes Maximum?

1. **Header efficiency**: The 2-bit length prefix can encode 0-3, and CID lengths above 3 are encoded as "3" plus a variable-length integer. However, the spec caps it at 20 bytes to keep header sizes manageable.
2. **Entropy**: 160 bits provides sufficient randomness to make CID guessing infeasible.
3. **Privacy**: Longer CIDs with high entropy prevent off-path observers from correlating connections.
4. **Routing**: Some load balancers embed routing information in CIDs.

## 5.4 Multi-CID Architecture

A single QUIC connection uses **multiple Connection IDs simultaneously**. Each endpoint can have multiple active CIDs:

```
Client's view of the connection:
  CID_A → points to path 1 (WiFi)
  CID_B → points to path 2 (Cellular)
  CID_C → retired, no longer valid

Server's view of the connection:
  Maps CID_A, CID_B, CID_C to the same connection state
```

This allows:
- **Parallel path usage**: Send packets on multiple paths simultaneously
- **Connection migration**: Switch from one path to another seamlessly
- **Load balancing**: Server routes connections based on CID, not 4-tuple

## 5.5 CID Lifecycle: NEW_CONNECTION_ID and RETIRE_CONNECTION_ID

CID management is explicit via two frame types:

### NEW_CONNECTION_ID Frame

Server (or client, for certain use cases) creates a new CID:

```
NEW_CONNECTION_ID Frame {
  Type           = 0x18,
  Sequence Number (i),        // Monotonically increasing integer
  Retire Prior To (i),         // Retire all CIDs with seq < this value
  Connection ID Length (i),    // 0-20
  Connection ID (bytes),       // The actual CID value
  Stateless Reset Token (128 bits)  // Used for stateless reset
}
```

**Sequence Number**: Identifies the CID. Used for ordering and for `RETIRE_CONNECTION_ID`.

**Retire Prior To**: When the server sends `NEW_CONNECTION_ID` with `retire_prior_to = N`, the client must retire all CIDs with sequence number < N. This is the server-side mechanism to prune the CID set.

**Stateless Reset Token**: A 128-bit value used to verify a stateless reset (Section 5.7).

### RETIRE_CONNECTION_ID Frame

An endpoint retires a CID it previously issued:

```
RETIRE_CONNECTION_ID Frame {
  Type           = 0x19,
  Sequence Number (i)         // Retire the CID with this sequence number
}
```

An endpoint might retire CIDs when:
- It no longer needs the alternative path
- It's reducing the number of active CIDs to save state
- A particular path is no longer usable

## 5.6 Initial Connection ID and the Handshake

The Initial packet's CID deserves special attention. Here's the sequence during connection establishment:

1. **Client chooses initial CID**: The client picks a random CID for its first Initial packet. This CID is used to derive Initial secrets.
2. **Server responds with its own CID**: In the server's Initial packet, it includes a Source Connection ID (SCID). This SCID becomes the client's DCID for subsequent Handshake and 1-RTT packets.
3. **Both sides may issue additional CIDs**: After the handshake, either side can send `NEW_CONNECTION_ID` frames to add CIDs for migration.

```
Client                                      Server
  |                                            |
  |  Initial (DCID=client-chosen-CID)          |
  |----------------------------------------→  |
  |                                            |
  |  Initial (SCID=server-chosen-CID)          |
  |  + NEW_CONNECTION_ID (additional CIDs)     |
  |←----------------------------------------  |
  |                                            |
  |  [1-RTT packets use server's SCID as DCID] |
```

## 5.7 Stateless Reset

What happens when a server loses all state for a connection? Normally, the server would drop incoming packets and the connection would timeout. QUIC provides a mechanism called **stateless reset** to gracefully handle this.

### How Stateless Reset Works

1. The server maintains the `Stateless Reset Token` for each CID it issues.
2. When the server loses connection state but receives a packet with a CID it issued:
   a. It verifies the packet number is in a valid range (within 2*max_ack_delay of the last received packet number)
   b. It computes: `test = HMAC-SHA256(stateless_reset_token, connection_id)`
   c. It compares the first 16 bytes of `test` to the last 16 bytes of the incoming packet
   d. If they match with high probability, it sends a `CONNECTION_CLOSE` with error code `0xXXXXXXXX` (stateless_reset)
   e. If not, it drops the packet

The stateless reset token is a 128-bit secret known only to the server. A client that receives a stateless reset packet will see a `CONNECTION_CLOSE` with `error_code=stateless_reset (0xXXXXXXXX)` and can recognize this as a stateless reset (not a normal close).

### Stateless Reset Token Protection

The stateless reset token is 128 bits. Because the test uses HMAC-SHA256, a client cannot forge a stateless reset without knowing the token. The 16-byte comparison threshold is chosen so that random packets have a 2^-16 probability of falsely triggering a reset (acceptable false positive rate).

## 5.8 Connection Migration with CIDs

Connection migration is the process of continuing a QUIC connection on a different network path (different src IP/src port). The CID system makes this possible:

```
Step 1: Client is on WiFi, sending with CID_1
  Client (192.168.1.100:54321) → Server (203.0.113.1:443)
  QUIC DCID = CID_1

Step 2: WiFi drops, client switches to cellular (10.0.0.50:61443)
  Client has CID_2 (previously issued by server via NEW_CONNECTION_ID)

  Client (10.0.0.50:61443) → Server (203.0.113.1:443)
  QUIC DCID = CID_2

Step 3: Server recognizes CID_2, maps to existing connection state
  Connection continues from where it left off
```

The client must validate the new path before migrating (to prevent amplification attacks). This is done via PATH_CHALLENGE / PATH_RESPONSE frames.

## 5.9 CIDs and Load Balancing

CID-based routing is one of the most important practical benefits of QUIC for large-scale deployments:

**Traditional (TCP) load balancing:**
```
Client → L4 Load Balancer → Backend Server
  (LB rewrites dest IP/port based on 4-tuple hash)
```

Problem: When the client IP changes (mobile handoff), the 4-tuple hash changes, and the LB might route the packet to a different backend, breaking the connection.

**QUIC CID-based load balancing:**
```
Client → L4 Load Balancer → Backend Server
  (LB reads CID from packet header, routes by CID)
```

The CID encodes which backend server owns the connection. The LB can be stateless (CID → server mapping via consistent hashing) or stateful (CID → backend lookup table). When a client migrates to a new IP, the CID still routes to the same backend.

### CID Encoding for Load Balancing

Some deployments encode routing information directly in the CID:

```
CID = [route_bits (variable)] [connection_id (remaining)]
```

For example, the first 8 bits of the CID could encode the server index (0-255), allowing the LB to route to the correct server with a simple mask operation, without any lookup table.

## 5.10 Privacy Considerations

CIDs present a privacy challenge: a CID that persists across network changes could be used to track a user across networks. QUIC addresses this with CID rotation:

- Clients request new CIDs via `NEW_CONNECTION_ID` frames
- Servers retire old CIDs via `RETIRE_CONNECTION_ID` frames
- When migrating, clients should use a newly issued CID rather than a CID used on a previous network

**Minimum CID rotation:** The spec recommends that clients request at least one new CID when changing networks. The server should honor this by issuing a fresh CID.

**Zero-length CID on short header packets:** If the client uses a zero-length CID, migration is impossible -- the connection is tied to the 4-tuple. This is valid but limits mobility.

## 5.11 Summary

Connection IDs are the cornerstone of QUIC's connection-oriented architecture. By decoupling the connection identity from the network address, CIDs enable:
- **Connection migration** across network changes
- **Parallel path usage** with multiple active CIDs
- **Stateless load balancing** without sticky 4-tuple requirements
- **Privacy protection** through CID rotation

The CID lifecycle is explicitly managed via `NEW_CONNECTION_ID` and `RETIRE_CONNECTION_ID` frames, with `STATELESS_RESET_TOKEN` providing graceful recovery when server state is lost. Together with the version negotiation mechanism from Chapter 4, CIDs ensure QUIC connections can survive the reality of modern mobile networks.
