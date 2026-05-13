# Chapter 7: SRH Structure and Fields - The Segment Routing Header

## 7.1 Overview

The **Segment Routing Header** (SRH) is the IPv6 extension header that carries the segment list for SRv6. Defined in RFC 8754, the SRH enables source routing in IPv6 networks by specifying an ordered list of segments that packets must traverse. This chapter dissects the SRH structure, field-by-field analysis, segment list encoding, and the mechanics of segment processing.

The SRH transforms IPv6 from a pure destination-based routing protocol into a programmable data plane where the source dictates the explicit path through the network.

## 7.2 SRH Overview

### 7.2.1 What is the SRH?

The SRH is an IPv6 extension header of type **Routing Header Type 4**. It contains:

1. A **segment list**: Ordered list of IPv6 addresses representing segments
2. **Segmentation metadata**: Information about the current position in the segment list
3. **Optional TLVs**: Additional information for processing

When a packet with an SRH arrives at a node, the node:

1. Examines the **Segments Left** field to determine its role
2. If Segments Left > 0: processes the current segment and advances
3. If Segments Left = 0: this is the final destination; strip SRH and deliver to upper layer

### 7.2.2 SRH in the IPv6 Header Chain

```
+-------------------+     +-------------------+     +-------------------+
|   IPv6 Basic      | --> |  SRH              | --> |  Upper Layer     |
|   Header          |     |  (Routing Type 4) |     |  (TCP/UDP/etc)   |
+-------------------+     +-------------------+     +-------------------+
         |                        |
         v                        v
   DA = first segment       Segments Left
   Segments Left = n        decremented at
                          each segment
```

The IPv6 basic header's **Next Header** field points to the SRH. The SRH's **Next Header** field points to the upper-layer protocol (TCP, UDP, etc.).

## 7.3 SRH Format

### 7.3.1 Full SRH Structure

```
+---------------------------------------------------------------+
|  Next Header   |  Hdr Ext Len  |  Routing Type | Segments Left |
+---------------------------------------------------------------+
|      Last Entry      |       Flags         |    Reserved       |
+---------------------------------------------------------------+
|                                                               |
|                                                               |
|                      Segment List[0]                          |
|                        (128 bits)                             |
|                                                               |
+---------------------------------------------------------------+
|                                                               |
|                                                               |
|                      Segment List[1]                          |
|                        (128 bits)                             |
|                                                               |
+---------------------------------------------------------------+
|                              ...                               |
+---------------------------------------------------------------+
|                                                               |
|                                                               |
|                      Segment List[n]                          |
|                        (128 bits)                             |
|                                                               |
+---------------------------------------------------------------+
|                                                               |
|                    Optional TLVs (variable)                   |
|                                                               |
+---------------------------------------------------------------+
```

### 7.3.2 Field Descriptions

| Field | Bits | Description |
|-------|------|-------------|
| Next Header | 8 | Protocol identifier of header following SRH (TCP=6, UDP=17) |
| Hdr Ext Len | 8 | Length of SRH in 8-byte units, not including first 8 bytes |
| Routing Type | 8 | **4** for Segment Routing Header (RFC 8754) |
| Segments Left | 8 | Number of segments remaining to be processed |
| Last Entry | 8 | Index of last element in segment list (array-style) |
| Flags | 16 |SRH flags for various control functions |
| Reserved | 16 | Must be zero; for future use |
| Segment List | 128×n | Array of 128-bit IPv6 addresses |

### 7.3.3 Hdr Ext Len Calculation

The **Hdr Ext Len** field encodes the length of the SRH excluding the first 8 bytes:

```
Hdr Ext Len = (total_srh_length - 8) / 8
```

For a segment list of n segments (indexed 0 to n):

```
total_srh_length = 8 + (n × 16) + TLV_length
Hdr Ext Len = n × 2 + (TLV_length / 8)
```

Example: 3 segments, no TLVs:
```
Hdr Ext Len = 3 × 2 = 6 (48 bytes total for segment list)
Total SRH length = 8 + 48 = 56 bytes
```

## 7.4 Segment List Encoding

### 7.4.1 Segment List Order

The **segment list is encoded in reverse order**. The first segment the packet will visit is at **Segment List[Last Entry]**, and the last segment is at **Segment List[0]**.

This counterintuitive encoding optimizes processing:

