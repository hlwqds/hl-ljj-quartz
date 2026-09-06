# Chapter 46: Multipath QUIC

## 46.1 The Problem: Single-Path Limitations

Traditional QUIC connections have a fundamental constraint: a connection is bound to a single network path (typically defined by the 4-tuple: source IP, source port, destination IP, destination port).

In today's heterogeneous network environments, this is limiting:

- **Mobile devices** regularly switch between WiFi and cellular
- **Enterprise networks** route traffic through multiple uplinks
- **Video conferencing** could benefit from combining bandwidth
- **Data centers** want to utilize all available network links

Multipath QUIC (RFC 9542) extends QUIC to use multiple network paths simultaneously, dramatically improving throughput, resilience, and user experience.

## 46.2 Multipath QUIC Architecture

### 46.2.1 Connection vs. Stream Semantics

```
Single-Path QUIC:
+------------------+
| QUIC Connection |
| (one path only) |
| +-------------+ |
| | Stream 1    | |
| +-------------+ |
| | Stream 2    | |
| +-------------+ |
+------------------+

Multipath QUIC:
+-------------------+
| QUIC Connection   |
| (multiple paths)  |
| +---------------+ |
| | Stream 1      | | <-- data distributed across paths
| +---------------+ |
| | Stream 2      | |
| +---------------+ |
+-------------------+
        ↑   ↑
   Path 1 Path 2
```

In multipath QUIC, streams are still the unit of reliability, but stream data can be split across paths.

### 46.2.2 Path Identifier

Each path is identified by a `Path ID`:

```
Path ID = (Connection ID, Address Pair)
- Path 0: Initial/default path
- Path 1, 2, 3: Additional paths
```

A connection always has at least Path 0.

## 46.3 PATH_CHALLENGE and PATH_RESPONSE Frames

Before using a new path, QUIC must validate it:

```
Endpoint A                                          Endpoint B
(New Path: A:9000 -> B:443)

   |--- PATH_CHALLENGE (random data) ------------->|
   |    Frame Type: 0x1e                            |
   |    Data: [8 bytes random]                      |
   |                                                |
   |<-- PATH_RESPONSE (echoed data) ----------------|
   |    Frame Type: 0x1f                            |
   |    Data: [8 bytes same data]                   |
   |                                                |
   |========= Path validated, can send data =======>|
```

PATH_CHALLENGE and PATH_RESPONSE verify:

1. The path is actually usable (reachability)
2. The peer is actually at that address (no spoofing)
3. NAT/mapping is stable enough (path is viable)

## 46.4 Packet Number Spaces on Multiple Paths

This is where multipath QUIC gets interesting. Each path has its own packet number space:

```
Path 0 (WiFi):
  +------------------+
  | PN Space 0       |
  | 1, 2, 3, 4, 5... |
  +------------------+

Path 1 (Cellular):
  +------------------+
  | PN Space 1       |
  | 1, 2, 3, 4, 5... |
  +------------------+
```

Key implications:

- **No ambiguity**: A packet number always refers to one path
- **Independent ACKs**: Each path acknowledges its own packets
- **Independent loss detection**: Each path runs its own recovery

## 46.5 Scheduling and Distribution

How does QUIC decide which path carries which data?

### 46.5.1 Packet Distribution Strategies

**Round Robin**: Distribute packets evenly across paths

```
Packet 1 -> Path 0
Packet 2 -> Path 1
Packet 3 -> Path 0
Packet 4 -> Path 1
```

**Weighted Fair Queue**: Based on path capacity

```
Path 0 (100 Mbps) -> 70% of packets
Path 1 (50 Mbps)  -> 30% of packets
```

**Low-Latency First**: Send latency-sensitive packets on fastest path

```
Video frames -> Path 0 (lower RTT)
ACKs         -> Path 1 (faster)
```

### 46.5.2 Scheduler Implementation

