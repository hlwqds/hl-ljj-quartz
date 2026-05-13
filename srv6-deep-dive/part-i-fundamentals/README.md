# SRv6 Deep Dive - Part I: Fundamentals

## Overview

Part I establishes the foundational knowledge required to understand SRv6, tracing the evolution from ATM through MPLS to Segment Routing, and explaining the architecture, data planes, and SID structure that underpin modern SRv6 deployments.

## Chapters

| Chapter | Title | Key Topics |
|---------|-------|------------|
| 01 | [MPLS Evolution](ch01-mpls-evolution.md) | ATM history, MPLS architecture, RSVP-TE, BGP/MPLS VPNs, scaling challenges |
| 02 | [Segment Routing Overview](ch02-sr-overview.md) | Core concepts, segment types, SID semantics, TI-LFA, SR architecture |
| 03 | [SR-MPLS](ch03-sr-mpls.md) | SR over MPLS data plane, label stack as segment list, PCE integration, migration |
| 04 | [SRv6 Origin](ch04-srv6-origin.md) | IPv6 motivation, SRH specification, RH0 deprecation, network programming vision |
| 05 | [SID Structure](ch05-sid-structure.md) | LOCATOR:FUNCTION:ARGUMENT format, behaviors, uSID compression, allocation |

## Learning Path

Part I establishes prerequisites:

1. **Chapter 1** provides historical context—understanding MPLS's evolution illuminates why Segment Routing took the form it did.

2. **Chapter 2** introduces Segment Routing's core concepts—segments, SID types, and path composition—that apply to both SR-MPLS and SRv6.

3. **Chapter 3** examines how SR operates over the existing MPLS data plane, providing a bridge between traditional MPLS and SRv6.

4. **Chapter 4** explains why IPv6 was chosen as the foundation for next-generation SR, detailing the SRH and the motivations that drove SRv6 design.

5. **Chapter 5** dissects the SRv6 SID—its 128-bit structure, encoding schemes, and behavior system—preparing readers for Part II's exploration of SRv6 network programming.

## References

- RFC 8402: Segment Routing Architecture
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8986: SRv6 Network Programming
- RFC 8667: IS-IS SRv6 Extensions
- RFC 8668: OSPFv3 Extensions for SRv6
- RFC 3031: Multiprotocol Label Switching Architecture
- RFC 3209: RSVP-TE Extensions
- RFC 4364: BGP/MPLS IP VPNs