1. The packet's initial DA is set to the first segment to visit
2. As each segment is processed, the DA is updated to the next entry
3. When Segments Left reaches 0, the DA equals the original destination

```
Segment List[0] = Final destination (SRv6 SID of last segment)
Segment List[1] = Second-to-last segment
...
Segment List[Last Entry] = First segment to visit
```

### 7.4.2 Example: Three-Segment Path

Consider path: R1 → R2 → R3 → R4 (where R4 is the ultimate destination)

```
Segment List[0] = R4's SID (final destination)
Segment List[1] = R3's SID (second segment)
Segment List[2] = R1's SID (first segment - Last Entry = 2)
Segments Left = 3
```

Initial packet state:
- DA = Segment List[Segments Left - 1] = Segment List[2] = R1
- Segments Left = 3

Processing at R1:
- Decrement Segments Left to 2
- Update DA to Segment List[Segments Left - 1] = Segment List[1] = R3
- Forward to R3

Processing at R3:
- Decrement Segments Left to 1
- Update DA to Segment List[Segments Left - 1] = Segment List[0] = R4
- Forward to R4

Processing at R4:
- Segments Left = 0 (final destination)
- Strip SRH
- Process upper layer

### 7.4.3 Segment List Diagram

```
Segment List[Last Entry]                    <- First segment to visit (DA initially)
Segment List[Last Entry - 1]                 <- Second segment
...
Segment List[1]                              <- Second-to-last segment
Segment List[0]                              <- Final destination

                    Processing Flow

Packet arrives at Segment List[Segments Left - 1]
    |
    v
Decrement Segments Left
Update DA to Segment List[Segments Left - 1]
Forward
```

## 7.5 Segments Left and Last Entry

### 7.5.1 Segments Left

**Segments Left** indicates how many segments remain to be processed before reaching the final destination. It is decremented at each SRv6 node before the packet is forwarded.

Processing pseudocode:

```
if Segments Left > 0:
    DA = Segment[Segments Left - 1]
    Segments Left = Segments Left - 1
    Forward packet
else:
    Strip SRH
    Deliver to upper layer
```

### 7.5.2 Last Entry

**Last Entry** contains the index of the last element in the segment list. For a segment list with n elements (indices 0 through n-1), Last Entry = n - 1.

```
Last Entry = len(segment_list) - 1
```

This field enables efficient parsing:

1. The parser knows exactly where the segment list begins (right before Last Entry)
2. No sentinel value needed to find the end
3. TLVs (if present) follow the segment list

### 7.5.3 Relationship Between Fields

```
Initial packet preparation:
    Last Entry = n - 1
    Segments Left = n

At each segment:
    Segments Left = Segments Left - 1

At final destination (Segments Left = 0):
    DA = Original destination
```

## 7.6 SRH Flags

### 7.6.1 Flag Field Structure

The 16-bit **Flags** field in the SRH is structured as follows:

```
+---------------------------------------------------------------+
|   Tag (8 bits)      |    Flags (8 bits)                       |
+---------------------------------------------------------------+

Flag bits (from MSB to LSB):
  0                   7
  +---+---+---+---+---+---+---+---+
  |TLV|TLV|   |   |   |   |   |   |
  |CM |CA |   |   |   |   |   |   |
  +---+---+---+---+---+---+---+---+
```

### 7.6.2 Tag (8 bits)

The **Tag** field provides a way to group packets belonging to the same traffic flow or service. Packets with the same Tag can be processed similarly.

Use cases:
- Service-level grouping (e.g., all packets for a specific VPN)
- OAM packet identification
-流量工程分组标记

### 7.6.3 Flag Bits

**TLV-CM** (bit 0): Critical TLV present in SRH
**TLV-CA** (bit 1): Critical TLV present in the next-to-last segment

**Note**: RFC 8754 originally defined these flags for TLV signaling. The interpretation and use of these flags has evolved in practice.

### 7.6.4 Additional Flags

The remaining flag bits are reserved for future use. Implementations must ignore unknown flags and preserve them unchanged.

## 7.7 Optional TLVs

### 7.7.1 TLV Overview

Type-Length-Value (TLV) options can be appended after the segment list. TLVs carry additional metadata for processing, such as:

- HMAC authentication
- OAM information
- Path validation
- Service function chaining parameters

### 7.7.2 TLV Format

