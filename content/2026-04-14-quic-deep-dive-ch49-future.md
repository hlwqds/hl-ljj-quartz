# Chapter 49: QUIC Future Directions

## 49.1 QUIC Evolution Model

QUIC was designed for extensibility. Unlike TCP (which lives in OS kernels), QUIC implementations live in user space, enabling:

1. **Rapid deployment** - No kernel updates needed
2. **Experimentation** - Easy to try new extensions
3. **Version flexibility** - Multiple QUIC versions can coexist
4. **Application-specific tuning** - Apps can customize behavior

This chapter explores active research areas, emerging extensions, and potential future developments.

## 49.2 Standardization Pipeline

### 49.2.1 Active IETF Working Groups

```
IETF 117 (July 2023):
  - QUIC Working Group active
  - Focus: Extensions and errata

Current extensions in progress:
  - QUIC Version Negotiation (clarified)
  - QUIC multicast (exploratory)
  - QUIC for realtime media (beyond datagrams)
  - QUIC Loss Bit (explicit loss notification)
```

### 49.2.2 RFC Roadmap

```
Already published:
  RFC 9000 - QUIC core
  RFC 9001 - QUIC-TLS
  RFC 9002 - Loss detection
  RFC 9003 - HTTP/3 extensions
  RFC 9004 - Datagrams
  RFC 9221 - Datagram extension (updated)
  RFC 9298 - Proxying QUIC

In progress:
  - QUIC version management
  - Multipath QUIC (RFC 9542)
  - QUIC load management
```

## 49.3 Loss Detection Improvements

### 49.3.1 Explicit Loss Notification (ELN)

Current QUIC requires PTO (Probe Timeout) to detect losses after a threshold. ELN proposes an explicit mechanism:

```
Current approach (PTO-based):
  Send packet #100
  Wait 3*RTT + max_ack_delay
  No ACK received -> assume lost, retransmit

With ELN:
  Send packet #100
  Receive ACK for #99 but NOT #100
  Peer sends EXPLICIT_LOSS(100) -> immediate retransmit
```

Benefits:
- Faster loss detection
- Less unnecessary retransmissions
- Better for asymmetric paths

Draft: draft-ietf-quic-eln

### 49.3.2 RTT Independence for ACK

Traditional ACK-based loss detection can be fooled by:
- Asymmetric paths (ACKs travel different route)
- Congestion on return path
- Bufferbloat on ACK path

Potential solutions:
- Separate ACK congestion control
- Path-probing for RTT asymmetry
- Hop-by-hop loss notification

## 49.4 Congestion Control Evolution

### 49.4.1 Beyond Cubic

Cubic has been TCP's default for 15+ years. QUIC implementations are experimenting:

```
Cubic:
  W(t) = C * (t - K)^3 + W_max
  Where K = (W_max * β / C)^(1/3)

BBR (Bottleneck Bandwidth and RTT):
  - Models bottleneck bandwidth and RTT
  - More aggressive exploration
  - Better for high-BDP networks

Copa (Congestion Avoidance with Principled Algorithms):
  - Exponential backoff when "behind"
  - Linear increase when "ahead"
  - Maintains target rate
```

QUIC's pluggable congestion control makes A/B testing straightforward.

### 49.4.2 Variable MTU Support

Current QUIC assumes ~1200-1500 byte MTU. Emerging work on:

- ** Jumbo frames** (9KB MTU) for data centers
- **Sub-1200 byte** for severely constrained links
- **MTU probing** to discover optimal packet size

```
MTU Probing Protocol:
  1. Start with safe 1200 byte packets
  2. Occasionally probe with larger packets
  3. If probe succeeds, increase MTU estimate
  4. If probe fails, decrease and blacklist path
```

## 49.5 Multipath Advancements

### 49.5.1 Coupled Congestion Control

Should paths share congestion state?

```
Uncoupled (current multipath):
  Path A: 10 Mbps, 50ms RTT
  Path B: 5 Mbps, 20ms RTT
  Total: 15 Mbps capacity, but...

Coupled:
  Path A and B share congestion window
  Aggregate throughput = min(sum capacity, single-stream fairness)

Coupled is more conservative but fairer to competing flows.
```

