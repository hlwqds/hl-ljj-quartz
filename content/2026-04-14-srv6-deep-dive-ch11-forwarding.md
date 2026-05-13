# Chapter 11: SRv6 Forwarding Process - Transit, PSP, USP, and Header Stack Mechanics

## 11.1 Overview

Understanding how an SRv6 packet moves through a network requires examining the forwarding process at each hop—the decisions made, the header manipulations performed, and the conditions that determine next-hop actions. This chapter dissects the complete forwarding flow, from initial encapsulation at the source through transit processing at intermediate nodes to final delivery at the destination.

The forwarding process reveals several key SRv6 design decisions that affect both functionality and performance: the PSP (Penultimate Segment Pop) and USP (Ultimate Segment Pop) flavors control when the SRH is removed, the Upper/Lower Header Stack (HL) mechanism enables nested encapsulation layers, and the Segments Left (SL) counter tracks progress through the segment list. Understanding these mechanics is essential for troubleshooting, performance optimization, and advanced SRv6 design.

## 11.2 Transit Processing Fundamentals

### 11.2.1 The Transit Paradigm

SRv6's forwarding model is elegantly simple: **transit nodes forward based solely on the Destination Address (DA), completely ignoring the SRH**. This design decision—fundamental to SRv6's scalability—means that routers along a path need only maintain FIB entries forlocators (the network-visible portion of SIDs), not for every possible SID or segment list combination.

A transit router parsing an SRv6 packet performs these steps:

```
Transit Processing:
1. Receive packet with DA = IPv6 address
2. Perform FIB lookup on DA
3. If DA matches a local locator:
   a. Identify the behavior bound to this SID
   b. Execute the behavior (SRH processing, DA update, etc.)
   c. If SL > 0, update DA and forward
4. Else:
   a. Forward based on longest-prefix match
```

This contrasts sharply with the SR-MPLS model, where every LSR must maintain label state for all LSPs. In SRv6, transit routers maintain only locator FIB entries—effectively one entry per node plus one per anycast group. The segment list is relevant only at the source (which computes it) and at segment endpoints (which execute behaviors). Transit nodes treat the SRH as an opaque extension header that travels with the packet but doesn't influence forwarding decisions.

### 11.2.2 End Behavior in Detail

The **End** behavior is the most commonly used segment behavior in SRv6. When a packet with DA matching a local End SID arrives, the router executes:

```
End Behavior:
1. Check SL (Segments Left)
2. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]        # Update DA from segment list
   c. Forward packet based on new DA
3. If SL == 0:
   a. This is the final segment
   b. Remove SRH (if present and PSP flavor)
   c. Deliver to upper layer
```

The key insight is that End consumes one segment from the segment list and advances to the next. The packet's DA is replaced with the next segment's value (from the SRH segment list), and the SL counter is decremented. This sequential consumption is what creates the path progression through the network.

### 11.2.3 Transit vs. Endpoint Roles

A single router may simultaneously serve as a **transit node** for some packets and an **endpoint** for others. Consider a topology where Router B lies on the path from A to C:

```
Segment List: [A, B, C, D]
Position A: Source - pushes SRH with segments [A, B, C, D], SL=3
Position B: Transit (for this packet) - DA=B, but B is an endpoint
            - SL > 0, so B updates DA to C, SL=2
Position C: Endpoint - SL > 0, updates DA to D, SL=1
Position D: Final endpoint - SL=0, removes SRH, delivers to upper layer
```

At Router B, the packet arrives with DA matching B's local prefix. B's FIB entry for its locator matches, identifying B as the responsible endpoint. B executes the End behavior, sees SL > 0, and advances to C. For other packets passing through B with different segment lists where B is not a segment, B would forward purely based on DA without behavior execution—a pure transit role.

## 11.3 SRH Flavors: PSP, USP, and ST

The SRH specification defines three flavor flags that control SRH processing behavior: **PSP** (Penultimate Segment Pop), **USP** (Ultimate Segment Pop), and **ST** (Segmentation Trailer). These flavors determine when and how the SRH is removed from the packet.

### 11.3.1 PSP (Penultimate Segment Pop)

