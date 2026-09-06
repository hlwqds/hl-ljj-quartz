# Chapter 8: Packet Structure and Processing - SRv6 in Action

## 8.1 Overview

This chapter examines the complete SRv6 packet structure and the processing mechanics at each node type. Understanding how packets are constructed, transmitted, and processed is essential for troubleshooting, design, and optimization of SRv6 networks.

We trace a packet's journey from source to destination, examining the exact header state at each point, and detailing how routers along the path process the SRH to forward packets along the programmed segment list.

## 8.2 Complete SRv6 Packet Structure

### 8.2.1 Full Packet Layout

A complete SRv6 packet contains:

```
+------------------------------------------------------------------+
|                                                                    |
|  IPv6 Basic Header (40 bytes)                                      |
|    - Source Address: Originating node                             |
|    - Destination Address: Current segment (changes at each hop)    |
|    - Next Header: 43 (SRH)                                        |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
|  Segment Routing Header (variable)                                |
|    - Segments Left: Segments remaining                            |
|    - Segment List: Ordered list of segments                       |
|    - Next Header: Upper layer protocol (6=TCP, 17=UDP)           |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
|  Upper Layer Header (TCP/UDP/etc.)                                |
|    - Payload                                                      |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
| 可能的:                                                                |
|  - ESP/AH for security                                            |
|  - Inner IP packet (for encapsulated packets)                    |
|                                                                    |
+------------------------------------------------------------------+
```

### 8.2.2 Unfragmentable vs Fragmentable Parts

In IPv6, certain extension headers must not be fragmented. The **unfragmentable part** includes:

1. IPv6 Basic Header
2. Hop-by-Hop Options Header (if present)
3. Destination Options Header (if present, before routing header)
4. **Routing Header (including SRH)**
5. Authentication Header (if present)
6. ESP Header (if present)

The **fragmentable part** includes:

1. Destination Options Header (after routing header)
2. Upper Layer Header
3. Payload

For SRv6, the SRH is always in the unfragmentable part. This means the entire SRH plus IPv6 header must fit within the path MTU.

### 8.2.3 Wire Format Example

A complete SRv6 packet with 3 segments, TCP payload:

```
Ethernet Header (not shown)
|
+------------------------------------------------------------------+
| Version | Traffic Class   |           Flow Label                  |
+------------------------------------------------------------------+
|         Payload Length    |    Next Header = 43   |   Hop Limit   |
+------------------------------------------------------------------+
|                                                                    |
|                    Source Address                                 |
|                 2001:db8:cafe:1::1                                |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
|                  Destination Address                             |
|                  FC00:0:1:3::1    <- Current segment              |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
| Next Header = 6 (TCP) | Hdr Ext Len = 6 | Routing Type = 4        |
+------------------------------------------------------------------+
| Segments Left = 3      | Last Entry = 2 | Flags | Reserved        |
+------------------------------------------------------------------+
|                                                                    |
|                 Segment List[0]                                   |
|               FC00:0:1:1::1    <- Final destination                |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
|                 Segment List[1]                                   |
|               FC00:0:1:2::1    <- Second segment                   |
|                                                                    |
+------------------------------------------------------------------+
|                                                                    |
|                 Segment List[2]                                   |
|               FC00:0:1:3::1    <- First segment (DA initially)    |
|                                                                    |
+------------------------------------------------------------------+
| TCP Header + Payload...                                           |
+------------------------------------------------------------------+
```

## 8.3 End-to-End Packet Journey

### 8.3.1 Example Topology

```
    Source                                          Destination
      |                                                  |
      |  Segment List: [S1, S2, S3, Dest]               |
      |  Last Entry = 3, Segments Left = 4              |
      |                                                  |
      v                                                  v
+-----+     +-----+     +-----+     +-----+     +-----+
| SR1 |---->| SR2 |---->| SR3 |---->| SR4 |---->| SR5 |
+-----+     +-----+     +-----+     +-----+     +-----+
  SID:        SID:        SID:        SID:        SID:
FC00:0:1:3 FC00:0:1:3 FC00:0:1:3 FC00:0:1:3 FC00:0:1:1
```

- **Source**: 2001:db8:cafe:1::1
- **SR1**: FC00:0:1:3::1 (first segment, locator /64 = FC00:0:1:3)
- **SR2**: FC00:0:1:2::1
- **SR3**: FC00:0:1:3::1
- **SR4**: FC00:0:1:4::1
- **SR5**: FC00:0:1:1::1 (final destination, segment list[0])
- **Destination**: FC00:0:1:1::5 (final inner destination)

Segment List (reversed order):

