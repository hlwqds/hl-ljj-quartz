# Chapter 9: SRv6 Behaviors and Microprograms - The SID Processing Model

## 9.1 Overview

SRv6's power lies not just in path steering but in **network programming**—the ability to define arbitrary packet processing at each segment through **behaviors**. Each SID encodes both a location (locator) and a behavior (function), enabling the source to specify not just which nodes to visit, but what processing to perform at each.

This chapter dissects the SRv6 behavior architecture, detailing the standardized behaviors defined in RFC 8986, the concept of microprograms (composing multiple behaviors), and the processing mechanics that make SRv6 a programmable data plane.

## 9.2 Behavior Architecture

### 9.2.1 What is a Behavior?

An SRv6 **behavior** defines the exact processing that occurs when a packet arrives at a node and the node recognizes its local SID. Behaviors are identified by the **Function** portion of the SID.

The behavior determines:

1. What happens to the SRH (strip, keep, push new)
2. How the DA is updated
3. How the packet is forwarded (or other action)
4. What metadata or context is used
5. Whether additional processing occurs

### 9.2.2 Behavior Identifiers

Behaviors are identified by their **Function code** in the SID. RFC 8986 defines:

| Function Code | Behavior Name | Description |
|--------------|---------------|-------------|
| 0x0000 | End | Basic endpoint, decrement and forward |
| 0x0001 | End.X | Endpoint with cross-connect to neighbor |
| 0x0002 | End.T | Endpoint with table lookup |
| 0x0003 | End.DX6 | Endpoint with decapsulation to IPv6 |
| 0x0004 | End.DX4 | Endpoint with decapsulation to IPv4 |
| 0x0005 | End.DT6 | Endpoint with IPv6 table lookup (VRF) |
| 0x0006 | End.DT4 | Endpoint with IPv4 table lookup (VRF) |
| 0x0007 | End.B6.Encaps | B6 insertion with encapsulation |
| 0x0008 | End.B6.Encaps.Red | Reduced B6 insertion |
| 0x0009 | End.BM | Behavior with meta |
| 0x000A | End.S | End with next-segment processing |
| 0x000B | End.B6.Encaps.Encaps.Red | Reduced double encapsulation |
| 0x000C | End.B6.Encaps.Encaps | Double encapsulation |
| 0x000D | End.Zero | Return zero |
| 0x000E | End.Next.E | Next endpoint |
| 0x000F | End.Next.C | Next crossing |
| 0x0010+ | Custom | Operator-defined behaviors |

### 9.2.3 Behavior Classification

SRv6 behaviors fall into several categories:

**Transit Behaviors**: Process SRH and forward (End, End.X, End.T)

**Decapsulation Behaviors**: Remove outer headers and deliver inner packet (End.DX6, End.DT6)

**Encapsulation Behaviors**: Add outer headers (End.B6.Encaps, End.B6.Encaps.Red)

**Service Behaviors**: Apply service processing (VPN, FCaps, etc.)

**Utility Behaviors**: Meta operations (End.BM, End.Zero)

## 9.3 Base Transit Behaviors

### 9.3.1 End (0x0000)

The **End** behavior is the most fundamental SRv6 behavior. It represents the node itself and performs basic segment processing.

```
End SID: FC00:0:1:1::1
  Locator: FC00:0:1:1::/64
  Function: End (0x0000)
  Argument: None
```

**Processing:**

```
on receiving packet with DA = End SID:
    if Segments Left > 0:
        # Transit segment processing
        DA = Segment[Segments Left - 1]
        Segments Left = Segments Left - 1
        Forward based on new DA
    else:
        # Final destination processing
        # (this case shouldn't normally occur for End)
        Deliver to upper layer
```

**Use cases:**
- Node identification
- Path waypoint
- Simple path steering

### 9.3.2 End.X (0x0001)

**End.X** forwards the packet via a specific layer-3 neighbor, bypassing shortest-path routing. The neighbor is specified in the SID's argument.

```
End.X SID: FC00:0:1:1:1::5
  Locator: FC00:0:1:1::/64
  Function: End.X (0x0001)
  Argument: Interface ID 5 (neighbor identifier)
```

**Processing:**

```
on receiving packet with DA = End.X SID:
    if Segments Left > 0:
        DA = Segment[Segments Left - 1]
        Segments Left = Segments Left - 1
        Forward via interface specified in argument
    else:
        # Final destination
        Forward via specified interface
```

**Use cases:**
- Traffic engineering through specific links
- Load balancing across multiple paths
- Bypass constrained links

### 9.3.3 End.T (0x0002)

**End.T** performs a routing lookup in a specific IPv6 table rather than the default table.

```
End.T SID: FC00:0:1:1:2::100
  Locator: FC00:0:1:1::/64
  Function: End.T (0x0002)
  Argument: Table ID 0x100
```

