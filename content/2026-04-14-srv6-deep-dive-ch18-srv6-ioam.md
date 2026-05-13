# Chapter 18: SRv6 IOAM - In-situ Operations, Administration, and Maintenance

## 18.1 Overview

IOAM (In-situ Operations, Administration, and Maintenance) provides per-packet telemetry and performance measurement capabilities directly within the data plane, without requiring dedicated probe traffic or out-of-band measurement systems. When integrated with SRv6, IOAM leverages the segment routing header to record node identification, timestamps, and performance metrics as packets traverse the network. This chapter presents the IOAM architecture, the trace and telemetry mechanisms, how IOAM data is encoded in SRv6 packets, deployment scenarios for flow telemetry and performance measurement, the distinction between active and passive measurement approaches, and practical considerations for SRv6 IOAM deployment.

IOAM represents a fundamental shift in network observability—from end-to-end probe-based measurement (where specialized packets are sent to measure characteristics) to in-situ measurement (where the actual traffic packets carry measurement data). This shift enables measurement at the granularity of individual flows, under actual network conditions, without the overhead and timing inaccuracies of probe traffic.

## 18.2 IOAM Fundamentals

### 18.2.1 IOAM vs Traditional OAM

Traditional OAM approaches fall into two categories:

```
Out-of-Band OAM:
- Dedicated probe traffic sent through network
- ICMP ping, traceroute, TWAMP, Y.1731
- Separate from production traffic
- May not reflect actual traffic behavior

In-Band OAM (IOAM):
- Measurement data carried in production traffic
- Nodes along path add data to packets
- Records actual packet experience
- 100% coverage of measured flows

SRv6 IOAM:
- IOAM data encoded in SRH or encapsulation
- Leverages SRv6 segment processing
- Each segment node records its contribution
- Destination extracts and exports telemetry
```

### 18.2.2 IOAM Trace Types

IOAM defines multiple trace types for different measurement purposes:

```
IOAM Trace Types:
1. IOAM Trace (Full):
   - Node ID, timestamp, hop-by-hop latency
   - Interface identifiers
   - Congestion experienced (ECN)
   - Hop count

2. IOAM Trace with Sequence Numbers:
   - Above + sequence number for packet ordering
   - Detect packet reordering

3. IOAM Proof of Transit (PoT):
   - Cryptographic verification that packet traversed specified nodes
   - Detects packet modification or shortcutting

4. IOAM Edge-to-Edge (E2E):
   - Only edge nodes (ingress/egress) record data
   - Lower overhead than full trace
```

### 18.2.3 IOAM Components

IOAM involves several functional components:

```
IOAM Components:
1. IOAM encapsulating node:
   - Adds IOAM header/data to packet
   - Starts timestamp, records node ID

2. IOAM transit node:
   - Adds own data to IOAM data field
   - Records timestamp, interface info

3. IOAM decapsulating node:
   - Finalizes IOAM data
   - Exports telemetry to collection system

4. Telemetry collection system:
   - Receives exported IOAM data
   - Analyzes for performance/ troubleshooting
```

## 18.3 SRv6 IOAM Integration

### 18.3.1 SRv6 IOAM Architecture

SRv6 IOAM integrates IOAM trace capabilities with the SRv6 network programming model:

```
SRv6 IOAM Architecture:
IOAM data can be carried in three locations:
1. SRH: IOAM data in segment list entries
2. Destination Options Header: IOAM data with IPv6 options
3. Encapsulation trailer: IOAM data after payload

Common approach: IOAM data in segment list or trailer
```

### 18.3.2 IOAM Header Structure

IOAM data is organized in a Type-Length-Value (TLV) structure within the SRv6 packet:

```
IOAM Header (in SRH or trailer):
+------------------+
| Type             |  (IOAM data type)
+------------------+
| Length           |  (TLV payload length)
+------------------+
| Reserved         |
+------------------+
| Node ID          |  (48-bit node identifier)
+------------------+
| Timestamp        |  (64-bit ingress time)
+------------------+
| Transit Delay    |  (optional, transit time)
+------------------+
| Interface ID     |  (optional, egress interface)
+------------------+
| ECN              |  (optional, congestion)
+------------------+
| Hop Count        |  (optional)
+------------------+

Multiple IOAM data fields (one per node) can be chained
```

