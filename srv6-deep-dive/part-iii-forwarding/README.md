# SRv6 Deep Dive - Part III: Forwarding Mechanisms

## Overview

Part III shifts focus from the protocol layer to the data plane—how SRv6 packets are actually forwarded through the network, how microsegments (uSID) compress SID encoding for efficient hardware implementation, how TI-LFA provides ultrafast failure protection, and how SR Policies provide sophisticated traffic engineering through software-defined path control.

## Chapters

| Chapter | Title | Key Topics |
|---------|-------|------------|
| 11 | [SRv6 Forwarding Process](ch11-srv6-forwarding.md) | PSP/USP/ST flavors, Upper/Lower HL, HL=0 processing, transit behavior details |
| 12 | [SRv6 Vanity SID](ch12-srv6-vanity.md) | uSID format, uN/uSF/uA, compression benefits, hardware implementation |
| 13 | [TI-LFA Protection](ch13-ti-lfa.md) | Topology-Independent LFA, post-convergence path, SRv6 fast reroute |
| 14 | [SR Policy](ch14-sr-policy.md) | SR Policy architecture, candidate paths, optimization objectives, steering |

## Learning Path

Part III builds from the protocol mechanics established in Part II into operational realities:

1. **Chapter 11** dissects the actual forwarding process—how routers process SRH at each hop, the PSP/USP/ST flavor variants that govern segment stripping, and the Upper/Lower Header Stack (HL) mechanics that handle nested SRv6 encapsulation.

2. **Chapter 12** reveals how uSID (microSID) compression dramatically reduces SID size overhead, enabling practical hardware forwarding with 32-bit compressed microsegments while maintaining the full programmability of the 128-bit SID model.

3. **Chapter 13** presents TI-LFA—the topology-independent LFA mechanism that provides sub-50ms failure protection for SRv6 paths, computed entirely from the segment list without requiring per-prefix loop-free alternates.

4. **Chapter 14** explains SR Policy—the control-plane architecture that programs segment lists onto packets, manages candidate paths and their preferences, and optimizes traffic placement according to user-defined objectives.

## Key Concepts Covered

### Forwarding Mechanics
- Transit processing: DA update, SL decrement, SRH inspection
- PSP (Penultimate Segment Pop): strip SRH at endpoint
- USP (Ultimate Segment Pop): preserve SRH for service chain visibility
- ST (Segmentation Trailer): optional trailer for OAM and metadata
- Upper/Lower HL boundaries: layered SRv6 encapsulation
- HL=0 processing: transit through encapsulation layer

### uSID Compression
- 16-bit function code in 32-bit uN microsegment
- uN (microNode-SID): single-hop compression
- uSF (microService-Function): chainable service segments
- uA (microAdapter): interface-specific operations
- 128-bit to 32-bit compression ratio
- Hardware FIB optimization

### Fast Failure Protection
- Loop-Free Alternate (LFA): pre-computed backup next-hop
- Topology-Independent LFA: per-segment backup via SR policy
- Remote LFA (RLFA): tunnel to PQ node for non-LFA coverage
- Post-convergence path: pre-installed alternate path
- TI-LFA construction from segment list
- 50ms protection switching requirements

### SR Policy Architecture
- SR Policy components: segment list, candidate paths, preference
- Dynamic vs. explicit SR Policy
- Candidate path attributes: protocol origin, preference, weight
- Optimization objectives: TE, delay, minimize hops, load-balancing
- Path computation: PCC, PCE, distributed
- Traffic steering mechanisms
- Binding SID (BSID): indirection for policy selection

## References

- RFC 8986: SRv6 Network Programming
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8402: Segment Routing Architecture
- RFC 8402: Segment Routing Architecture (LFA section)
- RFC 9256: Segment Routing Policy Architecture
- RFC 9002: Generic TLV for SR Policy
- IETF draft: SRv6 Microsegment (uSID)
- IETF draft: SRv6 Security Considerations

## Relationship to Part II

Part II established the protocol structures:
- IPv6 extension header architecture
- SRH format and segment list encoding
- Behavior system (End, End.X, End.DT6, etc.)
- Network programming model

Part III applies these toward forwarding realities:
- How behaviors execute in hardware
- How uSID compression enables practical deployment
- How SRv6 achieves carrier-grade reliability
- How SR Policy programs paths through the network