**Processing:**

```
on receiving packet with DA = End.T SID:
    if Segments Left > 0:
        DA = Segment[Segments Left - 1]
        Segments Left = Segments Left - 1
        Lookup new DA in table specified by argument
        Forward based on table entry
    else:
        Lookup DA in specified table
        Forward based on table entry
```

**Use cases:**
- Multi-table forwarding (VRF-like)
- Policy-based routing
- Tenant isolation

### 9.3.4 End.S (0x000A)

**End.S** is similar to End but also marks the segment as a protected segment for segment redundancy.

**Processing:** Similar to End with additional segment protection signaling.

## 9.4 Decapsulation Behaviors

### 9.4.1 End.DX6 (0x0003)

**End.DX6** decapsulates the outer IPv6 header and SRH, delivering the inner IPv6 packet to a service.

```
End.DX6 SID: FC00:0:1:1:3::1
  Locator: FC00:0:1:1::/64
  Function: End.DX6 (0x0003)
  Argument: Interface/VLAN identifier
```

**Processing:**

```
on receiving packet with DA = End.DX6 SID:
    # Always final destination for this SID
    Strip IPv6 outer header and SRH
    Deliver inner IPv6 packet to specified interface
```

**Use cases:**
- L2VPN IPv6 access
- Service termination
- Hairpin forwarding for services

### 9.4.2 End.DX4 (0x0004)

**End.DX4** decapsulates to IPv4, enabling SRv6 to IPv4 service delivery.

```
End.DX4 SID: FC00:0:1:1:4::1
  Locator: FC00:0:1:1::/64
  Function: End.DX4 (0x0004)
  Argument: Interface/VLAN identifier
```

**Processing:**

```
on receiving packet with DA = End.DX4 SID:
    Strip IPv6 outer header and SRH
    Deliver inner IPv4 packet to specified interface
```

**Use cases:**
- SRv6 for IPv4 VPN
- IPv4 service delivery over IPv6 SR domain
- Transition scenarios

### 9.4.3 End.DT6 (0x0005)

**End.DT6** decapsulates and performs IPv6 routing lookup in a specific VRF table.

```
End.DT6 SID: FC00:0:1:1:5::100
  Locator: FC00:0:1:1::/64
  Function: End.DT6 (0x0005)
  Argument: VRF ID 0x100
```

**Processing:**

```
on receiving packet with DA = End.DT6 SID:
    Strip IPv6 outer header and SRH
    Lookup inner DA in VRF table specified by argument
    Forward based on VRF routing
```

**Use cases:**
- IPv6 VPN (6VPE)
- Tenant routing isolation
- Multi-service forwarding

### 9.4.4 End.DT4 (0x0006)

**End.DT4** decapsulates and performs IPv4 routing lookup in a specific VRF table.

```
End.DT4 SID: FC00:0:1:1:6::100
  Locator: FC00:0:1:1::/64
  Function: End.DT4 (0x0006)
  Argument: VRF ID 0x100
```

**Processing:**

```
on receiving packet with DA = End.DT4 SID:
    Strip IPv6 outer header and SRH
    Lookup inner DA (IPv4) in VRF table specified
    Forward based on VRF routing
```

**Use cases:**
- IPv4 VPN (BGP VPNv4)
- L3VPN for IPv4
- Legacy VPN migration

## 9.5 Encapsulation Behaviors

### 9.5.1 End.B6.Encaps (0x0007)

**End.B6.Encaps** encapsulates the packet in a new IPv6 header with an SRH, enabling service insertion and traffic engineering.

```
End.B6.Encaps SID: FC00:0:1:1:7::1
  Locator: FC00:0:1:1::/64
  Function: End.B6.Encaps (0x0007)
  Argument: SR Policy reference or segments
```

**Processing:**

```
on receiving packet with DA = End.B6.Encaps SID:
    # Push new outer IPv6 header
    # Push SRH with segments from argument
    # Set outer DA = first segment in new SRH
    # Set inner DA = original DA
    # Forward encapsulated packet
```

**Result:**

```
Before:
  DA = End.B6.Encaps SID
  Payload = original packet

After:
  Outer DA = first segment of new path
  Outer SRH = new segments
  Inner DA = original destination
  Payload = original packet
```

**Use cases:**
- Service function chaining
- Traffic engineering over underlay
- VPN interconnection

### 9.5.2 End.B6.Encaps.Red (0x0008)

**End.B6.Encaps.Red** is a reduced version that omits the inner IPv6 header, saving overhead.

**Processing:**

```
on receiving packet with DA = End.B6.Encaps.Red SID:
    # Push new outer IPv6 header
    # Push SRH with segments
    # Copy relevant info from original
    # Forward (inner header stripped)
```