```c
typedef struct {
    quic_path_t *path;
    uint32_t packets_in_flight;
    double estimated_rtt;
    uint64_t bytes_queued;
} path_state_t;

// Scheduler selects path for next datagram
quic_path_t* select_path_for_datagram(quic_connection_t *conn,
                                       size_t datagram_size) {
    path_state_t *best = NULL;
    double best_score = 0;

    for (path_state_t *p = conn->paths; p != NULL; p = p->next) {
        // Score based on available capacity and RTT
        double score = (p->cwnd - p->bytes_in_flight) / p->estimated_rtt;

        if (score > best_score) {
            best_score = score;
            best = p;
        }
    }
    return best ? best->path : NULL;
}
```

## 46.6 Handling Path Failures

When a path degrades or fails:

```
Path 0 (WiFi) experiences severe degradation:
   - High packet loss
   - RTT spikes to 5000ms

QUIC's response:
1. Reduce Path 0 sending rate
2. Probe with PATH_CHALLENGE to verify
3. Shift traffic to Path 1 (Cellular)
4. If Path 0 recovers, gradually add traffic back
```

The `PATH_ABANDON` frame signals when a path is no longer needed:

```
Endpoint A                                          Endpoint B
   |                                                   |
   |--- PATH_ABANDON (Path ID 0) --------------------->|
   |    Frame Type: 0x1d                               |
   |    Path ID: 0                                     |
   |    Largest Acknowledged: 500                     |
   |    Error Code: 0 (no error, just switching)      |
   |                                                   |
```

## 46.7 Connection Migration vs. Multipath

These are related but distinct:

| Aspect            | Connection Migration    | Multipath QUIC                |
| ----------------- | ----------------------- | ----------------------------- |
| Purpose           | Survive network changes | Enhance throughput/resilience |
| Path count        | 1 active at a time      | Multiple simultaneously       |
| Active vs standby | Switch completely       | All active                    |
| Use case          | Mobile handoff          | Bonding, redundancy           |

Connection migration (Chapter 19) moves a connection from one path to another. Multipath QUIC uses multiple paths concurrently.

## 46.8 Security Considerations

### 46.8.1 Path Validation and Spoofing

An attacker could:

1. Send PATH_CHALLENGE from a spoofed address
2. Receive PATH_RESPONSE
3. Claim to own that address

**Mitigation**: QUIC requires PATH_RESPONSE to come from the same address that received PATH_CHALLENGE, and validates using the cryptographic handshake.

### 46.8.2 Connection ID Management

With multiple paths, you need multiple Connection IDs:

```
Path 0: CID = AAAAAAAA
Path 1: CID = BBBBBBBB
Path 2: CID = CCCCCC
```

Each CID is bound to the same cryptographic context via the Initial keys.

## 46.9 Comparison with Other Multipath Protocols

| Protocol       | Layer            | Approach                |
| -------------- | ---------------- | ----------------------- |
| MPTCP          | Transport (TCP)  | Subflow TCP connections |
| QUIC Multipath | Transport (QUIC) | Multiple QUIC paths     |
| SCTP           | Transport        | Multi-homing            |
| LISP           | Network          | Tunneling               |

Multipath QUIC's advantage: it preserves QUIC's user-space deployment, encryption, and stream multiplexing while adding path diversity.

## 46.10 Implementation Status

As of 2024:

- **Linux kernel**: Initial multipath QUIC support in early development
- **Quinn** (Rust): Experimental multipath support
- **MsQuic**: Multipath work in progress
- **Apple**: Deployed multipath in some internal services

## 46.11 Summary

Multipath QUIC (RFC 9542) enables simultaneous use of multiple network paths:

- **PATH_CHALLENGE/PATH_RESPONSE** validate new paths
- **Separate packet number spaces** per path
- **Schedulers** distribute traffic based on capacity/latency
- **PATH_ABANDON** cleanly close unused paths
- **Security** through path validation and CID management

Multipath QUIC is particularly valuable for mobile applications, high-bandwidth scenarios, and applications requiring resilience against network failures. The combination of QUIC's user-space deployment and multipath capability enables deployment without OS kernel changes.
