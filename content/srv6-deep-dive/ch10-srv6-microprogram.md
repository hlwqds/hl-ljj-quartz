# Chapter 10: SRv6 Network Programming Model - Composing the Program

## 10.1 Overview

SRv6 represents a fundamental shift in network architecture—from **destination-based forwarding** to **network programming**. The source encodes not just a destination but a complete program specifying which nodes to visit and what processing to perform at each. This chapter presents the comprehensive SRv6 Network Programming model, showing how individual behaviors combine into powerful network programs.

We examine the programming model architecture, program composition syntax, common program patterns, and the theoretical foundations that make SRv6 a programmable data plane.

## 10.2 The Network Programming Paradigm

### 10.2.1 What is Network Programming?

**Network Programming** in SRv6 (as defined in RFC 8986) is the ability to encode a sequence of instructions—a program—that a packet executes as it traverses the network. Each instruction is a SID with an associated behavior.

```
Traditional Forwarding:
  Packet arrives → Lookup DA → Forward to next hop

SRv6 Network Programming:
  Packet arrives → Execute instruction (behavior) → Update state → Next instruction
```

### 10.2.2 Program vs Path

The distinction is important:

- **Path**: The route a packet takes (which nodes)
- **Program**: What happens at each node (which nodes + what processing)

A program includes:

1. **Segments**: Which nodes to visit (the "where")
2. **Behaviors**: What to do at each node (the "what")
3. **Arguments**: Parameters for behaviors (the "how")

### 10.2.3 Source-Defined Programs

SRv6 programs are defined at the source and encoded in the SRH. Intermediate nodes execute the program without requiring per-flow state or signaling.

```
Source Node Program Definition:
  Segment 1: R1 with behavior End.X(if=3)
  Segment 2: R2 with behavior End.DT6(vrf=100)
  Segment 3: R3 with behavior End.B6.Encaps(policy=FW)

Encoded in SRH:
  Segment List = [R3's SID, R2's SID, R1's SID]
  Segments Left = 3
```

## 10.3 Program Composition

### 10.3.1 Atomic Instructions

Each SID with behavior is an **atomic instruction**:

```
R1's End.X(if=3):
  - Atomically: process SRH, update DA, forward out if=3
R2's End.DT6(vrf=100):
  - Atomically: decap, lookup in VRF 100, forward
```

### 10.3.2 Instruction Sequence

Programs compose as sequences of atomic instructions:

```
Program: R1 → R2 → R3 → R4

SRH Segment List (reversed):
  [0] = R4
  [1] = R3
  [2] = R2
  [3] = R1

Execution:
  Hop to R1 (first segment)
  R1 executes End.X
  Hop to R2 (next segment)
  R2 executes End.T
  Hop to R3 (next segment)
  R3 executes End.B6.Encaps
  Hop to R4 (next segment)
  R4 executes End.DT6
```

### 10.3.3 Program Termination

A program terminates when:

1. All segments processed (Segments Left = 0)
2. An error occurs (malformed SRH, unknown SID)
3. A behavior explicitly terminates processing

## 10.4 Program Definition Syntax

### 10.4.1 Notation

SRv6 programs are often represented using a compact notation:

```
SRv6 Program: <S1, S2, S3, ...>

Where each Sn = LOCATOR:FUNCTION:ARGUMENT

Example:
  <FC00:0:1:1::1, FC00:0:1:2::End.DX6, FC00:0:1:3::End.B6.Encaps(FW)>
```

### 10.4.2 Visual Representation

```
Source                                 Destination
  |                                        ^
  | Program: R1 → R2 → R3 → R4             |
  |                                         |
  v                                        |
+-----+     +-----+     +-----+     +-----+     +-----+
| R1  |---->| R2  |---->| R3  |---->| R4  |---->| Dest|
|End.X|     |End.T|     |Encaps    |DT6  |     |     |
+-----+     +-----+     +-----+     +-----+     +-----+
```

### 10.4.3 Program Segments

Each segment in a program has:

1. **Locator**: Routing prefix to reach the node
2. **Function**: Behavior to execute
3. **Argument** (optional): Parameters for behavior

```
Segment = (Locator, Function, Argument)
```

## 10.5 Common Program Patterns

### 10.5.1 Simple Transit

The simplest program: just pass through nodes without special processing.

```
Program: <End at R1, End at R2, End at R3>

SRH: [R3, R2, R1]
Segments Left: 3

Processing:
  R1: End - decrement SL, update DA to R2
  R2: End - decrement SL, update DA to R3
  R3: End - decrement SL to 0, deliver to upper layer
```