```
Segment List[0] = FC00:0:1:1::1 (SR5 - final segment)
Segment List[1] = FC00:0:1:4::1 (SR4)
Segment List[2] = FC00:0:1:3::1 (SR3)
Segment List[3] = FC00:0:1:2::1 (SR2)
Last Entry = 3
Segments Left = 4 (at source)
```

### 8.3.2 Step 1: Source Node - Packet Origination

At the source node:

```
Packet fields:
  Source Address:     2001:db8:cafe:1::1
  Destination Address: FC00:0:1:2::1  (Segment List[3] = first segment)
  Next Header:        43 (SRH)

SRH fields:
  Segments Left:      4
  Last Entry:         3
  Segment List[0]:     FC00:0:1:1::1  (SR5)
  Segment List[1]:     FC00:0:1:4::1  (SR4)
  Segment List[2]:    FC00:0:1:3::1  (SR3)
  Segment List[3]:    FC00:0:1:2::1  (SR2 - DA initially)

Upper layer: TCP to FC00:0:1:1::5
```

The source knows:

- Inner destination: FC00:0:1:1::5
- Outer destination (first segment): FC00:0:1:2::1

### 8.3.3 Step 2: SR1 (First Segment) Processing

SR1 receives packet with DA = FC00:0:1:2::1 (not its own SID)

SR1 is not the target of the current DA. It simply forwards based on routing. The SRH is not processed by transit routers that are not the current segment target.

Wait—SR1 **IS** a segment endpoint. Let's trace through carefully:

SR1's locator: FC00:0:1:3::/64
SR1 processes: FC00:0:1:3::1 (End SID)
SR2's locator: FC00:0:1:2::/64

Actually, in our example, let me reframe:

Each router has an End SID. The packet is routed to the locator of the current segment. Let me use a cleaner topology:

```
Packet originates at Source
DA = FC00:0:1:1::1 (SR1's End SID - first segment to process)
Segments Left = 3

SR1 receives packet with DA = FC00:0:1:1::1
SR1 is the target (matches its End SID)
SR1 processes SRH:
  - Segments Left: 3 -> 2
  - DA = Segment List[2] = FC00:0:1:2::1 (next segment)
SR1 forwards to SR2

SR2 receives packet with DA = FC00:0:1:2::1
SR2 is the target (matches its End SID)
SR2 processes SRH:
  - Segments Left: 2 -> 1
  - DA = Segment List[1] = FC00:0:1:3::1 (next segment)
SR2 forwards to SR3

SR3 receives packet with DA = FC00:0:1:3::1
SR3 is the target (matches its End SID)
SR3 processes SRH:
  - Segments Left: 1 -> 0
  - DA = Segment List[0] = FC00:0:1:4::1 (next segment - last)
SR3 forwards to SR4

SR4 receives packet with DA = FC00:0:1:4::1
SR4 is the target (matches its End SID)
SR4 processes SRH:
  - Segments Left: 0 -> 0 (already 0)
  - This is the final destination
  - SR4 strips SRH
  - DA = FC00:0:1:4::1 (this was the last segment, now original inner)
SR4 delivers to upper layer
```

### 8.3.4 Revised Example Topology

Let's use a cleaner 4-segment example:

```
Segment List: [SR4, SR3, SR2, SR1] (first to last)
Segment List[0] = SR4 (final)
Segment List[1] = SR3
Segment List[2] = SR2
Segment List[3] = SR1 (first)
Last Entry = 3
Segments Left = 4

Path: Source -> SR1 -> SR2 -> SR3 -> SR4 -> Dest
```

## 8.4 Transit Processing

### 8.4.1 Transit Router Perspective

A **transit router** is any router that receives a packet but is NOT the current segment target. Transit routers only see:

1. IPv6 basic header (for forwarding)
2. Locator prefix in DA (for routing)
3. Hop Limit (for TTL)

Transit routers do NOT:

- Process the SRH
- Decrement Segments Left
- Update the segment list

### 8.4.2 Transit Forwarding Example

```
Transit router R2 receives:
  DA = FC00:0:1:3::1
  R2's locator = FC00:0:1:2::/64
  DA does not match R2's locator

R2's forwarding decision:
  1. Perform longest-prefix match on DA
  2. Match FC00:0:1:3::/64 (R3's locator)
  3. Forward to next hop toward R3
  4. Do NOT touch SRH
```

This is a critical insight: **transit routers are unaware of SRv6 processing**. They simply route based on the DA's locator prefix.

### 8.4.3 Transit Scalability

Because transit routers don't process the SRH:

1. **No per-flow state**: Each packet is forwarded based on destination address
2. **Standard FIB entries**: Only locator prefixes needed
3. **Hardware-friendly**: Standard IPv6 forwarding ASICs work

## 8.5 Segment Endpoint Processing

### 8.5.1 Segment Endpoint Behavior

A **segment endpoint** is a node whose locator matches the current DA. When a packet arrives with DA = node's locator or specific SID:

1. Node recognizes itself as the segment target
2. Node processes the SRH
3. Node updates Segments Left and DA
4. Node forwards based on new DA

### 8.5.1 Detailed Segment Endpoint Processing

```
On packet arrival with SRH:

    if Segments_Left > 0:
        # This node is a transit segment
        next_segment = Segment_List[Segments_Left - 1]
        DA = next_segment
        Segments_Left = Segments_Left - 1

        # Optional: execute behavior based on SID
        # Optional: process TLVs
        # Optional: update HMAC

        Forward based on new DA

    else:
        # This node is the final destination
        # Strip SRH
        # Process upper layer
        Deliver_to_upper_layer()
```

### 8.5.3 Example: SR1 Processing

SR1's locator: FC00:0:1:1::/64
SR1's End SID: FC00:0:1:1::1

```
SR1 receives packet:
  DA = FC00:0:1:1::1  (matches SR1's End SID)
  Segments Left = 3
  Segment List[2] = FC00:0:1:2::1 (next segment)

SR1 processing:
  1. Match DA against local SID table
  2. Recognize FC00:0:1:1::1 as own End SID
  3. Execute End behavior:
     - Segments Left: 3 -> 2
     - DA: FC00:0:1:1::1 -> FC00:0:1:2::1
  4. Forward to next hop toward FC00:0:1:2::1
```

## 8.6 Final Destination Processing

### 8.6.1 Arrival at Final Segment

When Segments Left reaches 0, the packet has reached its final SRv6 segment. The node performs **final destination processing**:

```
if Segments_Left == 0:
    # Final destination processing

    # Option 1: Strip SRH and deliver
    strip_SRH()
    deliver_to_upper_layer()

    # Option 2: Keep SRH for processing (some behaviors)
    # (depends on specific behavior being executed)
```

### 8.6.2 DA After Final Segment

When Segments Left = 0:

- **DA = Segment List[0]** = the final segment's SID
- This is the SID that was processed last
- The original inner destination is preserved elsewhere or inferred from context

### 8.6.3 Upper Layer Delivery

After SRH stripping:

1. Upper layer protocol identified via SRH's Next Header field
2. Checksum verification (including pseudo-header)
3. Payload delivered to transport layer (TCP/UDP)
4. Application receives data

## 8.7 Complete Packet Evolution

### 8.7.1 State at Each Hop

Let's trace a complete packet journey with segments [A, B, C, D] where D is final:

```
Segment List (reversed):
  [0] = D (final)
  [1] = C
  [2] = B
  [3] = A (first)
Last Entry = 3
Segments Left = 4
```

**State at Source:**

```
DA = A (first segment)
Segments Left = 4
Segment List unchanged
```

**After A processes:**

```
DA = B (next segment)
Segments Left = 3
(A decremented from 4)
```

**After B processes:**

```
DA = C (next segment)
Segments Left = 2
```

**After C processes:**

```
DA = D (next segment)
Segments Left = 1
```

**After D processes:**

```
DA = D (remains)
Segments Left = 0
SRH stripped
Upper layer delivered
```

### 8.7.2 DA Updates Illustrated

```
Hop 0 (Source):
  DA = Segment[3] = A

Hop 1 (A):
  DA = Segment[2] = B

Hop 2 (B):
  DA = Segment[1] = C

Hop 3 (C):
  DA = Segment[0] = D

Hop 4 (D):
  DA = D (final)
  Segments Left = 0
  Strip SRH
```

## 8.8 Encapsulation Scenarios

### 8.8.1 Simple SRv6 (No Encapsulation)

The basic case we've discussed: original packet is encapsulated in SRH.

```
Original packet:
  SA = Source
  DA = Inner Dest

SRv6 packet:
  SA = Source
  DA = First Segment
  SRH with segments [rest]
```

### 8.8.2 SRv6 with Outer Encapsulation

When SRv6 operates over an underlay (e.g., another IPv6 network):

```
Outer Header:
  SA = Underlay Source (may be same as SR source)
  DA = Underlay Next Hop

Inner (SRv6 Packet):
  SA = Original Source
  DA = First SRv6 Segment
  SRH = SRv6 Segment List
  Payload = Original Packet
```