**Use cases:**
- Same as End.B6.Encaps when inner header not needed
- Lower overhead for simple forwarding cases

### 9.5.3 End.B6.Encaps.Encaps (0x000C)

**End.B6.Encaps.Encaps** performs double encapsulation—useful for hierarchical traffic engineering.

**Processing:**

```
on receiving packet:
    Push first SRH and outer header
    Push second SRH and outer header
    Forward with double encapsulation
```

### 9.5.4 End.B6.Encaps.Encaps.Red (0x000B)

Double encapsulation with reduced inner header.

## 9.6 Utility Behaviors

### 9.6.1 End.BM (0x0009)

**End.BM** (Behavior with Meta) carries metadata for complex processing chains. It can trigger multiple behaviors based on the metadata.

```
End.BM SID: FC00:0:1:1:9::metadata
  Locator: FC00:0:1:1::/64
  Function: End.BM (0x0009)
  Argument: Metadata (variable)
```

**Processing:**

```
on receiving packet with DA = End.BM SID:
    Extract metadata from SID argument
    Execute behavior specified by metadata
    May involve multiple processing steps
```

**Use cases:**
- Complex service chains
- OAM metadata carrying
- Policy-based processing

### 9.6.2 End.Zero (0x000D)

**End.Zero** returns a zero value, used for testing and signaling.

### 9.6.3 End.Next.E (0x000E)

**End.Next.E** prepares for next endpoint processing.

### 9.6.4 End.Next.C (0x000F)

**End.Next.C** prepares for crossing processing.

## 9.7 uSID Behaviors

### 9.7.1 uSID Overview

The **Microsegment (uSID)** proposal introduces compressed SID encoding. uSID behaviors use a different format:

```
uSID Container Address:
  +---------------------------------------------------------------+
  | UC (8 bits) | uN (8 bits) | uA (8 bits) | uD (96 bits)        |
  +---------------------------------------------------------------+

  UC = uSID Carrier (0xFD)
  uN = Number of uSID components
  uA = uSID Action
  uD = uSID Block (12 uSID slots of 8 bits each)
```

### 9.7.2 uN Behavior

The **uN** behavior processes the next uSID in the container:

```
on receiving packet with DA = uSID container:
    Extract next uSID from container
    Execute uSID's behavior
    Update container DA for next processing
```

### 9.7.3 uA Behavior

The **uA** behavior identifies the action to perform on the remaining uSIDs.

### 9.7.4 uDT/uDX Behaviors

uSID also defines DT/DX variants:

- **uDT6**: uSID decap with IPv6 table lookup
- **uDT4**: uSID decap with IPv4 table lookup
- **uDX6**: uSID decap to IPv6
- **uDX4**: uSID decap to IPv4

## 9.8 Composing Behaviors: Microprograms

### 9.8.1 Concept of Microprograms

A **microprogram** is a sequence of SRv6 behaviors executed at a single node. Instead of requiring a separate SID for each step, multiple behaviors can be composed at one SID.

Example: A node needs to:
1. Decapsulate outer header
2. Lookup in VRF table
3. Forward via specific interface

Without microprograms: 3 separate SIDs at 3 different nodes
With microprograms: 1 SID at 1 node executes all 3 behaviors

### 9.8.2 Flavor Mechanism

RFC 8986 introduces **flavors** to modify behavior at the same SID:

```
End.X with Flavor:
  - End: base behavior
  - PSP: Penultimate Segment Pop
  - USP: Ultimate Segment Pop
  - USD: Ultimate Segment Decapsulation
```

Flavors are encoded in the SID's argument or as separate bits.

### 9.8.3 PSP and USP Flavors

**PSP** (Penultimate Segment Pop): The second-to-last node pops the SRH, reducing processing at the final node.

```
Penultimate node:
  if this is the last segment AND PSP is set:
      Strip SRH before forwarding
  else:
      Process normally
```

**USP** (Ultimate Segment Pop): The last segment pops the SRH before upper layer processing.

```
Last segment:
  if USP is set:
      Strip SRH
      Deliver to upper layer
  else:
      SRH may remain for upper layer to process
```

### 9.8.4 Flavor Encoding

Flavors can be encoded in:

1. **SID argument**: Some arguments include flavor bits
2. **Separate flag field**: In the SRH flags
3. **Behavior-specific encoding**: Per behavior definition

## 9.9 Custom Behaviors

### 9.9.1 Operator-Defined Behaviors

RFC 8986 reserves **0x0010 through 0xFFFF** for operator-defined behaviors. This enables:

- Vendor-specific optimizations
- Application-specific processing
- Research and experimental features

### 9.9.2 Custom Behavior Considerations

When defining custom behaviors:

1. **Function code allocation**: Coordinate within operator's space
2. **Processing documentation**: Clearly define processing steps
3. **Interoperability**: Consider cross-vendor compatibility
4. **Security**: Validate input to prevent exploits