```
+---------------------------------------------------------------+
|     Type      |    Length     |           Value               |
+---------------------------------------------------------------+
|    8 bits     |    8 bits     |       variable length          |
+---------------------------------------------------------------+
```

### 7.7.3 TLV Types

RFC 8754 defines several TLV types:

| Type | Name | Description |
|------|------|-------------|
| 1 | PAD1 | Single-byte padding |
| 2 | PADN | Variable-length padding |
| 4 | HMAC | Authentication data |

### 7.7.4 PAD1 TLV

The **PAD1** TLV is a single-byte option used for alignment and padding:

```
Type = 0x00
Length = 0x00 (no Length field for PAD1)
```

### 7.7.5 PADN TLV

The **PADN** TLV pads the SRH to an 8-byte boundary:

```
Type = 0x01
Length = Variable (padded bytes to skip)
Value = 0x00 (repeated Length times)
```

### 7.7.6 HMAC TLV

The **HMAC** TLV provides integrity protection for the SRH:

```
Type = 0x04
Length = 40
Value:
  +---------------------------------------------------------------+
  |  Key ID (32 bits)      |  Reserved (32 bits)                    |
  +---------------------------------------------------------------+
  |                                                                   |
  |                     HMAC (256 bits)                               |
  |                                                                   |
  +---------------------------------------------------------------+
```

HMAC computation covers the mutable parts of the SRH and IPv6 header.

## 7.8 SRH Processing Mechanics

### 7.8.1 Packet Arrival

When a node receives an IPv6 packet with an SRH:

```
1. Parse IPv6 basic header
2. Next Header = 43 (SRH)
3. Parse SRH:
   - Verify Routing Type = 4
   - Extract Segments Left
   - Extract Last Entry
   - Locate Segment List
```

### 7.8.2 Segment Processing

```
if Segments Left > 0:
    # This node is a transit segment
    next_segment = Segment_List[Segments_Left - 1]
    DA = next_segment
    Segments_Left = Segments_Left - 1
    
    # Optional: process TLVs
    # Optional: update flags
    # Optional: update HMAC if present
    
    Forward packet based on new DA
else:
    # This node is the final destination
    Strip SRH (or keep if services require)
    Process upper layer (TCP/UDP/etc.)
```

### 7.8.3 DA Update Process

The **Destination Address** in the IPv6 header is updated at each segment:

```
Original DA is preserved somewhere for reference
New DA = Segment_List[Segments_Left - 1] (after decrement)
```

This ensures that at each hop, the packet is routed toward the next segment in the path.

## 7.9 SRH Size Calculations

### 7.9.1 Minimum SRH Size

The minimum SRH contains only the 8-byte fixed header with zero segments:

```
8 bytes (minimum SRH)
Hdr Ext Len = 0
No segment list
Segments Left = 0
```

This is a valid SRH for packets without explicit segment requirements (just to signal SRv6 capability).

### 7.9.2 SRH with Segments

For n segments:

```
SRH size = 8 + (n × 16) + TLV_size
Hdr Ext Len = (n × 2) + (TLV_size / 8)
```

| Segments | Min Size (bytes) | Hdr Ext Len |
|----------|-----------------|--------------|
| 0 | 8 | 0 |
| 1 | 24 | 2 |
| 2 | 40 | 4 |
| 3 | 56 | 6 |
| 5 | 88 | 10 |
| 10 | 168 | 20 |

### 7.9.3 Path MTU Considerations

The SRH, like all extension headers, must fit within the path MTU as an unfragmentable unit. This means:

1. **Before SRH processing**: The SRH must be within path MTU
2. **After encapsulation**: New outer headers may require additional MTU consideration
3. **Fragmentation**: If SRH exceeds path MTU, the packet cannot be forwarded

Typical deployment: ensure path MTU of at least 1280 bytes (IPv6 minimum) plus SRH overhead.

## 7.10 Multiple SRH Handling

### 7.10.1 Stacked SRH

Multiple SRH headers can be stacked when services require multiple levels of segmentation:

```
+-------------------+     +-------------------+     +-------------------+
|   IPv6 Basic      | --> |  SRH (outer)      | --> |  SRH (inner)      |
|   Header          |     |  (coarse path)    |     |  (fine-grained)   |
+-------------------+     +-------------------+     +-------------------+
         |                        |                        |
         v                        v                        v
   DA = first coarse          DA = fine              Upper Layer
   segment                  segment
```