### 10.5.2 Traffic Engineering

Use End.X to force specific paths:

```
Program: <End.X(if=5) at R1, End.X(if=7) at R2>

This forces traffic:
  R1 → via interface 5
  R2 → via interface 7

Instead of shortest-path routing
```

### 10.5.3 Service Insertion

Insert processing nodes in the path:

```
Program: <End.DT6(vrf=100) at PE,
          End.B6.Encaps(FW) at Firewall,
          End at P>

Packet flow:
  1. Travel to P (transit)
  2. At Firewall: encapsulate with FW policy, forward
  3. At PE: decap, lookup in VRF, deliver
```

### 10.5.4 VPN Service

Create L3VPN services with SRv6:

```
Program: <End.DT6(vrf=CustomerA) at PE2>

Source at PE1:
  1. PE1 encapsulates packet with SRH pointing to PE2
  2. Packet travels over SR domain
  3. PE2 decapsulates and looks up in VRF 100
  4. Forward based on VRF routing
```

### 10.5.5 Multi-Destination

Use segment list to reach multiple destinations:

```
Program: <End.DX6(if=4) to Host A,
          End.DX6(if=5) to Host B>

This doesn't quite work—SRH is single destination.

Alternative: Multiple packets with different SRHs,
or multicast extension headers (future work)
```

## 10.6 Advanced Program Constructs

### 10.6.1 Program Branching

SRv6 can simulate branching through multiple SIDs:

```
Program with branch:
  Segment 1: R1 (End)
  Segment 2: R2 (End) OR R3 (End)  <- not natively supported

SRv6 doesn't natively support branching.
Branching is achieved through:
  - Multiple packets with different SRHs
  - ECMP at segment endpoints
  - Programmable behaviors at endpoints
```

### 10.6.2 Program Loops

Loops are possible but typically avoided:

```
Problematic loop program:
  <R1, R2, R3, R2, R3, R2, R3...>

Issues:
  - Segments Left keeps decrementing
  - No loop counter
  - Potential infinite loops
```

Loops require careful handling with counting mechanisms.

### 10.6.3 Conditional Execution

Behaviors can implement conditional logic:

```
End.BM with metadata:
  - Metadata carries condition bits
  - Behavior interprets bits to decide action

Example:
  If metadata[0] == 1:
    Apply FW policy
  Else:
    Skip FW
```

### 10.6.4 Stateful Processing

While SRv6 itself is stateless in the data plane, stateful processing can be implemented:

```
Per-flow state at endpoints:
  - Connection tracking
  - Sequence numbers
  - Session tables

End.FC (Flow Cache) behavior:
  - First packet: compute actions, install state
  - Subsequent packets: use cached state
```

## 10.7 Program Distribution

### 10.7.1 Control Plane Distribution

SRv6 programs are distributed via:

1. **BGP**: For service SIDs (VPN, EVPN)
2. **IGP**: For topology SIDs ( End, End.X)
3. **BGP SR Policy**: For traffic engineering policies
4. **PCE**: For inter-domain path computation

### 10.7.2 BGP SRv6 Services

BGP carries SRv6 SIDs for services:

```
BGP SRv6 VPN SID:
  - Locator: From IGP
  - Function: VPN behavior (End.DT6, etc.)
  - Argument: VPN identifier (VRF ID, etc.)

BGP carries:
  - SID value
  - SID structure (L:A:F:G:AR)
  - Allocation policy
```

### 10.7.3 SR Policy

**SR Policy** (RFC 8402) is the vehicle for traffic engineering:

```
SR Policy:
  - Name/Color
  - Endpoint
  - Segment List(s)
  - Preference
  - Constraints (if any)

BGP SR Policy (draft):
  - Carries policy via BGP
  - Auto-discovery of policies
  - Distribution across domains
```

### 10.7.4 PCE Integration

Path Computation Element (PCE) computes SRv6 paths:

```
PCE responsibilities:
  - Path computation across domains
  - SID allocation
  - Policy distribution
  - Segment list optimization

PCE Communication:
  - PCEP (Path Computation Element Protocol)
  - BGP SR Policy for distribution
```

## 10.8 Program Examples in Detail

### 10.8.1 Example 1: Simple TE Path

**Goal**: Route traffic from Source to Dest via specific links

```
Topology:
  S --- R1 --- R2 --- R3 --- R4 --- D

Path required: S → R1 → R2 → R4 → D
               (bypass R3)

SRv6 Program at Source:
  <End.X(if=R1_to_R2) at R1,
   End.X(if=R2_to_R4) at R2,
   End.X(if=R4_to_D) at R4>
```