**PSP** instructs the **penultimate segment** (the node immediately before the final endpoint) to remove the SRH. The motivation is efficiency: if no service chaining or further SRv6 processing is required at the final endpoint, removing the SRH there saves one extension header processing operation at the last hop.

```
PSP Logic (at endpoint):
if (PSP flag set AND SL == 1):
    # Penultimate segment - I am second-to-last
    Remove SRH from packet
    Deliver to upper layer with clean IPv6 header
else:
    # Normal processing
    Process normally
```

Consider a path with segment list [A, B, C, D]:

- Position A: Source, pushes SRH, SL=3
- Position B: SL=2, not penultimate (SL != 1)
- Position C: SL=1, **penultimate** - if PSP set, strip SRH here
- Position D: SL=0, final endpoint - would normally process SRH, but with PSP, SRH already gone

The penultimate segment concept mirrors MPLS's PHP (Penultimate Hop Popping), where the LSR before the LSP tail-end pops the label stack, leaving the tail-end to receive a raw IP packet. PSP provides equivalent efficiency for SRv6.

### 11.3.2 USP (Ultimate Segment Pop)

**USP** is the opposite of PSP in intent: it instructs the **ultimate segment** (final endpoint) to preserve the SRH and not pop it. This preserves visibility for OAM operations and service chaining, at the cost of an additional processing step at the destination.

```
USP Logic (at final endpoint):
if (USP flag set AND SL == 0):
    # Ultimate segment - I am the final endpoint
    Leave SRH in packet
    Deliver to upper layer with SRH intact
else:
    # Normal processing
    Process normally
```

When would you want the final endpoint to keep the SRH? Several scenarios:

1. **OAM and Tracing**: Preserving the SRH allows the destination to reconstruct the complete path for diagnostic purposes. A traceroute response can include the original SRH to show every segment the packet traversed.

2. **Service Chain Visibility**: In service function chaining, the original segment list may need to be consulted by intermediate service functions, even after the final SRv6 endpoint is reached.

3. **Multicast Replication**: When an SRv6 endpoint also functions as a multicast replicator, preserving the SRH enables each replica to carry the original segment list.

USP is less commonly deployed than PSP due to its overhead, but it serves important purposes in environments where path visibility is valued.

### 11.3.3 ST (Segmentation Trailer)

**ST** indicates the presence of a **Segmentation Trailer** (also called the SRv6 OAM trailer or TLV trailer) appended after the payload. The trailer provides additional metadata about the segment list, processing state, or OAM information.

```
ST Structure (at end of packet after payload):
+----------+---------+----------+
|  Next    |  Len    |  Class   |
|  Header  |  (opt)  |          |
+----------+---------+----------+
|  Type    |  Flags  |  Checksum|
+----------+---------+----------+
|  Trailer Type-specific Data   |
+-------------------------------+
```

The ST trailer enables in-band telemetry, path tracing, and operations measurements without separate probing packets. Common trailer types include:

- **Path Tracing**: Records timestamps and node identifiers at each hop
- **Timestamps**: For delay measurement between segments
- **ECN Marking**: Explicit Congestion Notification passthrough

### 11.3.4 Flavor Combinations

The flavor flags can be combined, though not all combinations are sensible:

| PSP | USP | ST  | Behavior                                 |
| --- | --- | --- | ---------------------------------------- |
| 0   | 0   | 0   | Normal - endpoint processes SRH          |
| 1   | 0   | 0   | PSP - penultimate pops SRH               |
| 0   | 1   | 0   | USP - final keeps SRH                    |
| 1   | 1   | 0   | Invalid combination (mutually exclusive) |
| 0   | 0   | 1   | ST present - trailer follows payload     |
| 1   | 0   | 1   | PSP + ST                                 |
| 0   | 1   | 1   | USP + ST                                 |

The PSP and USP flags are mutually exclusive in the SRH flags field. Deployment typically selects either PSP (for efficiency) or neither (for simplicity), with USP reserved for specialized OAM scenarios.

## 11.4 Upper Header Stack vs. Lower Header Stack (HL)

SRv6 supports nested encapsulation—outer SRv6 headers containing inner payloads that may themselves be SRv6 packets. This arises in scenarios like service function chaining, VPN encapsulation over transport SRv6, or multi-domain steering. The **Header Stack** concept, and specifically the **HL** (Header Stack depth) mechanism, manages these layered encapsulations.