### 18.3.3 SRv6 IOAM Behaviors

SRv6 defines specific behaviors for IOAM processing:

```
End.OT (OAM Trace) Behavior:
- Applied at each segment endpoint
- Records node ID, timestamp, interface into IOAM data
- Appends IOAM data to existing trace data
- Continues with normal segment processing

End.TM (Telemetry Mark) Behavior:
- Marks packet for telemetry collection
- Triggers telemetry export at egress

End.OTP (Proof of Transit) Behavior:
- Cryptographic verification at each node
- Enables proof that packet traversed specific nodes
```

### 18.3.4 IOAM in Segment List

IOAM trace data can be recorded in segment list entries:

```
SRH with IOAM Trace Data:
Segment[0] = Node A's End.OT SID
Segment[1] = Node B's End.OT SID
Segment[2] = Node C's End.OT SID

Each node processes its segment:
1. Node A: Records A's data in Segment[0]
2. Node B: Records B's data in Segment[1]
3. Node C: Records C's data in Segment[2]

At egress:
- All segment data available
- Path traversed: A → B → C verified
```

## 18.4 IOAM Trace Mode

### 18.4.1 Trace Data Collection

IOAM trace mode records per-node data as packets traverse the network:

```
Trace Collection Process:
1. Ingress PE (Node A):
   - Start timestamp: T1
   - Node ID: A
   - Add IOAM trace header

2. Transit Node B:
   - Receive at timestamp: T2
   - Record: Node ID = B, Timestamp = T2, Ingress IF = 1
   - Transit delay: T2 - T1 (if measured)
   - Append to trace data

3. Transit Node C:
   - Receive at timestamp: T3
   - Record: Node ID = C, Timestamp = T3, Ingress IF = 2
   - Append to trace data

4. Egress PE (Node D):
   - Receive at timestamp: T4
   - Finalize trace: Node D data
   - Export full trace to telemetry collector
```

### 18.4.2 Trace Data Structure

The trace data accumulates node information:

```
IOAM Trace Data (accumulated):
After Node A: [A: T1]
After Node B: [A: T1, B: T2]
After Node C: [A: T1, B: T2, C: T3]
After Node D: [A: T1, B: T2, C: T3, D: T4]

Full Trace Record:
Node A: ingress-time=T1, egress-time=T2, node-id=A
Node B: ingress-time=T2, egress-time=T3, node-id=B
Node C: ingress-time=T3, egress-time=T4, node-id=C
Node D: (egress, final)

Analysis:
- Per-hop delay: T2-T1, T3-T2, T4-T3
- Total latency: T4 - T1
- Path verification: A → B → C → D confirmed
```

### 18.4.3 Deployment Modes

IOAM trace can operate in different deployment modes:

```
IOAM Deployment Modes:
1. Edge-to-Edge (E2E):
   - Only ingress and egress collect data
   - Transit nodes pass-through IOAM data
   - Lower overhead, only edge visibility

2. Full Trace:
   - Every node in path records data
   - Complete hop-by-hop visibility
   - Higher overhead

3. Selective:
   - Specific SIDs have IOAM capability
   - Only nodes with IOAM capability record
   - Partial path visibility

4. Hybrid:
   - Edge nodes always record
   - Transit nodes record on demand
   - Programmatic control via SID selection
```

## 18.5 IOAM Telemetry Export

### 18.5.1 Telemetry Export Mechanisms

IOAM data must be exported from the egress node to a collection system:

```
Telemetry Export Methods:
1. In-band Export:
   - IOAM data carried back to collector via separate packet
   - Egress generates export packet with IOAM data
   - Requires connectivity to collector

2. Out-of-band Export:
   - IOAM data sent via management protocol
   - gRPC, NETCONF, IPFIX
   - Independent of data plane

3. Hybrid:
   - IOAM header includes export instruction
   - Telemetry copied to export packet at egress
   - Combined in-band/out-of-band

4. Reflection:
   - Egress reflects IOAM data back to source
   - Source receives full trace
   - Useful when egress export not possible
```

### 18.5.2 Telemetry Collection Infrastructure

A typical telemetry collection infrastructure includes:

```
Telemetry Collection Components:
1. Data Collection:
   - Receives exported IOAM data
   - Stores in time-series database
   - Handles high-throughput data streams

2. Data Analytics:
   - Processes IOAM data
   - Calculates latency metrics
   - Detects anomalies

3. Visualization:
   - Dashboards for network operators
   - Per-flow, per-node metrics
   - Alerting on threshold violations

4. Integration:
   - NMS/EMS integration
   - Automation triggers
   - Ticketing systems
```

### 18.5.3 IPFIX for IOAM Export

IPFIX (IP Flow Information Export) is commonly used for IOAM telemetry:

```
IPFIX for IOAM:
- IOAM trace data exported as IPFIX records
- Template describes IOAM fields
- Options template for metadata
- High-scale export support

IPFIX Information Elements for IOAM:
- ioamTraceType
- ioamNodeId
- ioamTimestamp
- ioamTransitDelay
- ioamHopCount
- ioamEcnMark
```

## 18.6 Performance Measurement with IOAM

### 18.6.1 Latency Measurement

IOAM enables precise per-packet latency measurement:

```
Latency Measurement via IOAM:
Ingress PE (Node A):
  - Packet arrives at T_ingress
  - Encodes T_ingress in IOAM header

Transit Node B:
  - Receives at T_B_ingress
  - Records T_B_ingress
  - (Optional) records transit delay T_B_ingress - T_A_egress

Egress PE (Node D):
  - Receives at T_egress
  - Full trace available: T_ingress, T_B, T_C, T_egress
  - Calculate:
    - Per-hop delay: T_B - T_ingress, T_C - T_B, T_egress - T_C
    - Total latency: T_egress - T_ingress
    - Jitter: variation in delay over time
```

### 18.6.2 Packet Loss Measurement

IOAM can detect packet loss through sequence numbers:

```
Packet Loss Measurement:
1. Ingress PE assigns sequence number to each packet
2. Each transit node records sequence number
3. Egress PE detects gaps in sequence:
   - Sequence: 100, 101, 102, 105
   - Gap detected: 103, 104 missing
   - Packet loss at or before node that didn't record

Sequence Recording:
IOAM data includes:
  - Sequence number
  - Node ID
  - Timestamp

At egress:
  - Gap analysis reveals loss
  - Last recorded node indicates where loss occurred
```

### 18.6.3 ECN-Based Congestion Detection

IOAM can record ECN marks for congestion detection:

```
ECN Marking in IOAM:
IOAM data includes:
  - Original ECN mark from packet
  - Transit node's ECN marking decision

ECN Values:
- 00: Not ECN-capable
- 01: ECN-capable transport (ECT(0))
- 10: ECN-capable transport (ECT(1))
- 11: Congestion experienced (CE)

Congestion Analysis:
- Count CE marks per path
- Identify congested nodes
- Correlate with latency spikes
```

## 18.7 Proof of Transit (PoT)

### 18.7.1 PoT Concept

Proof of Transit verifies that a packet genuinely traversed a specified path:

```
Proof of Transit Purpose:
- Verify packet didn't skip nodes
- Detect shortcutting or path deviation
- Ensure SLA compliance

Traditional verification:
- Record each node's ID in packet
- But packet can be modified to include fake IDs

PoT solution:
- Cryptographic verification
- Each node applies function using secret
- Egress verifies using accumulated evidence
```

### 18.7.2 PoT Mechanism

PoT uses cryptographic accumulators:

```
PoT Mechanism:
1. Ingress:
   - Initialize accumulator = packet-hash
   - Add Ingress node's signature

2. Transit Nodes:
   - Each node updates accumulator
   - Secret key at each node
   - Update requires knowing secret

3. Egress:
   - Final accumulator received
   - Verify using all nodes' public keys
   - If verification passes: packet traversed all nodes
   - If verification fails: packet shortcut or modified

Mathematical basis:
- Accumulator = f(packet, secret_1, secret_2, ..., secret_n)
- Verification requires all secrets
- Missing node's secret → verification fails
```

### 18.7.3 SRv6 PoT Implementation

SRv6 PoT is implemented via the End.OTP behavior:

```
End.OTP (Proof of Transit) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Apply PoT function using local secret
   d. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Execute final PoT verification
   c. Deliver packet to upper layer
   d. Export PoT result (pass/fail)
```

## 18.8 SRv6 IOAM Configuration

### 18.8.1 Basic IOAM Configuration