**Packet Journey:**

```
Step 1 (Source):
  DA = R1's End.X SID
  SRH: [R4_End.X, R2_End.X, R1_End.X]
  Segments Left = 3

Step 2 (R1):
  Match End.X
  Forward via R1→R2 interface
  DA = R2's End.X SID
  Segments Left = 2

Step 3 (R2):
  Match End.X
  Forward via R2→R4 interface
  DA = R4's End.X SID
  Segments Left = 1

Step 4 (R4):
  Match End.X
  Forward via R4→D interface
  DA = (final)
  Segments Left = 0

Step 5 (D receives packet via R4's forwarding)
```

### 10.8.2 Example 2: Service Function Chain

**Goal**: Route traffic through firewall and NAT

```
Topology:
  Source → R1 → Firewall → NAT → R2 → Destination

SRv6 Program:
  <End.DT6(vrf=services) at R2,
   End.B6.Encaps(NAT_policy) at NAT,
   End.B6.Encaps(FW_policy) at Firewall,
   End at R1>
```

**Processing:**

```
At R1:
  End: just transit to Firewall

At Firewall:
  End.B6.Encaps(FW_policy):
    Push new SRH with NAT and R2 segments
    Apply firewall policy to packet
    Forward to NAT

At NAT:
  End.B6.Encaps(NAT_policy):
    Apply NAT translation
    Update packet headers
    Push remaining SRH (R2)
    Forward to R2

At R2:
  End.DT6(vrf=services):
    Strip SRH
    Lookup inner DA in VRF services
    Forward to destination
```

### 10.8.3 Example 3: Cross-AS VPN

**Goal**: Connect VPN sites across multiple AS domains

```
AS1: Source Site
AS2: Transit (SRv6 domain)
AS3: Destination Site

SRv6 Program:
  <End.DT6(vrf=100) at PE_AS3,
   End at ABR_AS2,
   End at PE_AS1>
```

**Processing:**

```
AS1 PE:
  Encapsulate with full SRH
  Send to ABR_AS2

AS2 ABR:
  Transit processing (End)
  Forward based on next segment

AS3 PE:
  Final destination
  Decapsulate and deliver to VRF 100
```

### 10.8.4 Example 4: uSID Program

**Goal**: Same as Example 1 but with uSID compression

```
Locator block: FC00:0:0::/32

Nodes:
  R1: uSID 0x0001
  R2: uSID 0x0002
  R3: uSID 0x0003
  R4: uSID 0x0004

Vanilla SRv6: 4 × 128 bits = 512 bits for segments
uSID: 4 × 16 bits = 64 bits (8 bytes) for segments

uSID Container:
  FC00:0:0:0001:0002:0003:0004:0005
  |uD||uN1||uN2||uN3||uN4||uN5|

Processing:
  At each node, extract next uN from container
  Execute uN's behavior
```

## 10.9 Program Verification

### 10.9.1 Correctness Criteria

An SRv6 program should be:

1. **Valid**: All SIDs are allocated and reachable
2. **Terminable**: Will eventually reach Segments Left = 0
3. **Secure**: No unauthorized segment access
4. **Optimal**: No unnecessary segments
5. **Consistent**: Produces same result as intended

### 10.9.2 Verification Methods

```
Static verification:
  - Check all SIDs exist in registry
  - Verify locator reachability
  - Confirm behavior support at each node

Dynamic verification:
  - SRv6 Ping to test segments
  - Traceroute to verify path
  - OAM to monitor health
```

### 10.9.3 SRv6 Ping

SRv6 Ping (RFC 8986 Appendix B) verifies program execution:

```
Ping to SID:
  Source sends ICMPv6 Echo Request with SRH
  Each segment processes and returns reply
  Reply verifies:
    - SID is locally instantiated
    - Behavior is correct
    - Connectivity exists
```

## 10.10 Security Considerations

### 10.10.1 SID Validation

Nodes should validate incoming SIDs:

```
SID validation:
  1. Locator is in local or authorized range
  2. Function code is known/supported
  3. Argument is well-formed
  4. SID is authorized for this source
```

### 10.10.2 HMAC Protection

The SRH HMAC TLV provides integrity:

```
HMAC computation:
  - Covers immutable SRH fields
  - Uses shared secret
  - Key ID identifies secret

Verification:
  - If HMAC present, verify before processing
  - Drop if HMAC invalid
```

### 10.10.3 Source Authorization

Only authorized sources can use certain SIDs:

```
Authorization schemes:
  - ACLs at domain boundaries
  - Keychain authentication
  - BGPsec-like path signatures (future)
```

### 10.10.4 Anti-Spoofing

SRv6 should prevent spoofing attacks:

```
Protections:
  - Source should be reachable via its claimed locator
  - Reverse path filtering on locators
  - uSID carrier validation
```

## 10.11 Operational Best Practices

### 10.11.1 SID Allocation Strategy

Design SID allocation for operational simplicity:

```
Hierarchical allocation:
  /36 - Organization block
    /48 - Region
      /64 - Node
        /80 - Node + Function
          /96 - Node + Function + Argument

Example:
  2001:db8:1234:0001:0000:0000:0000:0001
                    |____locator____||F|
```

### 10.11.2 Documentation

Document every SID:

```
SID Registry Entry:
  SID: FC00:0:1:5::100
  Locator: FC00:0:1::/64
  Function: End.DT6 (0x0005)
  Argument: VRF ID 256 (0x100)
  Allocated: 2024-01-15
  Purpose: IPv6 VPN for Customer A
  Node: PE1
  Owner: Network Team
  Change Procedure: Request via ticket
```

### 10.11.3 Monitoring

Monitor SRv6 program execution:

```
Metrics to monitor:
  - SID reachability (ping)
  - Program latency (end-to-end delay)
  - Segment failure rate
  - SRH errors (malformed, unknown)

Tools:
  - Telemetry from nodes
  - SRv6 OAM protocols
  - BMP (BGP Monitoring Protocol)
```

### 10.11.4 Troubleshooting

Common issues and resolutions:

```
Issue: Packet loops
  Cause: Incorrect segment list order
  Fix: Verify reversed encoding in SRH

Issue: SID not found
  Cause: SID not allocated or advertised
  Fix: Check IGP/BGP SID distribution

Issue: Behavior unexpected
  Cause: Wrong function code or argument
  Fix: Verify SID structure matches behavior

Issue: Performance degradation
  Cause: Too many segments, MTU issues
  Fix: Optimize segment list, check path MTU
```

## 10.12 Future Programming Extensions

### 10.12.1 Enhanced Behaviors

Future behaviors under development:

```
Potential extensions:
  - End.DX2 (L2VPN decap)
  - End.DT6S (with service chaining)
  - End.BM.S (stateful with metadata)
  - Custom AI/ML-driven behaviors
```

### 10.12.2 Programmable Data Plane

SRv6 as foundation for programmable networks:

```
P4 + SRv6:
  - Custom parsing of SRH
  - Custom behaviors in hardware
  - In-network compute
  - Intent-based steering

Applications:
  - Custom OAM
  - Adaptive routing
  - AI inference at network nodes
```

### 10.12.3 Cross-Domain Programming

Enhanced inter-domain programs:

```
IPv4/SRv6 translation:
  - IPv4 to SRv6 encapsulation
  - SRv6 to IPv4 decapsulation
  - Seamless transition

Multi-domain path computation:
  - PCE-based multi-domain paths
  - Automatic SID allocation per domain
  - Policy-based segment selection
```

## 10.13 Summary

This chapter presented the SRv6 Network Programming model:

- **Network programming paradigm**: Source defines complete program, not just destination
- **Program composition**: Atomic behavior instructions compose into programs
- **Program definition**: Syntax for specifying segments and behaviors
- **Common patterns**: Transit, TE, service insertion, VPN, multi-destination
- **Advanced constructs**: Branching, loops, conditional execution, stateful processing
- **Program distribution**: BGP, IGP, SR Policy, PCE integration
- **Detailed examples**: Simple TE, service chains, cross-AS VPN, uSID
- **Program verification**: Static and dynamic correctness checking
- **Security**: SID validation, HMAC, authorization, anti-spoofing
- **Operations**: Allocation strategy, documentation, monitoring, troubleshooting
- **Future extensions**: Enhanced behaviors, programmable data plane, cross-domain

With Part II complete, readers now have a thorough understanding of the SRv6 protocol stack—from IPv6 extension headers through the SRH, packet processing, behaviors, and the complete network programming model.

Part III (future) will explore SRv6 Operations, including deployment patterns, migration strategies, and real-world implementation case studies.

---

**References**

- RFC 8986: SRv6 Network Programming
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8402: Segment Routing Architecture
- RFC 8402: Segment Routing Policy
- IETF draft: SRv6 Network Programming - compressible SID format
- IETF draft: BGP SR Policy
- IETF draft: PCE for SRv6
- RFC 5440: PCEP (Path Computation Element Protocol)
