# Chapter 6: IPv6 Extension Headers - Foundation for SRv6

## 6.1 Overview

The IPv6 header structure is fundamentally different from IPv4. While IPv4 combines its basic header with options (which burden every packet), IPv6 separates core routing information from optional extension headers. This design provides extensibility without the performance penalty of parsing variable-length options in every packet. Understanding IPv6 extension headers is essential for understanding how the Segment Routing Header (SRH) operates, as the SRH is itself an IPv6 extension header.

This chapter examines the IPv6 extension header architecture, the mechanics of extension header chaining, and the specific extension headers that precede the SRH in the protocol stack.

## 6.2 IPv6 Header Structure

### 6.2.1 Basic IPv6 Header

The IPv6 basic header is a fixed 40 bytes, simpler than the variable-length IPv4 header:

```
+---------------------------------------------------------------+
| Version | Traffic Class |           Flow Label                |
+---------------------------------------------------------------+
|         Payload Length        |    Next Header    |   Limit   |
+---------------------------------------------------------------+
|                                                               |
|                       Source Address                          |
|                           (128 bits)                           |
|                                                               |
+---------------------------------------------------------------+
|                                                               |
|                    Destination Address                        |
|                           (128 bits)                           |
|                                                               |
+---------------------------------------------------------------+
```

Fields:

- **Version** (4 bits): IP version, always 6
- **Traffic Class** (8 bits): QoS/ DiffServ replacement
- **Flow Label** (20 bits): Flow identification
- **Payload Length** (16 bits): Size of packet data after header
- **Next Header** (8 bits): Type of next header (protocol or extension)
- **Hop Limit** (8 bits): TTL replacement
- **Source Address** (128 bits): Sender
- **Destination Address** (128 bits): Receiver (can be modified en route)

The fixed 40-byte basic header enables fast processing. Every intermediate router knows exactly where to find the Next Header field and can quickly determine what follows.

### 6.2.2 The Next Header Chain

IPv6's extensibility comes from the **Next Header** chain mechanism. Rather than having a variable-length options field in the base header, IPv6 uses a linked list of extension headers after the basic header:

```
+-------------------+     +-------------------+     +-------------------+
|   IPv6 Basic      | --> |  Extension HDR 1  | --> |  Extension HDR 2  |
|   Header          |     |  (Next Header=X)  |     |  (Next Header=Y)  |
+-------------------+     +-------------------+     +-------------------+
         |                                                   |
         v                                                   v
   +-------------------+                             +-------------------+
   |  Upper Layer      |                             |   Upper Layer     |
   |  (TCP/UDP/etc)    |                             |   (TCP/UDP/etc)   |
   +-------------------+                             +-------------------+
```

Each extension header contains a **Next Header** field that identifies what follows it. The chain terminates when a Next Header value indicates an upper-layer protocol (TCP=6, UDP=17, ICMPv6=58) or an unknown value.

### 6.2.3 Extension Header Order (RFC 8200)

RFC 8200 mandates a specific ordering for extension headers:

```
1. Hop-by-Hop Options (if present)
2. Destination Options (before routing header)
3. Routing (Segment Routing Header)
4. Fragment
5. Authentication Header (AH)
6. Encapsulating Security Payload (ESP)
7. Destination Options (final destination)
8. Upper Layer (TCP, UDP, etc.)
```

This ordering ensures that processing nodes can efficiently locate headers they need. The SRH, being a type of routing header, appears after Destination Options but before Fragment and ESP.

## 6.3 Hop-by-Hop Options Header

### 6.3.1 Purpose and Structure

The **Hop-by-Hop Options** header carries optional information that must be examined by every node along the path. While originally designed for router alerts and similar features, its use has expanded.

```
+---------------------------------------------------------------+
| Next Header | Hdr Ext Len |                                     |
+---------------------------------------------------------------+
|                                                               |
|                      Options                                 |
|                  (variable length)                            |
|                                                               |
+---------------------------------------------------------------+
```

