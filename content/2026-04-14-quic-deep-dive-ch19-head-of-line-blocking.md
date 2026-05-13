# Chapter 19: Connection Migration

## 19.1 The Problem: Changing Networks

In mobile networks, clients frequently change their network attachment:

- WiFi to cellular handover
- Cellular tower change
- VPN connect/disconnect
- NAT rebinding (public IP:port pair changes)

With TCP, any of these events breaks the connection. The 4-tuple `(src IP, src port, dst IP, dst port)` changes, and TCP has no mechanism to continue -- the connection dies.

QUIC solves this with **connection migration**: the ability to continue a connection on a different network path. The connection identifier (CID) system (Chapter 5) decouples connection identity from network address, enabling seamless migration.

## 19.2 Connection ID: The Key to Migration

A QUIC connection is identified by Connection IDs, not by the 4-tuple. As long as both endpoints agree the CID is valid, packets can be routed to that connection regardless of IP address or port.

```
Traditional TCP:
  Connection = f(src IP, src port, dst IP, dst port)
  IP changes → connection breaks

QUIC:
  Connection = f(Connection ID)
  IP changes (but CID valid) → connection continues
```

## 19.3 Migration Architecture

### 19.3.1 Path vs. Connection

QUIC distinguishes between:
- **Connection**: The logical QUIC state (streams, flow control, crypto keys)
- **Path**: A specific network route (src IP, src port, dst IP, dst port)

A connection can have multiple active paths (via multiple CIDs). A connection migrates when its primary path changes.

### 19.3.2 Active Path and Migration Path

```
Client has connection with Server using:
  - CID_A on path (192.168.1.100:54321 → 203.0.113.1:443) <- active path
  - CID_B on path (10.0.0.50:61443 → 203.0.113.1:443)     <- alternate path

When WiFi drops:
  - Client starts using CID_B on cellular path
  - Connection continues (same crypto state, same streams)
  - CID_B becomes the new active path
```

## 19.4 Path Validation

Before migration completes, the client must validate the new path. This prevents **amplification attacks** where an attacker sends packets with a spoofed source address.

### 19.4.1 PATH_CHALLENGE Frame

The client proves it can receive at its new address by sending a PATH_CHALLENGE:

```
PATH_CHALLENGE Frame {
  Type = 0x1e,
  Data (64 bits)    // Random data known only to client
}
```

The Data field is opaque -- the server must echo it back in PATH_RESPONSE.

### 19.4.2 PATH_RESPONSE Frame

The server responds to a valid PATH_CHALLENGE:

```
PATH_RESPONSE Frame {
  Type = 0x1f,
  Data (64 bits)    // Must match the PATH_CHALLENGE data
}
```

### 19.4.3 Validation Sequence

```
Client (new path) → Server:
  PATH_CHALLENGE (Data = random_64_bits)

Server (old path, verifies Data, sends response):
  PATH_RESPONSE (Data = random_64_bits)

Client receives valid PATH_RESPONSE:
  Path is validated, migration complete
  Connection continues on new path
```

If PATH_RESPONSE doesn't arrive within the probe timeout, the path is considered unusable and the client may fall back to the original path or abandon migration.

## 19.5 Path Validation During Address Change

When the client's address changes (even without explicit migration intent), the server must verify the new address:

1. Server receives packet from a new 4-tuple with a known CID
2. Server sends PATH_CHALLENGE to the new address
3. Client must respond with PATH_RESPONSE (proving reachability)
4. Server updates its notion of the active path

This is called **implicit path validation**: any packet from a new address implicitly triggers validation.

## 19.6 Client Address Change

When the client detects its local address changed (e.g., WiFi dropped, cellular took over), it:

1. Switches to using a CID from its issued CID list
2. Sends packets on the new path (PATH_CHALLENGE if probing)
3. Server validates and updates peer's address
4. Connection continues

```
Scenario: Client switches from WiFi to cellular

Before migration:
  Client (192.168.1.100:54321) → Server (203.0.113.1:443)
  DCID = CID_1

After WiFi drops:
  Client has CID_2 (previously issued via NEW_CONNECTION_ID)

  Client (10.0.0.50:61443) → Server (203.0.113.1:443)
  DCID = CID_2

  Server:
    - Recognizes CID_2
    - Maps to same connection state
    - Triggers path validation
    - Updates peer address to (10.0.0.50, 61443)
    - Connection continues
```

## 19.7 Server Address Change

Server-side address changes are rarer (servers tend to have stable IPs) but QUIC supports them:

```
Server changes its egress IP (e.g., load balancer failover):
  Server (203.0.113.2:443) → Client (192.168.1.100:54321)
  SCID = same CID

Client:
  - Receives packets from new server IP
  - Validates by sending PATH_CHALLENGE on new path
  - Connection continues with new server address
```

## 19.8 Connection Migration State Transfer

When migration occurs, the connection state is preserved:

| State | Migrates? | Notes |
|---|---|---|
| Stream data | Yes | Unacknowledged data retransmits on new path |
| Stream offsets | Yes | Preserved, retransmit uses same offsets |
| Flow control credit | Yes | Advertised limits apply on new path |
| Congestion state | Partial | cwnd and RTT estimates carry over |
| Crypto keys | Yes | Established keys work on new path |
| Packet numbers | No | New path starts with fresh packet numbers |

### 19.8.1 Packet Number Space After Migration

Each packet's number is independent. When a packet is lost and retransmitted, it gets a **new** packet number:

```
Before migration:
  Packet #10: STREAM frame (Stream 1, offset 0-999) -- LOST
  Packet #11: STREAM frame (Stream 1, offset 1000-1999)

After migration (new packet #15):
  Packet #15: STREAM frame (Stream 1, offset 0-999) -- RETRANSMIT

Receiver:
  - Has offset 0-999 from old packet #10
  - Identifies packet #15 as retransmit by offset
  - Deduplicates correctly
```

