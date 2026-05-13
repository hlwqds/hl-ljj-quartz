# SRv6 Deep Dive - Part V: Traffic Engineering

## Overview

Part V shifts focus to traffic engineering—the mechanisms that give operators fine-grained control over how traffic flows through the SRv6 network. Building on the forwarding foundations of Part III and the VPN services of Part IV, Part V presents FlexAlgo for constraint-based IGP path computation, SR-TE for end-to-end traffic engineering, traffic steering with failure protection, and traffic matrix measurement for continuous TE optimization.

## Chapters

| Chapter | Title | Key Topics |
|---------|-------|------------|
| 19 | [FlexAlgo](ch19-flex-algo.md) | Flexible Algorithm, IGP algorithm constraints, delay/bandwidth priority, affinity-based routing |
| 20 | [SR-TE](ch20-sr-te.md) | SR-TE tunnels, path computation, PCE/PCC architecture, traffic steering |
| 21 | [Traffic Steering](ch21-steering.md) | LFA/RLFA/TI-LFA, ECMP, UCMP, failure protection mechanisms |
| 22 | [Traffic Matrix](ch22-sr-traffic-matrix.md) | Traffic matrix measurement, TE optimization, automated tuning |

## Learning Path

Part V builds from path control to traffic engineering:

1. **Chapter 19 (FlexAlgo)** explains how IGP's algorithm field enables multiple constraint-based path computations within the same IGP instance—latency-optimized, bandwidth-aware, and affinity-constrained paths computed from the same topology database.

2. **Chapter 20 (SR-TE)** presents the end-to-end traffic engineering architecture built on SR Policy and FlexAlgo foundations—how PCE/PCC computes and distributes TE paths, the tunnel model, and how SR-TE achieves scalability through source-based path programming.

3. **Chapter 21 (Traffic Steering)** examines how the ingress node selects among candidate paths using color-based steering, how ECMP provides natural load distribution, and how failure protection mechanisms (LFA, RLFA, TI-LFA) intercept steering decisions to redirect around failures with sub-50ms convergence.

4. **Chapter 22 (Traffic Matrix)** reveals how operators measure, analyze, and leverage traffic demand data—using NetFlow/IPFIX, IOAM, and interface telemetry to build real-time traffic matrices that drive automated TE optimization and capacity planning.

## Key Concepts Covered

### FlexAlgo
- Algorithm field in SID advertisements (0-127)
- Metric types: IGP, TE, latency, hop count
- Affinity constraints: include, exclude, include-any
- SRLG exclusion and multi-constraint paths
- FlexAlgo integration with SRv6 SIDs

### SR-TE Architecture
- Source-based TE vs. RSVP-TE comparison
- SR Policy tunnel model
- PCE/PCC architecture and PCEP protocol
- Candidate path selection and protection
- Traffic steering mechanisms (color, prefix, flow)
- Multi-domain SR-TE considerations

### Traffic Steering
- Steering resolution process at ingress
- ECMP and weighted ECMP (UCMP)
- LFA: loop-free alternate fundamentals and limitations
- RLFA: remote LFA extending coverage with tunnels
- TI-LFA: 100% coverage via segment list-based backup
- Multi-layer protection: local LFA + TI-LFA + re-optimization

### Traffic Matrix
- Traffic matrix definition and structure
- Measurement approaches: NetFlow/IPFIX, SNMP, IOAM
- OD pair and temporal analysis
- Demand-aware path selection and load balancing
- Closed-loop automation with PCE
- Safety mechanisms for automated tuning

## References

- RFC 9479: IS-IS Flexible Algorithm
- RFC 9256: Segment Routing Policy Architecture
- RFC 4657: PCE Communication Protocol (PCEP)
- RFC 8402: Segment Routing Architecture
- RFC 8944: IS-IS Traffic Engineering (TE) Extensions for FlexAlgo
- RFC 8986: SRv6 Network Programming
- RFC 7752: BGP-LS for TED
- RFC 8570: IS-IS Traffic Engineering (TE) Metric Extensions

## Relationship to Other Parts

Part V connects to prior and subsequent parts:

**From Part III (Forwarding):**
- Chapter 14 (SR Policy) provides the control-plane framework that SR-TE builds upon
- Chapter 13 (TI-LFA) details the protection mechanism referenced in traffic steering

**From Part IV (VPN):**
- SR-TE commonly engineers VPN traffic for SLA compliance
- Traffic matrix measurement applies to VPN services

**To Part VI (Cloud):**
- Cloud connectivity relies on SR-TE for path control
- Traffic engineering enables cloud interconnect SLAs
- Global traffic matrix informs inter-cloud capacity planning
