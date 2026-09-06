# Chapter 1: What is QUIC?

## 1.1 A Brief History

QUIC (Quick UDP Internet Connections) is a transport layer protocol originally developed by Google engineers in 2012. It was designed to improve web performance by reducing connection establishment latency and solving head-of-line blocking problems inherent in TCP. Google deployed QUIC across its services (Chrome, YouTube, Search) before the IETF standardized it, culminating in RFC 9000 in 2021.

## 1.2 QUIC as a UDP-based Multiplexed Transport

QUIC runs over UDP, not TCP. This is a deliberate design choice: by building on UDP, QUIC implementations can bypass kernel-space networking, move protocol logic to user space, and get new features deployed without waiting for OS updates.

```
+-------------------+
|      HTTP/3       |
+-------------------+
|   QUIC (this      |
|    book covers)   |
+-------------------+
|       UDP         |
+-------------------+
|   IP Layer        |
+-------------------+
```

HTTP/3 is the application protocol that runs on top of QUIC. QUIC itself is a general-purpose transport protocol that can carry arbitrary byte streams, though in practice it's primarily used to carry HTTP/3 traffic.

## 1.3 The Core Problem QUIC Solves

### 1.3.1 TCP + TLS Connection Establishment

A conventional TCP + TLS connection requires multiple round trips before data can flow:

```
TCP Handshake:    SYN →            SYN+ACK ←         ACK →
TLS Handshake:    ClientHello →                    ← ServerHello, ...
                  [1 RTT]

Total: 2-3 RTTs before application data
```

1. SYN (client → server)
2. SYN+ACK (server → client)
3. ACK (client → server)
4. TLS ClientHello
5. TLS handshake exchanges
6. Application data

This is known as the "head-of-line blocking" problem extended across protocol layers. Each layer adds its own handshake, and neither can fully overlap with the other.

### 1.3.2 QUIC: 0-RTT or 1-RTT Connection Establishment

QUIC combines connection establishment and cryptographic handshake into a single phase:

```
QUIC Handshake:
  ClientHello + QUIC headers →      ← ServerHello + encrypted frames (1 RTT)
  Application data can follow immediately
```

With 0-RTT mode (when the client has previously connected), application data can be sent immediately on the first flight, no waiting required.

## 1.4 Stream Multiplexing Without Head-of-Line Blocking

TCP's stream abstraction is a single ordered byte pipeline. If packet N is lost, the entire connection stalls until N is retransmitted and received -- even if you don't care about packet N's data at all.

HTTP/1.1 tried to work around this by opening multiple TCP connections. HTTP/2 improved this with a single TCP connection carrying multiple interleaved HTTP/2 streams. But HTTP/2 still suffers from TCP head-of-line blocking: a lost TCP segment delays all HTTP/2 streams on that connection.

**QUIC fixes this at the transport layer.** QUIC provides independent streams. If one stream suffers a packet loss, only that stream pauses. Other streams continue uninterrupted:

```
Stream 1:  A A A A A A A (blocked waiting for lost packet)
Stream 2:  B B B B B B B (continues normally)
Stream 3:  C C C C C C C (continues normally)
```

Each QUIC stream is a separate ordered byte delivery channel, but streams do not block each other at the transport layer.

## 1.5 QUIC Feature Overview

| Feature                  | What QUIC Provides                                    |
| ------------------------ | ----------------------------------------------------- |
| Connection establishment | 0-RTT or 1-RTT (vs 2-3 RTT for TCP+TLS)               |
| Stream multiplexing      | Independent streams without HOL blocking              |
| Packet-level encryption  | Every QUIC packet is encrypted                        |
| Connection migration     | Client can change IP/port without dropping connection |
| Loss recovery            | Per-stream loss recovery, better RTT estimation       |
| Flow control             | Per-stream and connection-level flow control          |
| Version negotiation      | Built-in mechanism for protocol upgrades              |

## 1.6 RFC 9000 and the QUIC Family

The IETF published the QUIC standards as a suite of RFCs:

| RFC      | Subject                                            |
| -------- | -------------------------------------------------- |
| RFC 9000 | QUIC: A UDP-Based Multiplexed and Secure Transport |
| RFC 9001 | QUIC: TLS                                          |
| RFC 9002 | QUIC: Loss Detection and Congestion Control        |
| RFC 9003 | QUIC: Extensions for HTTP/3                        |
| RFC 9004 | QUIC: Datagram Extension                           |

This book focuses on RFC 9000 (the core protocol), with relevant coverage of RFC 9001 (TLS integration) and RFC 9002 (recovery).

## 1.7 What QUIC is Not

- **Not a replacement for TCP entirely.** QUIC uses UDP as its underlying datagram service, but implements reliable delivery, congestion control, and connection semantics itself.
- **Not the same as Google's original QUIC.** Google's QUIC (qlog/qbuf) differs in wire format, crypto, and behavior from the IETF standardized version.
- **Not just for HTTP.** While HTTP/3 is the dominant use case, QUIC's stream multiplexing can serve other application protocols. The extension for unreliable datagrams (RFC 9221) enables non-streamed use cases like DNS over QUIC.

## 1.8 Summary

QUIC is a UDP-based, multiplexed, secure transport protocol that eliminates the 2-3 RTT connection establishment penalty of TCP+TLS, removes stream-level head-of-line blocking, provides packet-level encryption, and enables connection migration. It is the transport for HTTP/3 and is designed for deployment in user space, enabling rapid protocol evolution without waiting for OS kernels.
