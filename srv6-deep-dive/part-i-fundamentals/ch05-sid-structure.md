# Chapter 5: SRv6 SID Structure - Format, Components, and Encoding

## 5.1 Overview

The SRv6 Segment Identifier (SID) is the fundamental atom of SRv6 network programming. Unlike SR-MPLS where a SID is merely a 20-bit label index, an SRv6 SID is a full 128-bit IPv6 address that encodes both **where** a segment is located and **what** processing should occur. This chapter dissects the SID structure, its functional components, and the encoding schemes that enable SRv6's programmability.

## 5.2 The 128-bit SRv6 SID

### 5.2.1 Basic Structure

An SRv6 SID is a 128-bit IPv6 address, structured as three functional parts:

```
+---------------------------------------------------------------+
|                        128 bits                               |
+---------------+-----------------------+-----------------------+
|   LOCATOR     |      FUNCTION         |       ARGUMENT        |
|   (variable)  |      (16 bits)        |       (variable)       |
+---------------+-----------------------+-----------------------+
| <-- N bits -->|<----- 16 bits ------>|<----- M bits --------->|
                |                       |
                +-----------------------+
                        128 - N bits
```

1. **LOCATOR**: Identifies the node or area where the SID is instantiated. Used for routing the packet toward the SID's location.

2. **FUNCTION**: Identifies the behavior to be executed at the node where the SID is active.

3. **ARGUMENT** (optional): Carries parameters or context for the function. Not all SIDs have arguments.

### 5.2.2 Locator (N bits)

The **Locator** is the routing prefix that allows the packet to reach the SID's owning node. It functions analogously to an IPv6 address prefix in standard routing.

Key properties:

- **Globally unique within the SR domain**: The locator identifies a specific node (or anycast group).
- **Advertised in IGP/BGP**: Like a loopback address, the locator is distributed through routing protocols.
- **Provides reachability**: The locator's prefix ensures packets reach the correct node for processing.

Typical locator sizes:

| Prefix Length | Bits for Function+Arg | Example                          |
| ------------- | --------------------- | -------------------------------- |
| /48           | 80                    | Large deployments with many SIDs |
| /64           | 64                    | Standard node locator            |
| /80           | 48                    | Function-rich deployments        |
| /96           | 32                    | Heavy function/argument use      |

### 5.2.3 Function (16 bits)

The **Function** is a 16-bit identifier that specifies the behavior at the node. RFC 8986 defines a base set of behaviors:

| Function Code | Name              | Description                           |
| ------------- | ----------------- | ------------------------------------- |
| 0x0000        | End               | Transit through node (SRv6 endpoint)  |
| 0x0001        | End.X             | Forward via specific layer-3 neighbor |
| 0x0002        | End.T             | Lookup in specific IPv6 table         |
| 0x0003        | End.B6.Encaps     | Encapsulate and forward               |
| 0x0004        | End.B6.Encaps.Red | Reduced encapsulation                 |
| 0x0005        | End.BM            | Behavior with Meta                    |
| 0x0006-0xFFFF | Flex              | Operator-defined behaviors            |

These base behaviors are the primitives from which complex network programs are composed.

### 5.2.4 Argument (Variable)

The **Argument** portion carries additional context or parameters for the function. Its presence and format depend on the specific function type:

- Some functions have no argument (argument length = 0)
- Some functions have fixed-length arguments
- Some functions have variable-length arguments encoded in the function field

The argument might carry:

- VPN identifier
- QoS parameters
- Traffic engineering constraints
- OAM metadata
- Application-specific context

## 5.3 SID Address Format Examples

### 5.3.1 Basic End SID

```
Locator: FC00:0:1:/64
Function: End (0x0000)
Argument: None

SID = FC00:0:1:0000:0000:0000:0000:0001
         |_________locator________|F|

Full address: FC00:0:1::1/128
```

When a node receives a packet with DA = FC00:0:1::1:

1. The node recognizes FC00:0:1::/64 as its locator prefix
2. The full address matches its End SID
3. The node decrements Segments Left in the SRH
4. The node updates DA to the next segment in the SRH
5. The node forwards the packet

### 5.3.2 End.X SID with Argument

```
Locator: FC00:0:1:/64
Function: End.X (0x0001) - forward via specific neighbor
Argument: Interface identifier (16 bits)

SID = FC00:0:1:0001:0000:0000:0000:0005
         |________loc________|F|Arg

Full address: FC00:0:1:1::5/128
```

The argument `0005` might encode "forward out interface ID 5."

### 5.3.3 VPN SID

```
Locator: FC00:0:2:/64 (PE2's locator)
Function: End.FM (0x0005) - End with VPN Forwarding Context
Argument: VRF ID (16 bits)

SID = FC00:0:2:0005:0000:0000:0000:00VRF
         |________loc________|F|Arg = VRF ID

Full address: FC00:0:2:5::100/128 (for VRF 0x100)
```

When PE2 processes this SID:

1. The SID identifies VRF 0x100 on PE2
2. The packet is matched against VRF 0x100's forwarding table
3. The packet is forwarded based on VRF routing

## 5.4 SID Encoding Schemes