- **Next Header** (8 bits): Protocol identifier of next header
- **Hdr Ext Len** (8 bits): Length of the extension header in 8-byte units, not including first 8 bytes
- **Options** (variable): One or more type-length-value (TLV) options

### 6.3.2 Option Format

Each option in the Hop-by-Hop Options header uses TLV encoding:

```
+---------------------------------------------------------------+
| Option Type     | Opt Data Len |       Option Data            |
+---------------------------------------------------------------+
| 1 byte          | 1 byte       |       variable               |
```

Option types use bit 0 and bit 1 for processing behavior:

- **Bit 0** (0x80): Skip this option if unrecognized
- **Bit 1** (0x40): Forward this option even if not processed locally

### 6.3.3 Router Alert Option

The **Router Alert** option (Type=5, RFC 2711) is used by RSVP and multicast protocols to alert routers that the packet contents require processing:

```
Option Type = 0x05 (100 in binary: 01 = skip, 00 = action required)
Option Length = 0x02
Option Data = 0x0000 (RSVP) or other protocol identifier
```

When a router sees the Router Alert, it examines the packet contents rather than simply forwarding. This is relevant for SRv6 because some implementations use router alert mechanisms during processing.

## 6.4 Destination Options Header

### 6.4.1 Purpose

The **Destination Options** header carries information intended only for the destination node(s). Unlike Hop-by-Hop options, intermediate routers do not process destination options.

Two placement positions exist:

1. **Before Routing header**: Options to be processed by intermediate destinations specified in the routing header
2. **After Routing header (or if no routing header)**: Options for the final destination only

### 6.4.2 Structure

The structure is identical to Hop-by-Hop Options:

```
+---------------------------------------------------------------+
| Next Header | Hdr Ext Len |                                     |
+---------------------------------------------------------------+
|                                                               |
|                      Options                                 |
|                  (variable length)                            |
|                                                               |
+---------------------------------------------------------------+
```

## 6.5 Routing Header (Type 0)

### 6.5.1 Original IPv6 Routing Header (RFC 3515)

Before SRv6, IPv6 defined the **Routing Header** (RH0, RH-Type 0) for source routing. RH0 allowed a sender to specify a list of intermediate nodes the packet should visit:

```
+---------------------------------------------------------------+
| Next Header | Hdr Ext Len |  Routing Type | Segments Left    |
+---------------------------------------------------------------+
|                                                               |
|                     Reserved                                 |
|                                                               |
+---------------------------------------------------------------+
|                                                               |
|                    Address[1]                                |
|                                                               |
+---------------------------------------------------------------+
|                                                               |
|                    Address[2]                                |
|                                                               |
+---------------------------------------------------------------+
|                              ...                              |
+---------------------------------------------------------------+
|                                                               |
|                    Address[n]                                |
|                                                               |
+---------------------------------------------------------------+
```

- **Routing Type**: 0 for RH0
- **Segments Left**: Number of hops remaining before reaching the final destination
- **Address[n]**: Intermediate nodes to visit

### 6.5.2 RH0 Security Issues

RH0 was deprecated in RFC 5095 due to security concerns:

1. **Traffic amplification**: Attackers could use RH0 to reflect traffic through third parties
2. **Bypass of access controls**: Packets could be routed around firewall policies
3. **Privacy concerns**: Source addresses could be spoofed through reflection

The deprecation of RH0 paved the way for SRv6's controlled approach to source routing through the SRH.

## 6.6 Fragment Header

### 6.6.1 IPv6 Fragmentation Model

IPv6 mandates **path MTU discovery** (PMTUD) for proper operation. Endpoints must discover the maximum transmission unit along their path before sending packets larger than the minimum IPv6 MTU (1280 bytes).

However, fragmentation can still occur:

- From the source node (for packets exceeding path MTU)
- By intermediate nodes in special cases (fragmentation after tunnel endpoints)

