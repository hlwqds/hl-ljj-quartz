# Chapter 4: SRv6 Origin - History and Motivation

## 4.1 Context: Why Extend SR to IPv6?

By 2012, Segment Routing had established its architectural foundations over MPLS. The IGP extensions, SID semantics, and traffic engineering capabilities were standardized and beginning to see deployment. Yet the architects recognized that MPLS, despite its widespread success, had fundamental limitations that would become increasingly problematic.

SRv6—Segment Routing over IPv6—emerged not as a replacement for SR-MPLS but as a complementary data plane that leveraged IPv6's capabilities to enable scenarios impossible with MPLS. The motivation was threefold: **programmability**, **scalability**, and **the inevitable transition to IPv6**.

## 4.2 Limitations of the MPLS Data Plane

### 4.2.1 Label Space Constraints

MPLS labels are 20 bits, limiting the label space to approximately 1 million values. While this seems large, enterprise-scale networks with extensive VPN deployments, VPLS instances, and traffic engineering contexts could approach these limits.

More critically, the label space required careful coordination. When VPN label 1000 appeared in a packet, its meaning depended entirely on context—which LSP carried the packet, which VRF on the receiving PE processed it. There was no self-contained meaning.

### 4.2.2 Inability to Encode Program Logic

The MPLS label's only semantics were "swap to this label" or "pop and forward." A transit router had no ability to inspect a label and determine what action should be taken beyond basic swapping. The intelligence resided entirely in the control plane's pre-programmed forwarding tables.

Consider a scenario where a network operator wanted packets to be processed differently at different hops:

- At R1: Apply encapsulation
- At R2: Copy DSCP to EXP
- At R3: Insert timestamp
- At R4: Count packet
- At R5: Decapsulate and forward

With MPLS, this was impossible without introducing complex signaling extensions or relying on proprietary mechanisms. The label could only say "swap to label X."

### 4.2.3 State Explosion in Large Domains

Each LSP required label state at every transit node. While SR's architecture eliminated per-LSP signaling (the path was encoded in the packet), the MPLS forwarding plane still maintained LFIB entries for each unique label encountered.

For networks with millions of flows traversing diverse paths, the aggregate LFIB state could become substantial—not prohibitive, but meaningfully different from stateless forwarding.

## 4.3 IPv6 as the Foundation for Network Programming

### 4.3.1 IPv6 Header Simplicity

IPv6's basic header is elegantly simple: 40 bytes containing source and destination addresses (128 bits each), version, payload length, next header, hop limit, and traffic class. Critically, IPv6 uses extension headers for optional functionality—unlike IPv4's kitchen-sink options approach.

```
IPv6 Basic Header (40 bytes):
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |Version| Traffic Class |           Flow Label                  |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |         Payload Length        |  Next Header  |   Hop Limit   |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                                                               |
 |                                                               |
 |                         Source Address                        |
 |                                                               |
 |                                                               |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                                                               |
 |                                                               |
 |                      Destination Address                      |
 |                                                               |
 |                                                               |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

The IPv6 address is 128 bits—enormous compared to MPLS's 20-bit labels. This address space could encode rich semantics without constraint.

### 4.3.2 Extension Headers

IPv6's extension header chain allows optional functionality to be added without modifying the base header:

- **Hop-by-Hop Options (0)**: Processed at every hop
- **Destination Options (60)**: Processed at destination
- **Routing Header (43)**: Specifies route with arbitrary addresses
- **Fragment (44)**: Fragmentation information
- **Authentication Header (51)**: IPSec AH
- **ESP (50)**: IPSec ESP
- **Mobility (135)**: Mobile IPv6
- **Host Identity Protocol (139)**: HIP
- **Stream Control Transmission Protocol (140)**: SCTP
- **No Next Header (59)**: No subsequent header

The **Routing Header (RH)** was particularly relevant for early IPv6 source routing attempts—though initial specifications were deliberately limited due to security concerns.

## 4.4 Early IPv6 Source Routing Attempts

### 4.4.1 The Original Routing Header (RH0)

IPv6's original routing header, RH0, allowed a sender to specify an arbitrary list of intermediate nodes that a packet should traverse. This was essentially IPv6's equivalent of IPv4's strict source routing option.

```
RH0 Extension Header:
  Next Header (1 byte)
  Hdr Ext Len (1 byte)
  Routing Type (1 byte) = 0
  Segments Left (1 byte)
  Reserved (4 bytes)
  Address[1]
  Address[2]
  ...
  Address[n]