### 9.9.3 Example Custom Behavior: End.FC

```
End.FC (Function Code = 0x0010):
  Function: FC (Flow Cache)
  Argument: Cache ID

Processing:
  on receiving packet with DA = End.FC SID:
      Check flow cache for matching entry
      If found:
          Apply cached actions
      Else:
          Compute and install new cache entry
          Process normally
```

## 9.10 Behavior Processing Examples

### 9.10.1 VPN Service Chain

Goal: Route traffic from Source through P1 (TE), through Service Node S1 (FW), to Destination

```
Segment List: [End.DT6(VRF=100) at PE2, End.B6.Encaps(FW policy) at S1, End at P1]
Reversed for SRH:
  [0] = PE2 End.DT6 SID
  [1] = S1 End.B6.Encaps SID
  [2] = P1 End SID
```

Processing:

```
At P1:
  - DA matches End SID
  - Segments Left: 3 -> 2
  - DA = Segment[1] = S1 End.B6.Encaps SID
  - Forward to S1

At S1:
  - DA matches End.B6.Encaps SID
  - Segments Left: 2 -> 1
  - Encapsulate with FW inspection policy SRH
  - DA = Segment[0] = PE2 End.DT6 SID
  - Forward to PE2

At PE2:
  - DA matches End.DT6 SID
  - Segments Left: 1 -> 0
  - Strip outer headers
  - Lookup inner DA in VRF 100
  - Forward to destination
```

### 9.10.2 Load Balancer Distribution

Goal: Distribute traffic across multiple servers using End.X

```
Segment List: [End.X(if=5), End.X(if=6), End.X(if=7)]
Reversed:
  [0] = if=7
  [1] = if=6
  [2] = if=5
```

Processing:

```
At LB node:
  First packet: DA = if=5, forward via interface 5
  Second packet: DA = if=6, forward via interface 6
  Third packet: DA = if=7, forward via interface 7
  Fourth packet: DA = if=5, repeat
```

### 9.10.3 Cross-AS SRv6

Goal: Cross multiple AS boundaries with per-AS segment lists

```
AS1: [R1_End, R2_End]
AS2: [R3_End, R4_End]
AS3: [R5_End, R6_End]

Requires stacked SRH:
  Outer SRH: AS1 segments
  Inner SRH: AS2 segments
  Innermost SRH: AS3 segments
```

## 9.11 Behavior Selection and SID Allocation

### 9.11.1 SID Planning

When allocating SIDs for behaviors:

```
Organization: Example Corp
Locator Block: 2001:db8:1234::/36

Allocation scheme:
  /48 for infrastructure
    /64 for each node
      SIDs:
        FC00:0:1:1::1 - End
        FC00:0:1:1:1::5 - End.X (interface 5)
        FC00:0:1:1:2::100 - End.T (table 256)
        FC00:0:1:1:5::100 - End.DT6 (VRF 256)
```

### 9.11.2 Function Code Registry

Maintain a registry of allocated function codes:

| Function | Code | Used By | Purpose |
|----------|------|---------|---------|
| End | 0x0000 | All nodes | Base endpoint |
| End.X | 0x0001 | All nodes | Cross-connect |
| End.T | 0x0002 | Selected | Table lookup |
| End.DX6 | 0x0003 | PE nodes | IPv6 decap |
| End.DT6 | 0x0005 | PE nodes | VRF decap |
| End.B6 | 0x0007 | Selected | Encapsulation |
| End.FC | 0x0010 | Custom | Flow cache |

## 9.12 Summary

This chapter covered SRv6 behaviors in depth:

- **Behavior architecture**: Function code identifies behavior; behaviors define packet processing
- **Transit behaviors**: End (basic), End.X (cross-connect), End.T (table lookup), End.S (protected)
- **Decapsulation behaviors**: End.DX6/DX4 (to interface), End.DT6/DT4 (to VRF table)
- **Encapsulation behaviors**: End.B6.Encaps variants for service insertion
- **Utility behaviors**: End.BM (meta), End.Zero, End.Next.E/C
- **uSID behaviors**: Compressed SID formats with uN, uA, uD variants
- **Microprograms**: Composing multiple behaviors at a single SID through flavors
- **Flavors**: PSP, USP, USD modify base behaviors
- **Custom behaviors**: Operator-defined codes 0x0010-0xFFFF
- **Composition examples**: VPN chains, load balancing, cross-AS paths

Chapter 10 will present the complete SRv6 Network Programming model, tying together segments, behaviors, and path definition into a coherent programming paradigm.

---

**References**

- RFC 8986: SRv6 Network Programming
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8402: Segment Routing Architecture
- IETF draft: SRv6 Network Programming - compressible SID format
- IETF draft: SRv6 Microsegment