### 5.4.1 Vanilla SRv6 (RFC 8986)

The standard encoding uses the full 128-bit SID as described above. Each SID is a unique IPv6 address allocated from the operator's IPv6 address space.

```
Advantages:
  - Clear semantic separation (Locator/Function/Arg)
  - Standardized in RFC 8986
  - Human-readable addresses

Disadvantages:
  - 128 bits per SID can be inefficient
  - Large SID blocks required for dense populations
  - Transit routers must store full 128-bit entries
```

### 5.4.2 Microsegment (uSID) -draft-ietf-spring-srv6-net-pgm-extension

Cisco's **Microsegment (uSID)** proposal dramatically reduces SID storage requirements by encoding multiple micro-SIDs in a single 128-bit address.

```
uSID Format:
  +---------------------------------------------------------------+
  | UC (8 bits) | uN (8 bits) | uA (8 bits) | uD (96 bits)        |
  +---------------------------------------------------------------+

  UC = uSID Carrier (0xFD)
  uN = Number of uSID components
  uA = uSID Action (behavior selector)
  uD = uSID Block (up to 12 uSID carriers)
```

Each uSID is only 16 bits (plus a shared uD block), enabling dense SID allocation:

```
uD block: FC00:0:0
uSID 1 (at R1): 0x0001 → FC00:0:0:1::/48
uSID 2 (at R2): 0x0002 → FC00:0:0:2::/48
uSID 3 (at R3): 0x0003 → FC00:0:0:3::/48

Full uSID container:
  FC00:0:0:0001:0002:0003:0004:0005
  |uD||uN1||uN2||uN3||uN4||uN5|
```

In this example, five 16-bit micro-SIDs are encoded in a single 128-bit address, each representing a segment to be processed sequentially.

### 5.4.3 uSID vs. Vanilla SRv6 Comparison

| Aspect               | Vanilla SRv6 | uSID              |
| -------------------- | ------------ | ----------------- |
| SID size (effective) | 128 bits     | 16 bits           |
| SID allocation       | Per-SID IPv6 | Block-based       |
| Transit FIB entries  | Full 128-bit | Compressed blocks |
| Human readability    | High         | Low               |
| Standardization      | RFC 8986     | IETF draft        |

uSID is particularly attractive for:

- Large-scale networks with many SIDs
- Hardware platforms with limited TCAM
- Environments where SID compression provides operational benefits

## 5.5 SID Reachability and Distribution

### 5.5.1 Locator Reachability

The Locator portion of a SID must be reachable via standard IPv6 routing. The IGP (IS-IS or OSPF) advertises locator prefixes, ensuring any SID with a given locator prefix is reachable.

```
R1 advertises locator FC00:0:1::/64
  - IGP installs /64 route to R1
  - Any packet to FC00:0:1:* reaches R1
  - R1 then processes based on Function bits
```

### 5.5.2 IGP SID Advertisement

RFC 8667 (IS-IS SRv6) and RFC 8668 (OSPFv3 SRv6) define how SRv6 SIDs are advertised:

```
IS-IS SRv6 Locator TLV:
+-------------------------------+
| Type = 1                      |
+-------------------------------+
| Length                        |
+-------------------------------+
| Flags                         |
+-------------------------------+
| MT                           |
+-------------------------------+
| Sub-TLVs:                    |
+-------------------------------+
  - SRv6 Locator Algorithm
  - SRv6 Locator Metric
  - SRv6 Prefix SID (optional)

SRv6 Prefix SID sub-TLV:
+-------------------------------+
| Type                          |
+-------------------------------+
| Length                        |
+-------------------------------+
| Flags                         |
+-------------------------------+
| MT                           |
+-------------------------------+
| Algorithm                     |
+-------------------------------+
| Locator Block Length (8 bits) |
| Locator Node Length (8 bits) |
| Function Length (8 bits)     |
| Argument Length (8 bits)     |
+-------------------------------+
| Node Suffix                   |
+-------------------------------+
```

### 5.5.3 BGP SRv6 SID

BGP can carry SRv6 SIDs for services (VPN, EVPN) and for inter-AS scenarios:

```
BGP SRv6 Service GUID sub-TLV:
  - ServID: Service identifier
  - SID Structure: L:A:F:G:AR
  - Per-Destination SID allocation
```

## 5.6 SID Behaviors in Detail

### 5.6.1 End (Endpoint)

The most fundamental SRv6 behavior. An **End** SID represents the node itself.

```
Packet arrives at node with DA = End SID

Processing:
1. If Segments Left > 0:
   a. Update DA = Segment[Segments Left]
   b. Decrement Segments Left
   c. Forward based on new DA
2. If Segments Left = 0:
   a. Strip SRH
   b. Process upper-layer header (layer 4+)
```

### 5.6.2 End.X (Endpoint with Layer-3 Cross-Connect)

**End.X** forwards the packet via a specific neighbor, bypassing shortest-path routing.

```
Packet arrives at node with DA = End.X SID (pointing to neighbor N)

Processing:
1. If Segments Left > 0:
   a. Update DA = Segment[Segments Left]
   b. Decrement Segments Left
   c. Forward to neighbor N (specified by SID argument)
2. If Segments Left = 0:
   a. Strip SRH
   b. Forward to neighbor N
```