### 6.6.2 Fragment Header Structure

```
+---------------------------------------------------------------+
| Next Header | Reserved  |  Fragment Offset   |  Res  | M Flag |
+---------------------------------------------------------------+
|                      Identification                           |
+---------------------------------------------------------------+
```

- **Next Header**: Protocol of the fragmentable part
- **Fragment Offset**: Position of this fragment in 8-byte units
- **M Flag**: 1 = more fragments follow, 0 = last fragment
- **Identification**: Unique value for this packet (for reassembly)

### 6.6.3 Fragment Interaction with SRH

Fragmentation and SRv6 interact in important ways:

1. **SRH is in the unfragmentable part**: The basic IPv6 header and all extension headers up to and including the SRH must fit in the path MTU
2. **Inner packet can be fragmented**: The payload after SRH processing may be fragmented independently
3. **Fragments lack SRH context**: Reassembly must occur before SRH processing continues

## 6.7 Authentication Header (AH) and ESP

### 6.7.1 AH Structure

The **Authentication Header** (AH, RFC 4302) provides integrity and authentication for IP packets:

```
+---------------------------------------------------------------+
| Next Header | Payload Len |          Reserved                 |
+---------------------------------------------------------------+
|                      Security Parameters Index (SPI)          |
+---------------------------------------------------------------+
|                      Sequence Number                          |
+---------------------------------------------------------------+
|                                                               |
|                    Authentication Data                        |
|                    (variable length, multiple of 32 bits)     |
|                                                               |
+---------------------------------------------------------------+
```

AH protects the immutable parts of the IPv6 header plus extension headers. However, some fields (like Hop Limit) are excluded because they change in transit.

### 6.7.2 ESP Structure

The **Encapsulating Security Payload** (ESP, RFC 4303) provides confidentiality, integrity, and authentication:

```
+---------------------------------------------------------------+
|                      Security Parameters Index (SPI)          |
+---------------------------------------------------------------+
|                      Sequence Number                          |
+---------------------------------------------------------------+
|                                                               |
|                    Payload Data (variable)                    |
|                                                               |
+---------------------------------------------------------------+
|                    Padding (0-255 bytes)                      |
+---------------------------------------------------------------+
|                  Pad Length    |  Next Header                  |
+---------------------------------------------------------------+
|                                                               |
|                    Authentication Data                        |
|                                                               |
+---------------------------------------------------------------+
```

### 6.7.3 SRH Security Considerations

When SRH is used with IPsec:

1. **AH and SRH conflict**: AH integrity covers extension headers, but SRH is modified at each segment (Segments Left decremented, DA updated)
2. **ESP and SRH**: ESP encrypts the payload; SRH remains visible for routing
3. **Transport vs Tunnel mode**: Affects which headers are protected

SRv6 typically operates in **transport mode** with the SRH outside ESP protection, allowing mid-path modification while keeping the payload confidential.

## 6.8 Upper Layer Headers

### 6.8.1 TCP (Protocol 6)

TCP follows extension headers when indicated by Next Header = 6:

```
+---------------------------------------------------------------+
|        Source Port          |       Destination Port          |
+---------------------------------------------------------------+
|                       Sequence Number                          |
+---------------------------------------------------------------+
|                    Acknowledgment Number                       |
+---------------------------------------------------------------+
| Offset | Reserved  | Flags |        Window Size                |
+---------------------------------------------------------------+
|                  Checksum             |   Urgent Pointer       |
+---------------------------------------------------------------+
```

### 6.8.2 UDP (Protocol 17)

UDP follows extension headers when Next Header = 17:

```
+---------------------------------------------------------------+
|        Source Port          |       Destination Port          |
+---------------------------------------------------------------+
|           Length            |           Checksum             |
+---------------------------------------------------------------+
```

### 6.8.3 Upper Layer Checksum Calculation