```
SRv6 IOAM Configuration (IOS-XR style):
1. Enable IOAM
   ioam
     enable

2. Configure IOAM export
   ioam
     export-profile IOAM-COLLECTOR
       collector 10.0.0.100
       protocol udp
       port 4739

3. Enable IOAM on SRv6 locator
   segment-routing srv6
     locators
       locator LOC1
         ioam
           trace
           export-profile IOAM-COLLECTOR

4. Configure IOAM behavior
   segment-routing srv6
     behaviors
       end.ot
         ioam trace
         timestamp-format unix-epoch
```

### 18.8.2 Per-Flow IOAM Enablement

IOAM can be enabled selectively per traffic class or flow:

```
Per-Flow IOAM:
1. Define traffic class for IOAM
   class-map match-any IOAM-TRAFFIC
     match dscp ef

2. Enable IOAM for traffic class
   policy-map IOAM-POLICY
     class IOAM-TRAFFIC
       srv6
         ioam enable
         trace

3. Apply to interface
   interface GigabitEthernet0/0
     service-policy output IOAM-POLICY
```

### 18.8.3 Verification Commands

```
show ioam:
- IOAM capabilities and status
- Trace data buffers
- Export statistics

show ioam trace:
- Recent trace records
- Per-node timestamps
- Packet sequence numbers

show srv6 ioam:
- IOAM-enabled SIDs
- IOAM behavior associations
- Per-SID trace statistics

show ioam statistics:
- Packets with IOAM
- Export success/failure
- Memory utilization
```

## 18.9 Deployment Scenarios

### 18.9.1 Service Chain Verification

IOAM verifies traffic traverses the correct service chain:

```
Service Chain Scenario:
Traffic path: CPE → Firewall → WAN-Opt → Cloud
                A        B          C        D

IOAM Trace:
Node A: Service=FW, Action=permit
Node B: Service=WAN-Opt, Action=optimize
Node C: Service=Cloud, Action=deliver

Verification:
- Trace confirms A → B → C → D
- Missing node = service bypass
- Sequence verification
```

### 18.9.2 SLA Verification

IOAM provides SLA verification data:

```
SLA Verification:
SLA Requirements:
- Latency < 50ms
- Jitter < 10ms
- Packet loss < 0.1%

IOAM Measurement:
- Every packet carries timestamps
- Per-hop delay recorded
- Loss detected via sequence gaps
- ECN marks for congestion

SLA Reporting:
- Real-time latency charts
- Loss rate calculations
- Compliance dashboards
```

### 18.9.3 Troubleshooting

IOAM accelerates troubleshooting:

```
Troubleshooting with IOAM:
Problem: Customer reports intermittent latency spikes

Traditional troubleshooting:
1. Deploy probes
2. Wait for spike to occur in probe traffic
3. Correlate with network events
4. May miss the actual traffic spike

IOAM troubleshooting:
1. Customer traffic already has IOAM
2. Analyze recent IOAM data
3. Identify spike timing
4. Examine trace: which node added latency?
5. Immediate root cause identification

Trace Analysis:
Timestamps: 0ms, 15ms, 45ms, 100ms
Node C added 55ms (normally 5ms)
Node C = suspect
Investigate Node C → found queue buildup
```

## 18.10 SRv6 IOAM vs Alternatives

### 18.10.1 Comparison with TWAMP

| Aspect           | TWAMP             | SRv6 IOAM      |
| ---------------- | ----------------- | -------------- |
| Measurement type | Probe-based       | In-situ        |
| Traffic measured | Synthetic probes  | Actual traffic |
| Scale            | Limited flows     | Per-flow       |
| Latency accuracy | High (dedicated)  | High (in-band) |
| Deployment       | Separate protocol | Data plane     |
| Hardware support | Widely supported  | Emerging       |

### 18.10.2 Comparison with INT (Inband Telemetry)

| Aspect          | INT (P4)                   | SRv6 IOAM            |
| --------------- | -------------------------- | -------------------- |
| Platform        | P4-capable hardware        | SRv6-capable routers |
| Data location   | Packet header (INT header) | SRH or trailer       |
| Visibility      | Per-hop                    | Per-SRv6-segment     |
| Standardization | Vendor-specific            | IETF standardized    |
| Scalability     | Challenge at high rates    | Similar              |

### 18.10.3 When to Use SRv6 IOAM