### 11.4.1 The Nested Encapsulation Problem

Consider a service chain where traffic must traverse both a transport path and a service function:

```
Domain A (source) encapsulates packet for transport to Node X
Node X must then apply service processing and re-encapsulate for transport to Node Y
Node Y delivers to the final destination
```

If both encapsulations use SRv6, the packet carries two SRH structures—nested like Russian dolls. At each level, processing must distinguish between:

- The current (active) SRH being processed
- Outer SRH structures that belong to an enclosing encapsulation
- Inner SRH structures that belong to an encapsulated payload

### 11.4.2 The HL Boundary

The **HL** (Header Stack Depth) field in the SRH specification was introduced to provide this separation. The HL value indicates the depth boundary between "Upper" SRH (active for this encapsulation layer) and "Lower" SRH (belonging to inner payloads).

```
Packet Structure with HL boundary:
+----------------------------------+
|  Outer IPv6 Header               |
|    DA = Outer Destination         |
+----------------------------------+
|  Outer SRH (HL = N)              |
|    Segments Left = current SL    |
+----------------------------------+
|  Upper HL Region                  |
|    (N segments active for this   |
|     encapsulation level)         |
+----------------------------------+
|  Lower HL Region                  |
|    (Nested SRH for inner         |
|     payload, not processed at    |
|     this layer)                  |
+----------------------------------+
|  Inner Payload (could be IPv6,  |
|  could be another SRv6 packet)   |
+----------------------------------+
```

When a node processes an SRv6 packet, the HL value tells it where the boundary lies: segment entries from position 0 to HL-1 (the Upper HL) are active and should be processed by this encapsulation layer. Segment entries from HL onward (the Lower HL) belong to the inner payload and should be ignored for current-layer processing.

### 11.4.3 HL=0: Full Stack Processing

**HL=0** is a special value indicating that the entire segment list belongs to the Upper HL—meaning this SRH fully describes the packet's segment list with no nested encapsulation. Most SRv6 deployments use HL=0.

```
HL=0 Processing:
- Entire segment list (Segments[0] through Segments[Last Entry]) is active
- No inner/nested SRH present at this layer
- Standard End behavior processes all segments
```

HL=0 simplifies the common case where no nesting occurs. Transit and endpoint nodes process the entire segment list without considering nested boundaries.

### 11.4.4 HL>0: Nested Encapsulation

When HL > 0, the segment list is divided:

```
HL > 0 Processing (at upper-layer endpoint):
- Upper HL: Segments[0] through Segments[HL-1] - process these
- Lower HL: Segments[HL] through Segments[Last Entry] - belong to inner payload
- When upper-layer processing completes (SL reaches HL-1):
  - Do NOT decrement to HL
  - Instead, this is the boundary - inner payload is now accessible
  - If inner payload is SRv6, its SRH becomes the active SRH
```

The HL boundary enables clean handoff between encapsulation layers. When the upper-layer segment list is exhausted, processing transitions to the inner payload without ambiguity.

## 11.5 Complete Packet Journey

### 11.5.1 Source Node Processing

At the SRv6 source node, the packet undergoes preparation before transmission:

```
Source Node Processing:
1. Receive packet from upper layer (TCP/UDP/application)
2. Determine SR Policy or segment list to apply
3. Push IPv6 header with:
   - Source Address = Node's address
   - Destination Address = First segment (Segment[0])
4. Push SRH with:
   - Segments[] = Complete segment list in reversed order
   - Segments Left = (Number of segments - 1)
   - Last Entry = (Number of segments - 1)
   - Flags: PSP/USP/ST as needed per policy
   - HL = 0 (no nesting unless explicitly programmed)
5. Transmit packet
```

The segment list is stored in **reversed order** in the SRH. If the desired path is A → B → C → D, the SRH contains segments [A, B, C, D] with Segments Left = 3. The first segment in the SRH (Segment[0] = A) is the initial DA.

### 11.5.2 Transit Node Processing

Transit nodes apply minimal processing:

```
Transit Node Processing:
1. Receive packet
2. Parse IPv6 header, extract Destination Address
3. FIB lookup on DA
4. If DA matches local locator:
   - Identify behavior from SID function
   - Execute behavior (End, End.X, etc.)
   - Update DA from segment list if SL > 0
   - Decrement TTL/Hop Limit
5. Else:
   - Normal IPv6 forwarding based on DA
6. Forward packet to next hop
```

The key observation: **transit nodes never touch the SRH**. The SRH is processed only at segment endpoints—nodes whose locators match the current DA. This separation between routing (which uses DA) and segment processing (which uses SRH) is what makes SRv6 scalable.

### 11.5.3 Segment Endpoint Processing

When a packet's DA matches a local locator, the node is a segment endpoint. The behavior bound to the matching SID determines processing:

```
Endpoint Processing (End behavior example):
1. Receive packet with DA = My-SID
2. Lookup SID in local SID table, identify behavior
3. Check Segments Left:
   a. If SL > 0:
      - SL = SL - 1
      - DA = Segment[SL]     # Move to next segment
      - Check PSP flavor: if PSP and SL == 1, strip SRH
      - Forward based on new DA
   b. If SL == 0:
      - Final destination for this SRv6 layer
      - If USP flag set, keep SRH; else strip SRH
      - Deliver to upper layer (layer-3 or service)
```

Different behaviors (End.X, End.DT6, etc.) modify this flow appropriately, but the SL decrement and DA update pattern remains consistent.

### 11.5.4 Final Delivery

At the final destination, the SRH (if present after PSP processing) is removed, and the inner payload is delivered to the upper layer:

```
Final Delivery:
1. Packet arrives with DA = Final destination
2. If SRH present (not stripped by PSP):
   - Process last segment if SL > 0, or
   - Strip SRH and process as final if SL == 0
3. Remove SRH (if present)
4. Remove outer IPv6 header
5. Deliver inner payload to transport layer (TCP/UDP) or application
```

For a VPN scenario, the End.DT6 behavior would deliver the inner payload to the appropriate VRF table for routing.

## 11.6 TTL and Hop Limit Handling

SRv6 must handle TTL (Time to Live) propagation carefully, especially given the potential for long segment lists and the source-routed nature of SRv6 paths.

### 11.6.1 TTL Decrement

Each SRv6 segment processing step (at endpoints) should decrement the IPv6 Hop Limit by 1, just as normal IPv6 forwarding does at each hop. Transit nodes that only forward (without SRv6 endpoint processing) also decrement the Hop Limit.

However, because SRv6 may traverse multiple segments in what would be a single IP hop in traditional routing, operators must consider the total segment list length when setting initial TTL values. A packet with an 8-segment list consumes 8 of its 64-hop limit before reaching the destination—a significant fraction.

### 11.6.2 TTL Expiration

When the Hop Limit reaches zero, the packet is discarded and an ICMPv6 Time Exceeded message is returned to the source. This is identical to normal IPv6 behavior. SRv6 traceroute utilities leverage this by sending probes with incrementing Hop Limits to discover the segment path.

### 11.6.3 MTU and Fragmentation

SRv6 encapsulation adds overhead: the IPv6 header (40 bytes) plus the SRH (minimum 8 bytes plus segment entries at 16 bytes each) plus potential flavor flags and TLVs. A packet with 4 segments requires:

```
Overhead calculation (4-segment path):
- IPv6 header: 40 bytes
- SRH: 8 bytes (base) + 4×16 bytes (segments) = 72 bytes
- Total SRv6 overhead: 112 bytes

Maximum path MTU consideration:
- Inner packet: 1500 bytes (typical Ethernet payload)
- Outer headers: 112 bytes
- Total: 1612 bytes
```

Path MTU Discovery (PMTUD) should be employed when inner payloads approach network MTU limits. Alternatively, fragmentation can occur at the source, but this is generally discouraged due to performance overhead.

## 11.7 Transit Processing at Scale

### 11.7.1 Locator-Based FIB

The scalability of SRv6 transit forwarding derives from the **locator FIB** model. Each node advertises its locator prefix via IGP (IS-IS or OSPFv3). Transit nodes install these prefixes in their FIB:

```
Locator FIB Entry (per node):
- Prefix: FC00:0:1:1::/64 (example)
- Next-hop: Interface toward node FC00:0:1:1
- Metric: IGP cost to reach that prefix
-SID count: How many SIDs use this locator
```