When IPv6 extension headers are present, the pseudo-header checksum includes the **final destination address** (after all routing), not the initial source. This is particularly relevant for SRv6 where the DA changes at each segment.

## 6.9 Extension Header Processing Rules

### 6.9.1 Intermediate Node Processing

When an intermediate node receives an IPv6 packet with extension headers:

1. **Parse basic header**: Extract Next Header, identify extension header type
2. **Process Hop-by-Hop if present**: Examine router alert options
3. **Check routing header**: If routing header present, update DA and Segments Left
4. **Forward packet**: Based on DA, continue to next header

The key point: intermediate nodes process only the extension headers necessary for forwarding. They do not process destination options, fragment headers, AH, or ESP (except for ESP tunnel mode decapsulation).

### 6.9.2 Final Destination Processing

The final destination must process all extension headers:

1. **Process in order**: Hop-by-Hop → Destination Options → Routing → Fragment → AH/ESP → Upper Layer
2. **Skip unrecognized options**: Per option type bits
3. **Deliver to upper layer**: After processing all headers

### 6.9.3 Unknown Extension Headers

RFC 8200 specifies that unknown extension headers should be processed as follows:

- If the node is the final destination: process the header
- If the node is NOT the final destination: skip over it and continue

This ensures forward compatibility—new extension headers can be introduced without breaking existing routers.

## 6.10 SRH as an Extension Header

### 6.10.1 SRH Position in the Stack

The **Segment Routing Header** (SRH) is defined in RFC 8754 and is the IPv6 extension header that carries the segment list for SRv6. It is:

- **A routing header type** (specifically Routing Type 4)
- **Placed after Destination Options** but before fragment-related headers
- **Processed by every node** along the path (unlike destination-only options)

### 6.10.2 SRH Relationship to Other Headers

```
IPv6 Basic Header (Next Header = Routing Header)
  |
  v
Destination Options Header (Next Header = SRH)
  |
  v
SRH (Next Header = Upper Layer Protocol, e.g., TCP/6)
  |
  v
Upper Layer (TCP, UDP, etc.)
```

### 6.10.3 Why SRH Uses Extension Header Mechanism

SRv6 leverages IPv6 extension headers for several reasons:

1. **Standardized mechanism**: No new packet structure needed; follows IPv6 architectural patterns
2. **Router compatibility**: Existing IPv6 routers understand extension header processing
3. **PMTUD integration**: Extension headers are part of the path MTU calculation
4. **Chain parsing**: The Next Header mechanism enables clean header chain traversal
5. **Hardware support**: Many forwarding chips already parse IPv6 extension headers

## 6.11 Summary

This chapter established the IPv6 extension header foundation necessary for understanding SRv6:

- **IPv6 basic header**: Fixed 40-byte structure with Next Header chain mechanism
- **Extension header chain**: Linked list of optional headers, each with Next Header pointer
- **Header ordering**: RFC 8200 mandates specific order; SRH follows Destination Options
- **Hop-by-Hop Options**: Processed by every node; used for router alert and path-specific options
- **Destination Options**: Processed only by destination(s); SRH precedes it in the chain
- **Routing Header (RH0)**: Original IPv6 source routing; deprecated for security reasons
- **Fragment Header**: For packet reassembly; SRH must fit within path MTU unfragmented
- **AH/ESP**: Security headers; SRH operates in transport mode outside IPsec protection
- **SRH positioning**: SRH is routing header type 4; processed at each segment

With this foundation, Chapter 7 will examine the detailed structure of the SRH itself.

---

**References**

- RFC 8200: Internet Protocol Version 6 (IPv6) Specification
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 5095: Deprecation of Type 0 Routing Headers in IPv6
- RFC 2711: IPv6 Router Alert Option
- RFC 4302: IP Authentication Header (AH)
- RFC 4303: Encapsulating Security Payload (ESP)
- RFC 8986: SRv6 Network Programming
