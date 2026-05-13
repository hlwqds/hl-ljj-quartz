# SRv6 Deep Dive - Part II: Protocol Details

## Overview

Part II provides detailed coverage of the SRv6 protocol stack. After establishing the fundamentals in Part I, this section dissects the protocol mechanics—the IPv6 extension header architecture that hosts the Segment Routing Header (SRH), the SRH structure and encoding, packet processing flows, the behavior system that enables network programming, and the complete network programming model.

## Chapters

| Chapter | Title                                                               | Key Topics                                                                                                                                                |
| ------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 06      | [IPv6 Extension Headers](ch06-ipv6-extension-headers.md)            | Basic IPv6 header, Next Header chain, Hop-by-Hop Options, Destination Options, RH0 deprecation, Fragment, AH/ESP, SRH positioning                         |
| 07      | [SRH Structure and Fields](ch07-srh-structure.md)                   | SRH format, segment list encoding, Segments Left, Last Entry, flags, TLVs, HMAC, size calculations, stacked SRH                                           |
| 08      | [Packet Structure and Processing](ch08-packet-structure.md)         | Complete packet layout, transit vs endpoint processing, end-to-end journey, DA updates, upper layer interaction, OAM                                      |
| 09      | [SRv6 Behaviors and Microprograms](ch09-behaviors-microprograms.md) | Behavior architecture, transit behaviors (End, End.X, End.T), decapsulation (End.DX, End.DT), encapsulation (End.B6.Encaps), uSID, flavors, microprograms |
| 10      | [Network Programming Model](ch10-network-programming.md)            | Programming paradigm, program composition, syntax, common patterns, advanced constructs, program distribution, security, operations                       |

## Learning Path

Part II builds knowledge progressively from IPv6 foundations through the complete SRv6 programming model:

1. **Chapter 6** provides IPv6 extension header context—the essential background for understanding how SRH fits into the IPv6 architecture.

2. **Chapter 7** dissects the SRH itself—the core data structure encoding segment lists, metadata, and optional TLVs.

3. **Chapter 8** traces packet processing end-to-end—how transit routers forward without processing and how segment endpoints execute behaviors.

4. **Chapter 9** details the behavior system—the primitives (End, End.X, End.DT6, etc.) that define packet processing at each segment.

5. **Chapter 10** presents the network programming model—how behaviors compose into complete programs for sophisticated packet processing.

## Key Concepts Covered

### Protocol Mechanics

- IPv6 extension header chain and Next Header mechanism
- SRH structure with segment list in reversed order
- Segments Left counter for tracking progress
- Transit scalability (locator-based forwarding)

### Behavior System

- **Transit behaviors**: End, End.X, End.T, End.S
- **Decapsulation behaviors**: End.DX6, End.DX4, End.DT6, End.DT4
- **Encapsulation behaviors**: End.B6.Encaps, End.B6.Encaps.Red, double encapsulation
- **Utility behaviors**: End.BM, End.Zero, End.Next
- **uSID behaviors**: Compressed microsegment formats
- **Flavors**: PSP, USP for SRH management

### Network Programming

- Source-defined programs encoded in SRH
- Composition of atomic behavior instructions
- Common patterns: transit, TE, service chains, VPN
- Program distribution via BGP, IGP, SR Policy, PCE

## References

- RFC 8200: Internet Protocol Version 6 (IPv6) Specification
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8986: SRv6 Network Programming
- RFC 8402: Segment Routing Architecture
- RFC 5095: Deprecation of Type 0 Routing Headers
- RFC 2711: IPv6 Router Alert Option
- RFC 4302: IP Authentication Header
- RFC 4303: Encapsulating Security Payload (ESP)
- RFC 8667: IS-IS SRv6 Extensions
- RFC 8668: OSPFv3 Extensions for SRv6
- IETF draft: SRv6 Network Programming - compressible SID format
- IETF draft: SRv6 Microsegment

## Relationship to Part I

Part I (Fundamentals) established:

- Historical context (MPLS evolution)
- Segment Routing architecture and concepts
- SR-MPLS as MPLS implementation
- SRv6 origin and motivations
- SID structure (LOCATOR:FUNCTION:ARGUMENT)

Part II (Protocol) builds on this by explaining:

- How IPv6 hosts the SRH as an extension header
- Detailed SRH format and encoding
- Packet processing mechanics
- The behavior execution model
- Complete network programming paradigm

## Coming in Part III

Part III will cover SRv6 Operations including:

- Deployment patterns and migration strategies
- Hardware considerations and forwarding implementations
- OAM and troubleshooting
- Security mechanisms
- Performance optimization
- Real-world implementation case studies
