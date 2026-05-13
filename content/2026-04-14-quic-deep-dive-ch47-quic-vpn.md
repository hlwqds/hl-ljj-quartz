# Chapter 47: QUIC VPN

## 47.1 Why QUIC for VPN?

Traditional VPN protocols have well-known limitations:

| Protocol          | Issues                                         |
| ----------------- | ---------------------------------------------- |
| PPTP              | Deprecated, insecure                           |
| OpenVPN           | TCP-based (head-of-line blocking), complex     |
| IPSec (transport) | Complex, OS-level integration                  |
| WireGuard         | Kernel module requirement, limited mobility    |
| TLS VPN           | TCP overhead, connection establishment latency |

QUIC as a VPN transport offers compelling advantages:

1. **User-space implementation** - No kernel modifications needed
2. **0-RTT reconnection** - Instant resume after network changes
3. **Connection migration** - Seamless WiFi/cellular handoff
4. **Multiplexing** - Multiple "connections" over one QUIC connection
5. **Encryption** - Built-in, strong cryptography via TLS 1.3

## 47.2 QUIC VPN Architecture

### 47.2.1 Tunneling Model

```
┌─────────────────────────────────────────────────────────┐
│                    QUIC VPN Architecture                │
│                                                         │
│  Device                                                 │
│  +--------------------------------------------------+   │
│  |  +----------+         +----------+              |   │
│  |  | TUN/TAP  | <────>  | QUIC     |              |   │
│  |  | Interface|         | Stack    |              |   │
│  |  +----------+         +----------+              |   │
│  |       ↑                     |                    |   │
│  |       │                     │ UDP               |   │
│  |       │                     ▼                    |   │
│  |  10.8.0.0/24          [Internet]                 |   │
│  +--------------------------------------------------+   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

The TUN/TAP interface presents a virtual network device to the operating system. IP packets written to the TUN interface are encapsulated in QUIC frames and sent to the VPN server.

### 47.2.2 Protocol Stack

```
Original Packet:
+-----------------+
| IP Header       |
+-----------------+
| TCP/UDP Header  |
+-----------------+
| Application     |
+-----------------+

Encapsulated in QUIC VPN:
+--------------------------------------------------+
| UDP Header                                       |
+--------------------------------------------------+
| QUIC Header (Long/Short)                         |
+--------------------------------------------------+
| CRYPTO Frame (for control)                       |
+--------------------------------------------------+
| DATAGRAM Frame (encapsulated original packet)    |
+--------------------------------------------------+
```

## 47.3 Encapsulation: TUN to QUIC

### 47.3.1 Sending Direction (Client -> Server)

```
1. OS routing layer sends packet to TUN interface
2. VPN client reads packet from TUN fd
3. Packet is queued for sending via QUIC
4. QUIC stack encapsulates packet in DATAGRAM frame
5. UDP socket sends QUIC packet to server
```

### 47.3.2 Receiving Direction (Server -> Client)

```
1. UDP socket receives QUIC packet
2. QUIC stack processes, decrypts
3. Extracts DATAGRAM frame payload (original IP packet)
4. Writes packet to TUN interface
5. OS networking stack processes normally
```

## 47.4 QUIC Frame Usage in VPN

### 47.4.1 DATAGRAM for Encapsulated Traffic

The `DATAGRAM` frame (RFC 9221) is ideal for VPN encapsulation:

```c
// Client: encapsulate IP packet in QUIC datagram
uint8_t ip_packet[1500];  // Raw IP packet from TUN
size_t pkt_len = read(tun_fd, ip_packet, sizeof(ip_packet));

quic_frame_t frame = {
    .type = 0x30,  // DATAGRAM with length
    .payload = ip_packet,
    .payload_len = pkt_len,
};

quic_send_frame(conn, &frame);
```

Benefits:

- No per-packet acknowledgments (efficient)
- Loss-tolerant (QoS can decide to drop or retransmit)
- Full packet encapsulation preserves IP semantics

### 47.4.2 STREAM for Control Channel

VPN control messages (authentication, configuration) use streams:

```
Stream 0: Control messages
  - Authentication requests
  - Configuration push (DNS servers, routes)
  - Keepalive

Stream 1-N: Data traffic (via DATAGRAM)
```

## 47.5 Connection Establishment Flow

```
Client                                                  Server
   |                                                       |
   |---[Initial: CRYPTO (ClientHello)]-------------------->|
   |      + ALPN: "quic-vpn"                               |
   |      + Token (for resumption)                        |
   |                                                       |
   |<--[Initial: CRYPTO (ServerHello)]--------------------|
   |      + Certificate                                    |
   |      + Config                                        |
   |                                                       |
   |---[Handshake: CRYPTO (finished)]-------------------->|
   |                                                       |
   |<--[Handshake: CRYPTO (finished)]--------------------|
   |                                                       |
   |---[1-RTT: STREAM (auth credentials)]---------------->|
   |                                                       |
   |<--[1-RTT: STREAM (config push)]----------------------|
   |       DNS: 10.8.0.1                                   |
   |       Routes: 0.0.0.0/0                               |
   |                                                       |
   |<== Tunnel Operational =>                              |
   |                                                       |
   |---[1-RTT: DATAGRAM (encapsulated IP)]--------------->|
   |---[1-RTT: DATAGRAM (encapsulated IP)]--------------->|
   |---[1-RTT: DATAGRAM (encapsulated IP)]--------------->|