### 5.6.3 End.T (Endpoint with Specific IPv6 Table)

**End.T** performs a lookup in a specific IPv6 routing table rather than the default table.

```
Packet arrives at node with DA = End.T SID (table T)

Processing:
1. If Segments Left > 0:
   a. Update DA = Segment[Segments Left]
   b. Decrement Segments Left
   c. Lookup DA in table T
   d. Forward according to table T's entry
2. If Segments Left = 0:
   a. Lookup DA in table T
   b. Forward according to table T's entry
```

This enables:

- Multi-table forwarding (VRF-like isolation)
- Policy-based routing
- Traffic engineering through specific tables

### 5.6.4 End.B6.Encaps (Endpoint to BH Encapsulation)

**End.B6.Encaps** encapsulates the packet in an outer IPv6 header with a new SRH, then forwards.

```
Packet arrives at node with DA = End.B6.Encaps SID

Processing:
1. Push new outer IPv6 header
2. Push SRH with segments for next processing
3. Set outer DA to first segment
4. Set inner DA to original DA
5. Forward encapsulated packet
```

This enables:

- Service chain insertion
- Traffic engineering over underlays
- VPN encapsulation

### 5.6.5 End.B6.Encaps.Red (Reduced Encapsulation)

A variant of End.B6.Encaps that omits the inner IPv6 header, reducing overhead.

### 5.6.6 End.BM (Behavior with Meta)

**End.BM** combines multiple behaviors and carries metadata for complex processing chains.

## 5.7 SID Allocation Best Practices

### 5.7.1 Locator Planning

```
SRv6 Locator Allocation Example:

Organization: Example Corp (AS 65000)
Locator Block: 2001:db8:1234::/36

Division by function:
  /48 for infrastructure (loopbacks, links)
  /48 for services (VPN, Internet)
  /48 for overlays (cloud interconnect)

Division by region:
  /56 for each region (Americas, EMEA, APAC)

Division by node:
  /64 for each node

Example R1 locator:
  2001:db8:1234:0001::/64
```

### 5.7.2 Function Allocation

Define a function allocation scheme across the organization:

```
Function code allocation:
  0x0000: End (base)
  0x0001: End.X
  0x0002: End.T
  0x0003-0x000F: Standard functions
  0x0010-0x00FF: VPN functions
  0x0100-0xFFFF: Custom/operator-specific
```

### 5.7.3 SID Documentation

Every SID should be documented with:

- Full 128-bit address
- Locator/Function/Argument breakdown
- Behavior description
- Where allocated (which node)
- Purpose and usage context
- Operational notes (change procedures, dependencies)

## 5.8 Transit Processing

### 5.8.1 FIB Entry for Locator

Transit routers need only install the locator prefix in their FIB—not every individual SID:

```
R2 transit processing for SID FC00:0:1:1::5:

1. R2 receives packet, DA = FC00:0:1:1::5
2. R2 performs longest-prefix match: FC00:0:1::/64
3. R2 forwards to R1 (locator owner)
4. R2 does NOT need to know about End.X behavior
   (that's R1's local processing)
```

This is a critical scalability insight: transit routers forward based on locator only; only the locator owner needs to understand the function.

### 5.8.2 Partial Fib

When using vanilla SRv6 with long locator prefixes (e.g., /64), transit routers must install more specific routes. When using uSID with compressed blocks, transit routers can aggregate more effectively.

## 5.9 Summary

This chapter dissected the SRv6 SID structure:

- **128-bit structure**: The SRv6 SID comprises LOCATOR (routing prefix), FUNCTION (16-bit behavior), and optional ARGUMENT (parameters)—all within a single IPv6 address.

- **Locator**: The routing prefix that ensures the packet reaches the SID's owning node. IGP advertises locator prefixes for reachability.

- **Function**: The 16-bit behavior selector defining what processing occurs. Base behaviors (End, End.X, End.T, End.B6.Encaps, etc.) are standardized in RFC 8986.

- **Argument**: Optional parameter field carrying context (VPN ID, interface ID, etc.) for the function.

- **Encoding schemes**: Vanilla SRv6 uses full 128-bit addresses; uSID compresses multiple 16-bit micro-SIDs into a single 128-bit container for efficiency.

- **Transit scalability**: Only the locator is visible to transit routers; function processing is local to the SID owner.

- **SID distribution**: IGP extensions (IS-IS SRv6, OSPFv3 SRv6) and BGP carry SID information for reachability and service instantiation.

With this understanding of SID structure, Part I of the SRv6 Deep Dive is complete. Part II will explore advanced SRv6 concepts including network programming, service chaining, and operational patterns.

---

**References**

- RFC 8986: SRv6 Network Programming
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8667: IS-IS SRv6 Extensions
- RFC 8668: OSPFv3 Extensions for SRv6
- RFC 8402: Segment Routing Architecture
- draft-ietf-spring-srv6-net-pgm-extension: SRv6 Network Programming - compressible SID format