Research question: What's the right fairness model?

### 49.5.2 Heterogeneous Path Scheduling

Different paths have different characteristics:

```
Path A (WiFi): Low latency, variable bandwidth
  -> Best for: Interactive traffic (mouse clicks, video frames)

Path B (Cellular): Higher latency, stable bandwidth
  -> Best for: Bulk transfer, ACK delivery

Scheduler decides:
  - Which packet goes on which path
  - How to split real-time vs bulk traffic
  - When to probe new paths
```

## 49.6 Network Middlebox Interactions

### 49.6.1 QUIC's Battle with Middleboxes

QUIC's encrypted headers create challenges:

| Middlebox Behavior | QUIC Impact |
|--------------------|-------------|
| Stateful firewall tracking | May block after NAT reboot |
| Deep Packet Inspection | Can't see payload, may throttle |
| TLS interception | Breaks end-to-end encryption |
| Rate limiting | Can't determine app type |
| QoS marking | Can't prioritize by application |

### 49.6.2 GREASE Extensions

GREASE (Generate Random Extensions And Sustain Extensibility) was borrowed from TLS:

```
GREASE Type: 0x1a1a (or other GREASE values)

When middleboxes reject unknown values,
implementations can detect and work around:
- Replace unknown value with GREASE
- If it works, middlebox is the problem
- If it fails, server doesn't support it
```

### 49.6.3 Connection ID Management Evolution

CDID (Connection ID) practices are evolving:

```
Problem: Long-lived CIDs enable tracking across networks

Solutions under consideration:
1. Short-lived CIDs with frequent rotation
2. Zero-length CIDs for privacy-sensitive apps
3. CID proxying (like MASQUE)
4. Per-network CID binding
```

## 49.7 Application Integration

### 49.7.1 QUIC as a Library

TCP is a OS service. QUIC is increasingly a library:

```c
// Traditional
int sock = socket(AF_INET, SOCK_STREAM, 0);
connect(sock, ...);

// QUIC as library
quic_config_t config = {
    .tls_config = my_tls,
    .congestion_control = BBR,
    .max_datagram_size = 1200,
};
quic_conn_t *conn = quic_connect(&config, "example.com", 443);
```

Benefits:
- Application controls all transport behavior
- Easy to A/B test different configurations
- Ship transport improvements without OS updates

### 49.7.2 UDP Socket APIs (io_uring, etc.)

Kernel bypass for performance-critical QUIC:

```c
// io_uring for QUIC
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_send_zc(sqe, quic_fd, msg, len, MSG_ZEROCOPY);
io_uring_submit(&ring);

// Zero-copy transmission
// Reduces CPU overhead for high-throughput QUIC
```

### 49.7.3 HTTP/4 and Beyond

HTTP working group is already thinking past HTTP/3:

```
HTTP/3: QUIC as transport
HTTP/4?: Beyond request/response?

Possibilities:
- Bidirectional streams as first-class
- Native pub/sub messaging
- Integrated WebTransport improvements
- Zero-copy HTTP objects
```

## 49.8 Performance Frontiers

### 49.8.1 Kernel Bypass

For maximum performance, some QUIC implementations offer kernel bypass:

```
Userspace networking (DPDK, io_uring):
  - Packets go directly from app to NIC
  - No kernel involvement
  - Requires dedicated CPU cores
  - ~40-60% CPU savings for high throughput

QUIC + DPDK example:
  - Application calls quic_send()
  - Data copied to DPDK mbuf
  - NIC DMA directly from mbuf
  - RX: NIC DMA to mbuf, quic_recv() reads
```

### 49.8.2 Hardware Offload

```
Crypto offload:
  - AES-GCM/ChaCha20-Poly1305 on NIC
  - Reduces CPU overhead

Packet number offload:
  - NIC tracks PN counter
  - Reduces per-packet processing

MPTCP-like offload:
  - NIC manages path diversity
  - OS sees single "connection"
```