SRv6 IOAM is appropriate when:

```
SRv6 IOAM Use Cases:
1. Per-flow performance measurement
   - SLA verification for critical flows
   - Real-user monitoring

2. Troubleshooting active issues
   - Rapid diagnosis without probe deployment
   - Exact path and timing for issues

3. Security verification
   - Proof of path traversal
   - Compliance auditing

4. Service chain validation
   - Verify traffic through required services
   - Detect service bypass

Not appropriate when:
- Only aggregate statistics needed (use IPFIX sampling)
- Hardware doesn't support SRv6 IOAM
- Probe-based measurement acceptable
```

## 18.11 IOAM Data Export Formats

### 18.11.1 JSON Export Format

IOAM data can be exported in JSON for modern systems:

```json
{
  "flow-id": "abc123",
  "source": "2001:db8::1",
  "destination": "2001:db8::100",
  "timestamp": "2026-04-14T12:00:00.123Z",
  "trace": [
    {
      "node-id": "PE1",
      "ingress-time": "2026-04-14T12:00:00.000Z",
      "egress-time": "2026-04-14T12:00:00.005Z",
      "interface-in": "Gi0/0",
      "interface-out": "Gi0/1",
      "ecn": "00"
    },
    {
      "node-id": "P1",
      "ingress-time": "2026-04-14T12:00:00.005Z",
      "egress-time": "2026-04-14T12:00:00.020Z",
      "interface-in": "Gi0/0",
      "interface-out": "Gi0/1",
      "ecn": "00"
    }
  ],
  "summary": {
    "total-hops": 2,
    "total-latency-ms": 20,
    "per-hop-latency": [5, 15]
  }
}
```

### 18.11.2 IPFIX Export

IPFIX provides efficient binary export:

```
IPFIX Export for IOAM:
- Template ID 256: IOAM Trace Record
- Field IDs:
  1: sourceIPv6Address
  2: destinationIPv6Address
  3: ioamTraceType
  4: ioamNodeId
  5: ioamTimestamp
  6: ioamTransitDelay
  7: ioamHopCount
- Data records follow template
- High-throughput export possible
```

## 18.12 Summary

SRv6 IOAM provides in-situ telemetry and performance measurement directly within the SRv6 data plane:

- **In-band Measurement**: IOAM data is carried in production packets, providing measurement under actual network conditions rather than synthetic probe traffic.

- **Hop-by-Hop Trace**: The IOAM trace mode records per-node data—node ID, timestamp, interface, transit delay—as packets traverse each SRv6 segment endpoint.

- **Multiple Trace Types**: IOAM supports full trace, edge-to-edge trace, proof of transit (cryptographic path verification), and selective trace for different use cases.

- **SRv6 Integration**: IOAM data is encoded in the SRH, destination options, or encapsulation trailer, with specific SRv6 behaviors (End.OT, End.TM, End.OTP) for processing.

- **Performance Metrics**: IOAM enables per-packet latency measurement, packet loss detection via sequence numbers, ECN-based congestion identification, and jitter calculation.

- **Proof of Transit**: The End.OTP behavior provides cryptographic verification that packets genuinely traversed specified paths, detecting shortcutting or modification.

- **Telemetry Export**: IOAM data is exported via IPFIX, gRPC, or other protocols to collection systems for analysis, visualization, and alerting.

- **Deployment Considerations**: SRv6 IOAM is appropriate for SLA verification, active troubleshooting, security compliance, and service chain validation where per-flow visibility is required.

IOAM completes the SRv6 VPN story by providing the operational visibility necessary to manage, troubleshoot, and optimize SRv6-based services at scale.

---

**References**

- RFC 9197: Data Fields for In-situ Operations, Administration, and Maintenance (IOAM)
- RFC 9259: Operations, Administration, and Maintenance (OAM) with Segment Routing over IPv6 (SRv6)
- RFC 9322: In-situ OAM Large LinkTrace Data (IOAM-LTD)
- RFC 9463: In-situ OAM with Proof of Transit (IOAM-PoT)
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8986: SRv6 Network Programming
- RFC 7011: IP Flow Information Export (IPFIX)
- RFC 8603: Export of Structured Data in IPFIX
- IETF draft: SRv6 IOAM Deployment Considerations
- IETF draft: IOAM Data Export with IPFIX