### 19.8.2 Congestion State After Migration

The congestion controller's state carries over, but the RTT estimate may be dramatically different on the new path:

```
WiFi path: RTT = 20ms, cwnd = 100 packets
Cellular path: RTT = 150ms, cwnd = 100 packets

After migration:
  - cwnd remains 100 packets (but may be too aggressive for new RTT)
  - RTT estimate updates based on new path
  - Congestion control adjusts cwnd over time
```

Most QUIC implementations apply a conservative approach after migration: either slightly reduce cwnd or use the new path's RTT to immediately recalculate.

## 19.9 Path State Machine

Each path (address pair) has states:

```
                     │
                     ▼
    ┌─────────────────────────────────┐
    │         UNVALIDATED             │
    │  Initial state for new path     │
    │  Cannot send non-probing frames │
    └─────────────┬───────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
        ▼                   ▼
    ┌─────────────┐   ┌─────────────┐
    │ VALIDATING   │   │   DROPPED   │
    │ PATH_CHAL    │   │  Path probe│
    │ sent, waiting│   │  failed     │
    └───────┬─────┘   └─────────────┘
            │
            ▼
    ┌─────────────────────────────────┐
    │          VALIDATED              │
    │  Path proven usable             │
    │  Non-probing frames allowed    │
    └─────────────┬───────────────────┘
                  │
                  ▼
    ┌─────────────────────────────────┐
    │          ACTIVE                 │
    │  Preferred path for sending     │
    └─────────────┬───────────────────┘
                  │
                  ▼
    ┌─────────────────────────────────┐
    │          DEPOPULATED            │
    │  No longer preferred path      │
    └─────────────────────────────────┘
```

## 19.10 Path Challenge/Response for Probing

When uncertain about a new path's viability, endpoints can send **path-probing packets** containing PATH_CHALLENGE frames. Unlike migration (which switches the primary path), probing simply validates the path exists without committing to it.

```
Probing without migrating:
  Client wants to test cellular before committing:
    Client (cellular) → Server: PATH_CHALLENGE
    Server → Client (cellular): PATH_RESPONSE
    Client received valid response: path is valid

  Client may:
    a) Migrate to cellular (use as active path)
    b) Keep WiFi as active, cellular as standby
    c) Drop cellular, stay on WiFi
```

## 19.11 Handling Migration Failures

Migration can fail for several reasons:

### 19.11.1 Path Validation Failure

If PATH_RESPONSE doesn't arrive:

```
Client:
  1. Sends PATH_CHALLENGE on new path
  2. Waits for probe_timeout (typically 3 * current RTT, max 10s)
  3. No response → path invalid
  4. May retry or fall back to original path
```

### 19.11.2 Peer Doesn't Receive Packets

If the server doesn't receive the client's migrated packets:

```
Server sees:
  - No packets from client on any known address
  - Connection times out

Server may:
  1. Send packets to all known client addresses (all CIDs)
  2. Wait for response
  3. If none, connection eventually times out
```

### 19.11.3 Stateless Reset

If the server loses connection state entirely (crash/restart), it can perform a stateless reset (Chapter 5). The client receives a CONNECTION_CLOSE with `error_code=stateless_reset` and can choose to reconnect or retry.

## 19.12 PMTUD and Migration

Path MTU Discovery (PMTUD) interacts with migration. Each path may have different MTU:

```
WiFi MTU: 1500 bytes
Cellular MTU: 1280 bytes (sometimes less)

After migration to cellular:
  - QUIC packet size must fit cellular's smaller MTU
  - Sender may need to reduce packet size
  - PMTU discovery restarts on new path
```

QUIC implementations typically use conservative MTU (1200 bytes) that works across most paths, avoiding the need for dynamic PMTUD adjustment.

## 19.13 ECN and Migration

Explicit Congestion Notification (ECN) marks may not be consistent across paths:

```
WiFi path: ECNECT(0) - clean
Cellular path: ECNCE(1) - congestion experienced

After migration:
  - ECN state is reset
  - New path's ECN marks are independently tracked
  - Loss/ECN history is path-specific
```

## 19.14 Connection Migration Summary

Connection migration enables QUIC connections to survive network changes by decoupling connection identity from network address:

| Mechanism | Role |
|---|---|
| Connection ID | Identifies connection independent of address |
| NEW_CONNECTION_ID | Issues CIDs for potential migration paths |
| PATH_CHALLENGE | Validates new path (anti-amplification) |
| PATH_RESPONSE | Proves path is bidirectional |
| Path state machine | Tracks path validation and preference |

Migration involves:
1. Detecting address change
2. Selecting a CID for the new path
3. Sending PATH_CHALLENGE to validate
4. Waiting for PATH_RESPONSE
5. Updating active path and continuing

The crypto state, stream state, and flow control all carry over. Only the packet number space is fresh on the new path.

## 19.15 Summary

Connection migration is one of QUIC's most practical features for mobile networks. By using Connection IDs as the connection identifier rather than the 4-tuple, QUIC enables seamless handovers between network interfaces or addresses without breaking the connection.

Path validation (PATH_CHALLENGE/PATH_RESPONSE) prevents amplification attacks during migration. The path state machine tracks validation, preference, and deprecation of network paths.

While most protocol state survives migration (crypto, streams, flow control), congestion state may need adjustment and packet numbers are path-specific. QUIC's design ensures that applications see uninterrupted stream delivery even as the underlying network path changes -- a significant improvement over TCP's connection breakage on network change.