```

## 47.6 0-RTT Resumption and VPN

One of QUIC's killer features for VPN: **0-RTT resumption**.

When a client reconnects (e.g., after network switch):

```
Client                                                  Server
   |                                                       |
   |---[Initial: CRYPTO + 0-RTT]-------------------------->|
   |      + Early Data: Authentication token             |
   |      + DATAGRAM: Encapsulated packets (queued)        |
   |                                                       |
   |<--[Initial: CRYPTO + 0-RTT]--------------------------|
   |                                                       |
   |<== Tunnel Resumed Immediately =>                       |
   |                                                       |
```

The client can send queued IP packets immediately, before the handshake completes. To the user, VPN reconnection is nearly instantaneous.

## 47.7 Connection Migration and Mobile Handoff

With QUIC's connection migration, a VPN connection survives network changes:

```
Timeline:
   WiFi:     |==== VPN Session =====|
   Cellular:                  |==== Migrated VPN Session ====|

During handoff:
   - Client detects WiFi signal weakening
   - Client starts cellular connection to same server
   - QUIC PATH_CHALLENGE/PATH_RESPONSE validates new path
   - Traffic shifts to cellular path
   - IP address changed (WiFi down, cellular up)
   - QUIC connection migrates seamlessly
```

No VPN re-authentication needed. The existing QUIC connection migrates to the new path.

## 47.8 Performance Characteristics

### 47.8.1 Overhead Comparison

| Protocol      | Encapsulation Overhead   | Connection Setup |
| ------------- | ------------------------ | ---------------- |
| WireGuard     | ~60 bytes/packet         | ~1 RTT           |
| OpenVPN (TCP) | ~50 bytes + TCP overhead | ~2-3 RTT         |
| OpenVPN (UDP) | ~50 bytes                | ~2-3 RTT         |
| QUIC VPN      | ~40-60 bytes             | 0-RTT or 1-RTT   |

### 47.8.2 Congestion Control

QUIC's congestion control applies to VPN traffic, which is both good and bad:

- **Good**: Prevents congestion collapse, fair behavior
- **Bad**: May be more conservative than raw UDP

Most QUIC VPN implementations expose congestion control tuning options.

## 47.9 Security Considerations

### 47.9.1 Threat Model

```
Eavesdropper (passive)          MITM (active)
      |                               |
      | <-- Encrypted QUIC ---------> | <-- Sees ciphertext only
      |                               |     (if TLS 1.3 + AEAD)
      |                               |
```

QUIC VPN inherits TLS 1.3's security properties:

- **Forward secrecy** (unless 0-RTT with resumption tokens)
- **Authentication** (certificate-based)
- **Encryption** (AES-GCM/ChaCha20-Poly1305)

### 47.9.2 0-RTT Replay Attacks

0-RTT data is vulnerable to replay attacks. VPN implementations should:

1. Use 0-RTT only for encapsulated data packets
2. Keep control channel on 1-RTT streams
3. Implement replay detection for auth tokens

## 47.10 Existing Implementations

### 47.10.1 Comparison

| Implementation                  | Language | Notes                           |
| ------------------------------- | -------- | ------------------------------- |
| masque (Apple)                  | C        | iOS/macOS built-in, proxy-style |
| quic-tun                        | Go       | Userspace QUIC, TUN interface   |
| quivpn                          | Rust     | Experimental                    |
| Outline (Shadowsocks over QUIC) | Go       | Based on QUIC                   |

### 47.10.2 Apple's MASQUE Proxy

Apple's implementation uses QUIC as a proxy protocol rather than full VPN:

```
Device                         Proxy                      Internet
   |                              |                            |
   |---[QUIC: CONNECT to google.com]-->|                     |
   |                              |                            |
   |<==[TCP connection tunnelled]==|                            |
   |                              |                            |
   |---[HTTP/3 over QUIC]---------|---->[HTTP/3 to origin]--->|
```

The proxy establishes the TCP connection to the origin, avoiding server-side IP leakage.

## 47.11 Deployment Considerations

### 47.11.1 NAT and Firewalls

QUIC VPN must handle NAT:

```
Symmetric NAT Problem:
  Client behind NAT: C:9000 -> NAT:45000 -> Server:443
  Server sees: NAT IP:45000

  If NAT mapping expires before connection closes:
    - QUIC heartbeats must keep mapping alive
    - Or connection migration/establishment on new mapping
```

### 47.11.2 MTU and Fragmentation

QUIC VPN encapsulation increases packet size:

- Original: 1500 bytes (typical Ethernet MTU)
- QUIC overhead: ~40-60 bytes (header + encryption)
- Total: ~1540-1560 bytes

VPN implementations should:

1. Advertise smaller MTU to TUN interface
2. Use Path MTU Discovery
3. Fragment if necessary (not ideal for performance)

## 47.12 Summary

QUIC VPN leverages QUIC's transport capabilities for virtual private networking:

- **DATAGRAM frames** encapsulate IP packets efficiently
- **STREAM frames** carry control channel traffic
- **0-RTT resumption** enables instant reconnection
- **Connection migration** provides seamless network handoff
- **User-space deployment** means no kernel modifications

The combination of QUIC's performance characteristics (low latency, multiplexing, encryption) with VPN tunnel semantics creates a compelling alternative to traditional VPN protocols. As QUIC adoption grows, expect QUIC-based VPN solutions to become more prevalent.