### 8.8.3 End.B6.Encaps Behavior

The **End.B6.Encaps** behavior creates a new outer header with SRH:

```
Original packet arrives at encapsulator:

1. Push new IPv6 header
2. Set outer DA = first segment
3. Push SRH with remaining segments
4. Set inner DA = original inner DA
5. Forward encapsulated packet
```

This creates a packet-within-a-packet structure for service chaining or traffic engineering.

## 8.9 Upper Layer Interaction

### 8.9.1 TCP/UDP Processing

After SRH stripping at the final destination:

1. Upper layer identified from SRH Next Header
2. TCP/UDP processed normally
3. Checksums verified including pseudo-header (with final DA)

### 8.9.2 Checksum Considerations

The IPv6 pseudo-header for TCP/UDP checksum uses the **final destination address** (after routing). For SRv6:

- Source Address: Original source (unchanged)
- Destination Address: Final DA after all SRH processing

This ensures transport layer integrity despite source routing.

### 8.9.3 Fragmentation and Reassembly

SRv6 and fragmentation interact carefully:

1. **SRH is unfragmentable**: The SRH must fit in path MTU
2. **Inner payload may fragment**: If inner packet exceeds remaining MTU
3. **Reassembly before processing**: Fragments are reassembled before SRH processing continues

## 8.10 Error Handling

### 8.10.1 Segments Left Errors

If a node receives a packet with Segments Left > Last Entry:

```
Error: Invalid SRH (Segments Left exceeds list)
Action: Drop packet
ICMPv6: Parameter Problem (Code 0)
```

### 8.10.2 Unknown SID

If a node receives a packet with DA matching a locator but the specific SID is not locally instantiated:

```
Error: SID not found
Action: Drop packet or forward based on locator (implementation-dependent)
```

### 8.10.3 Missing SRH

If an IPv6 packet indicates SRH (Next Header = 43) but the header is missing or malformed:

```
Error: Malformed packet
Action: Drop packet
ICMPv6: Parameter Problem (Code 0 or 2)
```

## 8.11 OAM and Troubleshooting

### 8.11.1 SRv6 Ping

The **SRv6 Ping** (RFC 8986 Appendix B) verifies segment reachability:

```
SRv6 Ping packet:
  - IPv6 Header with SRH
  - ICMPv6 Echo Request
  - Segment list contains SID to test

SRv6 Ping response:
  - Reverse segment list
  - ICMPv6 Echo Reply
```

### 8.11.2 traceroute6 with SRH

Standard traceroute works with SRv6:

```
traceroute6 to destination with SRH:

Hop 1: Router processing segment 1
Hop 2: Router processing segment 2
...
Hop N: Final destination
```

Each hop shows the router's address as it processes each segment.

### 8.11.3 Packet Captures

When capturing SRv6 packets:

```
Wireshark filter for SRH:
  ipv6.router == 43 && ipv6.router_type == 4

tcpdump for SRv6:
  tcpdump -i eth0 -nn -e 'ip6[ nh + 24 ] == 43 && ip6[ nh + 25 ] == 4'
```

### 8.11.4 Debug Commands (Linux)

```
# Show SRv6 local SIDs
ip -6 sr localsids

# Show SRv6 policies
ip -6 sr policy

# Show SRv6 segments
ip -6 sr segments

# Monitor SRv6 packets
ip -6 sr monitor
```

## 8.12 Summary

This chapter traced SRv6 packet structure and processing:

- **Complete packet structure**: IPv6 basic header + SRH + upper layer, with unfragmentable vs fragmentable parts
- **End-to-end journey**: DA changes at each segment, Segments Left decrements
- **Transit processing**: Routers forward based on locator prefix, don't touch SRH
- **Segment endpoint processing**: Matches DA, processes SRH, updates Segments Left and DA
- **Final destination**: Segments Left = 0, strip SRH, deliver to upper layer
- **Packet evolution**: DA = Segment[Segments Left - 1] at each hop
- **Encapsulation scenarios**: SRv6 can operate with or without outer encapsulation
- **Upper layer interaction**: TCP/UDP processed normally after SRH stripping
- **Error handling**: Invalid SRH causes ICMP parameter problem
- **OAM**: Ping, traceroute, and packet captures work with SRv6

Chapter 9 will detail the specific SRv6 behaviors—how each SID type causes different processing at segment endpoints.

---

**References**

- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8986: SRv6 Network Programming
- RFC 8200: Internet Protocol Version 6 (IPv6) Specification
- RFC 4443: ICMPv6 for IPv6
- IETF draft: SRv6 Ping and Traceroute