### 49.8.3确定性网络 (DetNet) Integration

Deterministic networking aims for bounded latency:

```
Traditional: "Best effort" with statistical guarantees
DetNet:      "Guaranteed" with deterministic bounds

QUIC + DetNet:
  - Traffic scheduling (like IEEE 802.1Qbv)
  - Explicit path reservation
  - Bounded jitter for real-time apps
```

## 49.9 Security Enhancements

### 49.9.1 Post-Quantum Cryptography

TLS 1.3 uses ECDHE for key exchange. Post-quantum alternatives:

```
Current (vulnerable to quantum computers):
  ECDH P-256 / X25519

Post-quantum candidates:
  Kyber (lattice-based)
  SIKE (isogeny-based) - recently broken
  HRSS (lattice-based)

Timeline:
  2024: NIST PQ standard expected
  2025-2026: Integration into TLS 1.4?
  2027+: QUIC implementations update
```

### 49.9.2 Certificate Compression

Current certificates can be 2-4KB. QUIC CRYPTO overhead impacts handshake:

```
Solutions:
1. Certificate compression (RFC 8879)
   - Brotli-compressed certificates
   - 30-50% size reduction

2. Certificate chain optimization
   - Fewer intermediate certs
   - Shorter chains where possible

3. Raw key blessings
   - Pre-authenticated keys
   - Skip certificate entirely
```

## 49.10 Ecosystem Growth

### 49.10.1 Implementation Landscape

```
Production QUIC implementations:
  - MsQuic (Microsoft, C)
  - Quinn (Rust)
  - ngtcp2 (C)
  - quiche (Rust, Cloudflare)
  - lsquic (C, LiteSpeed)
  - proton-bqe (C++, Proton)
  - apple/quic (Swift/C)

Experimental:
  - Google/quic (original Google QUIC)
  - mvfst (Facebook, Rust/C++)
  - quorum (Java)
```

### 49.10.2 QUIC in Emerging Networks

```
卫星网络 (Satellite):
  - High latency (600ms+)
  - High bandwidth
  - QUIC's recovery vs. long RTT

5G/6G Networks:
  - Ultra-low latency
  - Network slicing
  - QUIC for URLLC use cases

IoT/Constrained:
  - DTLS over QUIC?
  - QUIC-Lite for 6LoWPAN
  - Noise protocol integration
```

## 49.11 Research Areas

### 49.11.1 Active Measurement

```
QUIC enables better network measurement:
- Connection characteristics reveal path properties
- Packet timing reveals congestion state
- Handshake timing reveals middlebox behavior

Research questions:
- Can we detect congestion earlier?
- Can we predict path quality changes?
- Can we fingerprint applications?
```

### 49.11.2 Fairness Studies

```
QUIC vs. TCP fairness remains debated:

Scenario: QUIC flow + TCP flow competing
Expected: Equal bandwidth (TCP friendly)
Observed: Sometimes QUIC gets more

Reasons:
- Different congestion algorithms
- Different initial windows
- PTO differences

Ongoing research on "TCP friendliness" for QUIC
```

## 49.12 Summary

QUIC's future is bright and active:

**Standardization**:
- Multipath, Loss Bit, enhanced datagrams in progress
- Post-quantum crypto on the horizon

**Performance**:
- Kernel bypass, hardware offload maturing
- Deterministic networking integration

**Ecosystem**:
- Multiple production-quality implementations
- Deployment across major services

**Research**:
- Better congestion control models
- Network measurement applications
- Security and privacy enhancements

QUIC was designed to be extensible. The next decade will prove whether that design philosophy enables the protocol to evolve faster than the network landscape changes.

---

## Appendix: QUIC Version Reference

| Version | Hex | Status |
|---------|-----|--------|
| RFC 9000 | 0x00000001 | Standard (2021) |
| draft-34 | 0xff00001d | Historic |
| Google QUIC Q050 | 0x51303430 | Google's version |
| GREASE | 0x1a1a1a1a | Testing only |
