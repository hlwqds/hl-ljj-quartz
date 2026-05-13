# Chapter 4: Version Negotiation

## 4.1 Why Version Negotiation Matters

Network protocols evolve. A client and server may speak different versions of QUIC. Rather than failing silently or breaking the connection, QUIC has a built-in version negotiation mechanism that allows endpoints to agree on a common version or cleanly determine they cannot communicate.

This is especially important given QUIC's user-space deployment model: different clients and servers may ship with different QUIC library versions at different times.

## 4.2 QUIC Versions: Version Field Encoding

Each QUIC packet's header contains a 32-bit version field. For IETF QUIC v1, this is `0x00000001`.

```
QUIC Version Field (32 bits):
  0x00000001  → QUIC v1 (RFC 9000)
  0x00000000  → Version 0 (special: used in Version Negotiation packet)
  0x?         → Future versions use other values
  0x?a?c?d?e  → Greased values (0x?a?c?d?e format, used for extensibility)
```

### Greased Versions

The QUIC spec reserves certain version numbers for "greasing" -- testing extensibility. Grease values follow the pattern `0x?a?c?d?e` where `?` is any hex digit, so `0x1a2c3d4e`, `0xfa0c5d6e`, etc. An endpoint that receives a greased version should respond with a Version Negotiation packet but MUST NOT retry the connection with the greased version -- this tests that the peer correctly handles unknown versions.

## 4.3 The Version Negotiation Packet

When a server (or client, in certain cases) receives a packet with a version it does not support, it responds with a **Version Negotiation (VN) packet**.

### VN Packet Format

The VN packet is a long header packet with version `0x00000000` and contains the list of versions the responder supports:

```
Long Header Packet (Header Form = 1, Version = 0x00000000):
  +------------------------------------+
  | Header Form = 1                    | (1 bit)
  | Reserved = 0                       | (1 bit)
  | DCID Len                          | (8 bits)
  | Destination Connection ID         | (variable)
  | SCID Len                          | (8 bits)
  | Source Connection ID              | (variable)
  | Supported Version 1                | (32 bits)
  | Supported Version 2                | (32 bits)
  | ...                                |
  +------------------------------------+
```

Note: The VN packet is **not encrypted**, because encryption keys have not been established yet. The server echoes back the client's Destination Connection ID (which proves the VN packet was generated in response to this client's packet, not a forged injection).

## 4.4 Version Negotiation During the handshake

### Client-Initiated Version Negotiation

The normal case: client sends an Initial packet with version v1, server supports only v2.

```
Client                                    Server
  |                                          |
  |  Initial (version=0x00000002)            |
  |  DCID=server's CID                        |
  |----------------------------------------→ |
  |                                          |
  |  Version Negotiation (version=0x00000000)|
  |  Supported: [0x00000001, 0x00000003]      |
  |  DCID echoed from client's packet         |
  |←---------------------------------------- |
  |                                          |
  |  [Client retries with supported version]  |
  |  Initial (version=0x00000001)            |
  |----------------------------------------→ |
```

**Critical:** The client MUST verify that the DCID in the VN packet matches what it sent. If not, the VN packet could be a forged injection and must be ignored.

**Critical:** After receiving VN, the client MUST NOT reuse the same Connection ID it originally chose. The spec says: "A client MUST reject any server response that contains a Version Negotiation packet that lists the Version field from any packet it is sending." This prevents a downgrade attack where an on-path attacker injects a VN packet with a subset of versions (removing the attacker's vulnerable version from the list).

### Client-Side Version Negotiation

A server receiving a packet with an unsupported version can send VN. But what if a client receives a packet with an unsupported version? In principle, clients don't listen for incoming connections (they only send), so this rarely applies. However, during connection migration (Chapter 5), a client might receive packets from a new path with a different version.

## 4.5 What Versions Are Currently Deployed

The dominant version in deployment is **QUIC v1** (`0x00000001`), standardized in RFC 9000. Draft versions (0xff00001 through 0xff0000d for various IETF drafts) were deployed during the standardization process but are now obsolete.

HTTP/3 is defined over QUIC v1 only.

## 4.6 Version Downgrade Attack Prevention

The version negotiation mechanism is a potential attack surface. An on-path attacker could:
1. Intercept the client's Initial packet
2. Inject a VN packet listing only a weak/vulnerable version
3. Client retries with the attacker's chosen version

**QUIC's defense:** The client's first Initial packet (in 0-RTT attempt) and the server's first response use the version the client chose, not the version in the VN packet. Additionally, the VN packet echoes the client's original DCID, allowing the client to verify it was a legitimate response.

**Further defense:** If the client receives a VN packet listing a version the client doesn't support, it MUST abort the connection attempt with `VERSION_GINGER_ERROR`. This prevents downgrade to a version neither side might support.

## 4.7 Practical Limitations

In practice, version negotiation has limitations:

1. **Middleboxes may drop unknown versions**: Some firewalls and NAT devices drop UDP packets with unknown QUIC versions, preventing VN from reaching the client.
2. **0-RTT complicates VN**: If a client sends 0-RTT data and receives VN, it must retry the 0-RTT, but the server may not have buffered the 0-RTT data.
3. **Latency cost**: VN adds at least 1 RTT to connection establishment (unless the client correctly guesses the server's supported version on the first try).

### Practical Version Selection Heuristics

QUIC clients typically use information from previous connections to the same server to select the version:

- Store the server's last-used QUIC version
- Try that version first (1-RTT or 0-RTT success)
- Fall back to v1 (`0x00000001`) if the stored version fails

## 4.8 GREASE QUIC Version (0x?a?c?d?e)

The IETF standardized "GREASE" for QUIC (borrowed from TLS's GREASE mechanism). Implementations SHOULD:

1. Send a greased version in some fraction of initial packets (to test middlebox behavior)
2. Accept VN packets with greased versions (and not retry with them)
3. Treat a peer responding with a greased VN as behaving correctly

This ensures the version negotiation mechanism remains tested and working as the protocol evolves.

## 4.9 Connection IDs and Version Negotiation

The Initial packet's Destination Connection ID (DCID) is used to derive the **Initial secrets**. The server's choice of SCID in its Initial packet becomes the client's DCID for subsequent packets.

During version negotiation, the DCID is echoed verbatim, so it carries over from the original client packet. This means version negotiation does not disrupt CID-based routing -- the client's original CID remains the routing key for any packets up to VN receipt.

## 4.10 Summary

QUIC's version negotiation is a proactive extensibility mechanism that allows endpoints to agree on a protocol version without complete connection failure. The VN packet is sent in response to an unsupported version, echoing the client's DCID for verification. The protocol includes downgrade attack defenses (VN must list the original version, client must reject mismatches) and GREASE support for extensibility testing. In practice, QUIC v1 dominates, but version negotiation ensures the protocol can evolve.