```

However, RH0 was deprecated in RFC 5095 due to security concerns—it could be exploited for traffic amplification and evasion of security devices. Attackers could spoof source addresses and force packets through arbitrary paths, bypassing access controls.

### 4.4.2 Why Segment Routing Succeeded Where RH0 Failed

Segment Routing's innovation was not in inventing source routing—early IPv6 and IPv4 already supported this in limited forms. SR's insight was recognizing that **source routing combined with a controlled, operator-managed SID space** provided security and operational benefits that ad-hoc routing headers could not.

Key differences:

| Aspect           | RH0 Source Routing          | SRv6 Segment Routing        |
|------------------|------------------------------|------------------------------|
| Address source   | Arbitrary, potentially attacker-controlled | Operator-allocated SID space |
| Path verification | None                         | IGP/BGP validation           |
| SID meaning      | Generic IPv6 address         | Programmed behavior (via SRH) |
| Scalability      | Poor (address explosion)    | Excellent (semantic compression) |
| Operational model | End-to-end, stateless       | Domain-based, distributed intelligence |

## 4.5 The SRH: Segment Routing Header

### 4.5.1 RFC 8754: IPv6 Segment Routing Header

RFC 8754 introduced the SRH (Segment Routing Header), a new Routing Header type designed for Segment Routing. The SRH encoded segment lists in a way that was secure, scalable, and programmable.

```
SRH Format:
  Next Header (1 byte): Type of next header
  Hdr Ext Len (1 byte): Header length in 8-byte units
  Routing Type (1 byte): 4 for SRH
  Segments Left (1 byte): Index of next segment
  Last Entry (1 byte): Index of last segment
  Flags (2 bytes): Various SRH flags
  Tag (2 bytes): Optional tag for traffic classification

  Segment List[]: Variable-length array of 128-bit IPv6 addresses
    Segment[0] (16 bytes): First segment
    Segment[1] (16 bytes): Second segment
    ...
    Segment[n] (16 bytes): Last segment
```

### 4.5.2 The Segments Left Pointer

The SRH's **Segments Left (SL)** field is the critical mechanism that enables sequential segment processing:

```
Packet with SRH containing [A, B, C] (3 segments):
  Segments Left = 2 (initially pointing to last)
  Destination Address = A (initial active segment)

Processing at node A:
  1. DA = A (matches local SID)
  2. SL = SL - 1 = 1
  3. DA = B (next segment)
  4. Forward to B

Processing at node B:
  1. DA = B (matches local SID)
  2. SL = SL - 1 = 0
  3. DA = C (next segment)
  4. Forward to C

Processing at node C:
  1. DA = C (matches local SID)
  2. SL = SL - 1 = -1 (no more segments)
  3. Process upper-layer header
```

This mechanism allows the SRH to specify a complete path while the IPv6 Destination Address carries the immediate next segment—a clean separation between path state (SRH) and active processing (DA).

### 4.5.3 Processing Behavior

When an SR-capable node receives a packet:

1. The node examines the Destination Address.
2. If the DA matches a local SID, the node executes the SID's behavior:
   - Decrement Segments Left
   - Update DA to next segment in SRH
   - Perform the SID's defined action
3. If the DA does not match a local SID, standard IPv6 forwarding applies.

## 4.6 SRv6 Design Principles

### 4.6.1 Three Fundamental Components

SRv6's architecture rests on three pillars:

1. **SRv6 Segment Identifier (SID)**: A 128-bit IPv6 address that identifies a segment. Unlike MPLS labels, the SID is a full IPv6 address with semantic meaning.

2. **SRv6 Segment Routing Header (SRH)**: Carries the segment list, specifying the path.

3. **SRv6 Endpoint Behavior**: The action a node takes when processing a SID.

### 4.6.2 The SRv6 SID as Network Programming Instruction

SRv6's revolutionary capability is that **the SID encodes both the location (which node) and the behavior (what action)**. An SRv6 SID is not merely an address—it's a program instruction executed at a specific location.

Consider a traditional network function chain: Firewall → WAN Optimizer → Router. In SR-MPLS, each function requires separate encapsulation and forwarding. In SRv6, each function is encoded as a behavior within a SID:

```
SRv6 SID for Firewall processing at node F1:
  FC00:0:1:100::1
  |________________||__|
        Locator      Function (End.B6.Encaps)

