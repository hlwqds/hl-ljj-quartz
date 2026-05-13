# SRv6 Deep Dive - Part IV: SRv6 VPN

## Overview

Part IV shifts focus to SRv6's role in VPN (Virtual Private Network) architectures—how SRv6 enables Layer 2 and Layer 3 VPN services, the integration with EVPN for Ethernet services, VPLS for legacy LAN emulation, and IOAM for operational visibility. This part builds from the forwarding mechanics established in Part III to show how SRv6 delivers carrier-grade VPN services with modern programmable data planes.

## Chapters

| Chapter | Title | Key Topics |
|---------|-------|------------|
| 15 | [SRv6 VPN Overview](ch15-srv6-vpn.md) | SRv6 VPN architecture, L3VPN/BGP VPN, comparison with MPLS VPN, SRv6 VPN behaviors |
| 16 | [SRv6 EVPN](ch16-srv6-evpn.md) | EVPN integration with SRv6, ESI, LACP, DF election, multi-homing |
| 17 | [SRv6 VPLS](ch17-srv6-vpls.md) | VPLS over SRv6, MAC learning, flooding suppression, Ethernet service emulation |
| 18 | [SRv6 IOAM](ch18-srv6-ioam.md) | In-situ OAM, flow telemetry, performance measurement, SRv6 trace |

## Learning Path

Part IV builds from the programmable network layer established in Part III into service delivery:

1. **Chapter 15** introduces the SRv6 VPN architecture—how BGP carries VPN routes over SRv6 transport, the SRv6-specific behaviors (End.DT4, End.DT6) that deliver packets to the correct VRF, and the structural advantages over MPLS VPN including native IPv6 transport and simplified OAM.

2. **Chapter 16** reveals the EVPN integration with SRv6—the ESI (Ethernet Segment Identifier) framework for multi-homed CE devices, the LACP auto-discovery mechanism, and the Designated Forwarder election that prevents duplicate frames in multi-homed scenarios.

3. **Chapter 17** explains VPLS over SRv6—the emulation of Ethernet LAN services across SRv6 networks, the MAC learning mechanisms, flooding behavior, and the PW (Pseudowire) encapsulation that carries L2 frames over the SRv6 underlay.

4. **Chapter 18** presents SRv6 IOAM—the in-situ operations, administration, and telemetry that provides per-packet visibility through the SRv6 domain, enabling flow-level performance measurement and troubleshooting without dedicated probe traffic.

## Key Concepts Covered

### SRv6 VPN Architecture
- BGP L3VPN with SRv6 transport
- VPNv6 vs VPNv4 address families
- Route Target (RT) import/export
- End.DT4 and End.DT6 VPN delivery behaviors
- SRv6 encapsulation for VPN traffic
- Comparison: MPLS VPN vs SRv6 VPN

### EVPN Integration
- EVPN overview and route types
- ESI (Ethernet Segment Identifier) encoding
- LACP auto-discovery for ES
- Designated Forwarder (DF) election
- Multi-homing with all-active redundancy
- EVPN over SRv6 underlay
- Frame forwarding with EVPN

### VPLS Architecture
- VPLS service model (emulated LAN)
- Pseudowire (PW) encapsulation
- VPLS over SRv6 transport
- MAC learning in VPLS
- Flood-and-learn vs. controlled flooding
- VPLS vs EVPN comparison
- H-VPLS for scale

### IOAM and Telemetry
- In-situ OAM vs. out-of-band OAM
- IOAM trace and telemetry data
- SRv6 IOAM header integration
- Per-flow performance measurement
- Flow telemetry collection
- Active vs. passive measurement
- SRv6 trace for path verification

## Relationship to Part III

Part III established the forwarding mechanics:
- End behavior execution and segment processing
- PSP/USP flavor behavior at segment endpoints
- uSID compression for efficient hardware forwarding
- TI-LFA for fast failure protection
- SR Policy for traffic engineering

Part IV applies these toward VPN service delivery:
- How VPN traffic uses SRv6 transport
- How SRv6 endpoint behaviors deliver to VRFs
- How EVPN uses SRv6 for underlay connectivity
- How IOAM leverages SRv6's programmable header for telemetry
- How uSID compression benefits VPN scale

## References

- RFC 8986: SRv6 Network Programming (VPN behaviors)
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8402: Segment Routing Architecture
- RFC 7209: Requirements for EVPN
- RFC 7432: BGP EVPN (VLAN-Based Service)
- RFC 4761: VPLS Using BGP
- RFC 4762: VPLS Using LDP
- RFC 8300: IPv6-in-IPv6 GRE for SRv6
- IETF draft: SRv6 VPN over IPv6 underlay
- IETF draft: EVPN Integration with SRv6
- IETF draft: SRv6 IOAM