Use cases:
- Inter-AS SRv6 with per-domain segments
- Service function chaining with multiple policies
- Traffic engineering with hierarchy

### 7.10.2 Next Header Chaining

Each SRH's **Next Header** points to the next header:

```
IPv6 Basic Header:
    Next Header = 43 (SRH #1)

SRH #1:
    Next Header = 43 (SRH #2)
    Hdr Ext Len points to end of SRH #1

SRH #2:
    Next Header = 6 (TCP)
    Hdr Ext Len points to end of SRH #2
```

### 7.10.3 Processing Stacked SRH

Processing follows the same logic but continues through multiple SRH headers:

```
at node:
    if current SRH Segments Left > 0:
        process current SRH
    else:
        if current SRH Next Header = 43 (another SRH):
            switch to next SRH
            process it
        else:
            deliver to upper layer
```

## 7.11 SRH Comparison with RH0

### 7.11.1 Similarities

- Both are IPv6 extension headers (Routing Type)
- Both use Segments Left mechanism
- Both update DA at each hop
- Both allow source-specified path

### 7.11.2 Differences

| Aspect | RH0 (Deprecated) | SRH |
|--------|-----------------|-----|
| Routing Type | 0 | 4 |
| Security | Insecure (amplification) | Controlled via HMAC TLV |
| Transparency | Full header reversal | Preserves segment order |
| Processing | Pure source routing | Programmable via behaviors |
| Extensibility | Fixed format | TLV-based extensibility |
| Standardization | RFC 3515 (deprecated) | RFC 8754 |

### 7.11.3 Why SRH is Secure Where RH0 Was Not

RH0 allowed unlimited amplification attacks because routers would forward packets to reflected destinations without adequate checks. SRH addresses this through:

1. **Controlled segment lists**: Only authorized segments can be included
2. **HMAC verification**: Integrity protection prevents tampering
3. **No amplification**: Segments must be explicitly authorized
4. **Segment visibility**: Network operators control segment allocation

## 7.12 Operational Considerations

### 7.12.1 MTU Configuration

Operators must ensure:

1. **Path MTU discovery** works correctly across the SRv6 domain
2. **Maximum segment list** fits within typical path MTUs
3. **Fragmentation** is avoided for SRH-carrying packets

### 7.12.2 Hardware Support

SRH processing varies by platform:

- **Software routers**: Parse SRH in control plane, program FIB entries
- **Hardware ASICs**: May have limited SRH parsing depth
- **Network processors**: Full SRH parsing with wire-speed processing

### 7.12.3 Debugging Tools

Useful commands for SRH inspection:

```
# Wireshark display filter for SRH
ipv6.router == 43 && ipv6.router == 4

# tcpdump for SRH
tcpdump -i <iface> 'ip6[ nh + 24 ] == 43 && ip6[ nh + 25 ] == 4'

# Linux ip -6 route with SRv6
ip -6 route show
ip -6 neigh show
```

## 7.13 Summary

This chapter provided detailed analysis of the SRH:

- **SRH as IPv6 extension header**: Routing Type 4, follows Destination Options
- **Fixed header fields**: Next Header, Hdr Ext Len, Routing Type, Segments Left, Last Entry, Flags, Reserved
- **Segment list encoding**: Reversed order (first segment at last index), processed from end to beginning
- **Segments Left**: Critical counter decremented at each segment, determines current processing
- **Last Entry**: Index of final segment, enables efficient parsing
- **Flags**: Tag field for grouping, flag bits for TLV signaling
- **Optional TLVs**: PAD1, PADN, HMAC for padding and authentication
- **Processing mechanics**: DA update at each segment, SRH stripped at final destination
- **Size calculations**: 8 bytes minimum, 16 bytes per segment plus TLVs
- **Stacked SRH**: Multiple SRH headers for hierarchical segmentation
- **SRH vs RH0**: SRH is secure where RH0 was deprecated

Chapter 8 will examine how SRH operates within the complete IPv6 packet structure and detail packet processing flows.

---

**References**

- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8200: Internet Protocol Version 6 (IPv6) Specification
- RFC 5095: Deprecation of Type 0 Routing Headers
- RFC 8986: SRv6 Network Programming
- IANA IPv6 Routing Header Types Registry