SRv6 SID for WAN Opt processing at node O1:
  FC00:0:2:200::1
  |________________||__|
        Locator      Function (End.B6.Encaps)

Full path: [FC00:0:1:100::1, FC00:0:2:200::1, Final.Destination]

At each segment:
- F1: Firewall processing, then forward to O1
- O1: WAN optimization, then forward to destination
```

## 4.7 Evolution Timeline

### 2012-2014: Concept Development

Cisco's engineers, led by Clarence Filsfils, began exploring IPv6-based Segment Routing as a complement to SR-MPLS. The key insight was that IPv6's 128-bit addresses provided sufficient space to encode not just locators but entire program instructions.

### 2015: IETF Draft Submissions

The SRv6 working group formed, submitting foundational drafts:

- **draft-filsfils-spring-srv6-network-programming**: Core SRv6 network programming concepts
- **draft-filsfils-spring-srv6 headers**: SRH specification
- **draft-filsfils-spring-ipv6-only**: SRv6 for IPv6-only domains

### 2016-2017: Experimental Deployments

Early SRv6 implementations emerged in Cisco's IOS-XR and Linux kernel. Testing focused on:

- Basic segment routing with SRH
- Endpoint behaviors (End, End.X, End.T)
- Microsegment (uSID) concepts

### 2018-2020: Standardization

Key RFCs emerged:

| RFC | Title | Year |
|-----|-------|------|
| RFC 8402 | Segment Routing Architecture | 2018 |
| RFC 8754 | IPv6 Segment Routing Header (SRH) | 2020 |
| RFC 8986 | SRv6 Network Programming | 2021 |

### 2021-Present: Production Deployment

Major carriers began SRv6 deployments, particularly in:

- China (China Mobile, China Telecom, China Unicom)
- Europe (Deutsche Telekom, Telecom Italia)
- Asia-Pacific

## 4.8 Motivation Summary: Why SRv6 Over SR-MPLS?

### 4.8.1 Programmability

SRv6 enables true network programming—the ability to specify arbitrary processing at any hop using SID behaviors. SR-MPLS could only forward; SRv6 can process.

### 4.8.2 IPv6 Integration

As IPv4 address exhaustion drove IPv6 adoption, SRv6 offered a native IPv6 segment routing solution. For operators building IPv6-only networks, SRv6 provided traffic engineering without requiring MPLS.

### 4.8.3 Simplified Operations

SRv6 eliminates the MPLS label stack entirely. Packets are native IPv6 with an SRH extension header—simpler to debug, easier to trace, and compatible with standard IPv6 tools.

### 4.8.4 End-to-End Visibility

SRv6 SIDs are IPv6 addresses, visible in standard IPv6 telemetry (NetFlow, IPFIX, sFlow). Path tracing requires only examining the SRH, not decoding label stacks.

### 4.8.5 Programmable OAM

SRv6 enables in-band OAM—telemetry data can be carried within the SID itself, allowing precise measurement of latency, loss, and jitter per segment without external probes.

## 4.9 Summary

This chapter traced SRv6's origins and motivations:

- **MPLS limitations**: 20-bit label space, inability to encode program logic, and state explosion motivated exploration of alternatives.

- **IPv6 advantages**: 128-bit addresses provided semantic richness, extension headers offered extensibility, and IPv6 adoption made it an attractive foundation.

- **RH0 lessons**: Early IPv6 source routing failed due to security issues; SR succeeded by combining source routing with controlled, operator-managed SID spaces.

- **SRH innovation**: RFC 8754's SRH provided a secure, scalable mechanism for encoding segment lists in IPv6 packets.

- **Programmability**: SRv6's key innovation was encoding not just location but behavior within SIDs, enabling true network programming.

The following chapter dissects the SRv6 SID structure in detail—its format, components, and the encoding schemes that enable SRv6's powerful programmability.

---

**References**

- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8986: SRv6 Network Programming
- RFC 8402: Segment Routing Architecture
- RFC 5095: Deprecation of Type 0 Routing Headers in IPv6
- RFC 8200: Internet Protocol, Version 6 (IPv6) Specification