Transit nodes need only O(N) FIB entries where N is the number of nodes in the network, regardless of how many SIDs each node publishes. This is dramatically better than SR-MPLS, where each LSP required state at every transit LSR.

### 11.7.2 Transit Performance

Hardware forwarding of SRv6 at transit nodes is essentially identical to normal IPv6 forwarding:

1. Parse DA from IPv6 header
2. Longest-prefix match in TCAM
3. Forward to next-hop

The only SRv6-specific overhead is ensuring that packets with SRH are not inadvertently forwarded based on SRH contents—the FIB lookup on DA ensures only the outer IPv6 DA influences forwarding.

Modern ASICs handle SRv6 transit as a minor extension to IPv6 forwarding, with no performance penalty compared to native IPv6 in most implementations.

## 11.8 OAM Integration

Operations, Administration, and Maintenance (OAM) in SRv6 leverages the segment list to provide path-specific diagnostics.

### 11.8.1 SRv6 Traceroute

Traceroute in SRv6 works by sending probes with decreasing Hop Limits. Each probe triggers ICMP Time Exceeded at the point where TTL expires:

```
SRv6 Traceroute Process:
1. Source sends probe with Hop Limit = 1
   - No response (TTL expires at first hop)
2. Source sends probe with Hop Limit = 2
   - ICMP from second hop
3. Continue incrementing Hop Limit
4. Each ICMP response reveals one segment
5. Final probe (large TTL) reaches destination
```

Because each segment is a distinct DA, traditional traceroute naturally reveals the segment path. Combined with USP flavor (which preserves SRH at the final endpoint), the complete path can be reconstructed.

### 11.8.2 Path Tracing with ST Flavor

The ST (Segmentation Trailer) flavor enables active measurement without TTL expiration. Nodes along the path append timestamped information to the trailer, providing precise delay measurements:

```
Path Tracing Process:
1. Source sends packet with ST flag set
2. Each segment endpoint:
   a. Appends timestamp to trailer
   b. Adds local identifier (SID or router ID)
   c. Optionally adds interface statistics
3. Destination records arrival time
4. Packet returns to source with full path trace
```

## 11.9 Summary

This chapter traced the complete SRv6 forwarding flow from source to destination:

- **Transit Processing**: Transit nodes forward based solely on the Destination Address, treating the SRH as an opaque extension header. The SRH is relevant only at segment endpoints. This design provides O(N) scalability where N is the number of nodes, regardless of SID count or segment list length.

- **End Behavior**: The fundamental End behavior decrements Segments Left, updates the DA from the segment list, and forwards. This sequential consumption creates the progression through the programmed path.

- **PSP Flavor**: Penultimate Segment Pop allows the node immediately before the final endpoint to strip the SRH, saving processing at the destination. This mirrors MPLS PHP and provides equivalent efficiency.

- **USP Flavor**: Ultimate Segment Pop instructs the final endpoint to preserve the SRH, enabling OAM visibility, traceroute reconstruction, and service chain metadata preservation.

- **ST Flavor**: Segmentation Trailer enables in-band telemetry, path tracing, and delay measurement through a trailer appended after the payload.

- **HL Boundary**: The Upper/Lower Header Stack boundary with HL>0 handles nested SRv6 encapsulations, cleanly separating which segments belong to which encapsulation layer. HL=0 indicates no nesting.

- **Complete Journey**: Source nodes push the IPv6 header and SRH with reversed segment list and initial SL value. Transit nodes forward without SRH processing. Segment endpoints execute behaviors, decrementing SL and updating DA. Final delivery strips remaining headers and passes the inner payload upward.

Understanding these forwarding mechanics is essential for deploying, troubleshooting, and optimizing SRv6 networks. The protocol's elegance—separating transit (scalable, FIB-only) from endpoint processing (stateful, behavior-driven)—enables carrier-grade performance while preserving programmability.

---

**References**

- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8986: SRv6 Network Programming
- RFC 8402: Segment Routing Architecture
- RFC 8200: Internet Protocol Version 6 (IPv6) Specification
- RFC 4443: ICMPv6 for IPv6
