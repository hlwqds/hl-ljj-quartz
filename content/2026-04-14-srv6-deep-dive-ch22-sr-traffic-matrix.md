# Chapter 22: SR Traffic Matrix - Measurement, Analysis, and Optimization

## 22.1 Overview

The traffic matrix represents the volume of traffic flowing between each origin-destination pair in a network. Understanding the traffic matrix is fundamental to traffic engineering: without accurate traffic demand data, engineers cannot determine whether the network has sufficient capacity, whether traffic is properly balanced across paths, or whether TE policies achieve their objectives. In SRv6 networks, the traffic matrix informs path computation, validates TE policy effectiveness, and triggers re-optimization when utilization patterns change.

This chapter presents traffic matrix fundamentals in the SRv6 context: how traffic matrices are measured using telemetry and flow collection, how the traffic matrix enables TE optimization including bandwidth-aware path selection and load balancing, how automated TE tuning continuously adjusts SR Policies based on measured demands, and practical considerations for deploying traffic matrix measurement in production networks.

## 22.2 Traffic Matrix Fundamentals

### 22.2.1 What is a Traffic Matrix?

The traffic matrix captures traffic demand between network points:

```
Traffic Matrix Definition:

A traffic matrix TM is a 3-dimensional structure:
TM[origin, destination, class] = traffic volume

Where:
- origin: ingress point (router, interface, or prefix)
- destination: egress point (router, interface, or prefix)
- class: traffic class (QoS queue, DSCP, or application type)
- traffic volume: bits per second or packets per second

Example 2x2 Traffic Matrix:
                Dest: DC1    Dest: DC2
Origin: Site-A    10 Gbps     5 Gbps
Origin: Site-B    3 Gbps      8 Gbps

Class-Differentiated Matrix:
                Dest: DC1    Dest: DC2
Origin: Site-A
  Real-time      2 Gbps      1 Gbps
  Best-effort    8 Gbps      4 Gbps
```

### 22.2.2 Traffic Matrix in SRv6 Context

SRv6 changes how traffic matrices are used:

```
Traditional TE Traffic Matrix:
- Used to compute LSP bandwidth allocation
- Input to offline planning tools
- Updated infrequently (daily/weekly)

SRv6 TE Traffic Matrix:
- Real-time or near-real-time measurement
- Continuous input to dynamic TE
- Informs SR Policy candidate path selection
- Triggers automated re-optimization

SRv6 Advantages:
1. Per-Prefix Visibility:
   - Each destination prefix is observable
   - SID identifies specific service
   - Fine-grained demand measurement

2. Path Transparency:
   - Segment list reveals exact path
   - Easy correlation of demand to path
   - Direct validation of TE policy

3. Per-Class Measurement:
   - DSCP preserved through SRv6 domain
   - Class-level traffic matrix possible
   - Per-QoS optimization
```

### 22.2.3 Traffic Matrix Components

```
Traffic Matrix Components:

1. Origin Identification:
   - Ingress router
   - Input interface
   - Source prefix
   - Application ID (if available)

2. Destination Identification:
   - Egress router
   - Output interface
   - Destination prefix
   - VPN/VRF

3. Traffic Characteristics:
   - Volume (bps, pps)
   - Burstiness
   - Flow count
   - Packet size distribution

4. Path Information:
   - SID used
   - Segment list traversed
   - ECMP member selected
   - Forwarding class

5. Time Dimension:
   - Momentary (real-time)
   - Average (over interval)
   - Peak (daily/weekly/monthly)
```

## 22.3 Traffic Matrix Measurement

### 22.3.1 Measurement Approaches

Multiple methods exist for traffic matrix measurement:

```
Measurement Method Comparison:

| Method           | Granularity | Overhead | Accuracy    |
|------------------|-------------|----------|-------------|
| NetFlow/IPFIX    | Flow-level | Medium   | High        |
| SNMP Interface   | Interface  | Low      | Medium      |
| TWAMP            | Path-level | Medium   | High        |
| IOAM             | Packet-level| Low     | Very High   |
| BGP Flow Spec    | Rule-level | Low      | Low         |
| Segment Routing  | SID-level  | Low      | High        |
| Telemetry        | Real-time  | Medium   | High        |

Best Practice: Combine multiple methods
- NetFlow/IPFIX for flow details
- Interface counters for validation
- IOAM for path verification
```

### 22.3.2 NetFlow/IPFIX Collection

Flow collectors capture traffic demand:

```
NetFlow/IPFIX for Traffic Matrix:

Flow Record Fields:
- Source/Destination IP
- Source/Destination Port
- Protocol
- ToS/DSCP
- Input/Output Interface
- Byte/Packet Count
- Start/End Time

SRv6-Aware Flow Export:
- Export outer IPv6 addresses (SRv6 header)
- Export SRH information if present
- Export actual segment list (if preserved)

Collection Architecture:
[Ingress PE] --IPFIX--> [Collector] ---> [TE Server]
                                   |
                                   v
                              [Traffic Matrix]

Collector aggregates:
- Per (src, dst, dscp) -> volume
- Per (ingress, egress, class) -> volume
```

### 22.3.3 Interface SNMP Measurement

Interface counters provide basic measurement:

```
SNMP Interface Counting:

Counters Available:
- ifHCInOctets / ifHCOutOctets
- ifHCInUcastPkts / ifHCOutUcastPkts
- ifInNUcastPkts / ifOutNUcastPkts
- ifInErrors / ifOutErrors

Traffic Matrix Derivation:
- Measure at each interface
- Infer origin-destination from IGP topology
- Use BGP AS-path for finer granularity

 Limitations:
- No per-flow visibility
- No DSCP breakdown
- Requires topology inference
- Sampled collection (1:1000 typical)

Use Case:
- Capacity planning
- Link utilization monitoring
- Anomaly detection
```

### 22.3.4 IOAM for Path Measurement

IOAM (Chapter 18) provides precise path telemetry:

```
IOAM-Based Traffic Matrix:

IOAM Trace Data:
- Per-packet timestamp at each node
- Node ID at each hop
- Interface information
- ECN marks

Traffic Matrix from IOAM:
- Aggregate IOAM data per path
- Derive per-OD pair latency
- Identify path utilization
- Detect micro-bursts

IOAM Deployment Modes:
- Full Trace: Every node records
- Sampled: 1-in-N packets
- Event-Driven: Triggered on anomaly

Use Case: SRv6 Path Validation
- Confirm packets use intended path
- Measure actual latency vs designed
- Verify SR Policy effectiveness
```

### 22.3.5 BGP Flowspec Measurement

BGP Flowspec can contribute to traffic matrix:

```
BGP Flowspec for Traffic Matrix:

Flowspec Rule:
- Match: destination 10.1.0.0/16
- Match: DSCP EF
- Then: rate-limit 100Mbps

Flowspec Telemetry:
- Counters per rule at each router
- Indicates traffic volume matching rule
- Can export via IPFIX

Use Cases:
- Identify elephant flows
- Detect traffic spikes
- Correlate with policy changes
```

## 22.4 Traffic Matrix Analysis

### 22.4.1 Origin-Destination Pair Analysis

Analyzing OD pairs reveals demand patterns:

```
OD Pair Analysis:

Volume Distribution:
- Most OD pairs: low volume (<100 Mbps)
- Few OD pairs: high volume (>1 Gbps)
- "Elephant" vs "Mouse" flows

Pareto Principle:
- 20% of OD pairs carry 80% of traffic
- Focus TE on high-volume pairs
- Elephant flow management critical

Example Distribution:
OD Pair           Volume     % of Total
Site-A -> DC1     8 Gbps     35%
Site-A -> DC2     5 Gbps     22%
Site-B -> DC1     3 Gbps     13%
Site-B -> DC2     3 Gbps     13%
Site-C -> DC1     2 Gbps      9%
Site-C -> DC2     1.5 Gbps    8%

Top 2 pairs = 57% of traffic
```

### 22.4.2 Temporal Analysis

Traffic patterns vary over time:

```
Temporal Patterns:

1. Diurnal Pattern:
- Business hours: high utilization
- Night hours: low utilization
- Weekends: minimal utilization

2. Weekly Pattern:
- Weekdays: consistent high utilization
- Weekend: reduced utilization

3. Monthly/Seasonal:
- Month-end processing
- Holiday shopping (retail)
- Tax season

4. Event-Driven:
- Product launches
- Marketing campaigns
- News events

Analysis Use:
- Right-size capacity
- Plan maintenance windows
- Predict capacity needs
```

### 22.4.3 Class-of-Service Analysis

Traffic matrix should distinguish traffic classes:

```
Class-Differentiated Matrix:

Matrix Structure:
TM[class][origin][destination] = volume

Example:
                    Real-Time    Best-Effort
Site-A -> DC1        2 Gbps        6 Gbps
Site-A -> DC2        1 Gbps        4 Gbps

TE Implications:
- Real-time: minimize latency
- Best-effort: maximize throughput

DSCP Preservation in SRv6:
- DSCP copied to outer IPv6 header
- Preserved through transit
- Per-class measurement possible
```

### 22.4.4 Path Utilization Analysis

Correlate demand with path capacity:

```
Path Utilization Analysis:

For each SR Policy path:
1. Sum traffic volumes using path
2. Compare to path capacity
3. Calculate utilization %

Utilization Categories:
- Under-utilized: < 30% (potential consolidation)
- Normal: 30-70% (good utilization)
- High: 70-85% (monitor closely)
- Critical: > 85% (immediate attention)
- Over-subscribed: > 100% (congestion)

Example Path Analysis:
Path: Site-A -> Core-1 -> Core-2 -> DC1
Capacity: 100 Gbps
Traffic: 75 Gbps
Utilization: 75% (High)

Action:
- Consider adding capacity
- Or load-balance some flows to alternate path
```

## 22.5 TE Optimization Based on Traffic Matrix

### 22.5.1 Demand-Aware Path Selection

Traffic matrix informs path selection:

```
Demand-Aware Path Selection:

1. Hot Spot Detection:
   - Identify over-utilized links
   - Find alternative paths for elephant flows

2. Flow Placement:
   - Match flow to optimal path
   - Consider volume, class, SLA

3. Load Balancing:
   - Distribute demand across paths
   - Maintain balance within thresholds

Algorithm:
For each elephant flow:
1. Find current path
2. Calculate current path utilization
3. If utilization > threshold:
   a. Find alternate path with lower utilization
   b. If exists and meets SLA:
      - Move flow to alternate path
4. Update traffic matrix
```

### 22.5.2 Capacity Optimization

Traffic matrix drives capacity planning:

```
Capacity Optimization Process:

1. Measure:
   - Current traffic matrix
   - Projected growth

2. Analyze:
   - Identify bottlenecks
   - Calculate required capacity

3. Plan:
   - Size new links
   - Plan link additions

4. Validate:
   - Post-change measurement
   - Confirm improvements

Demand Forecasting:
- Linear extrapolation
- Trend analysis
- Seasonal adjustment
- Event-based adjustment

Example:
Current: 80 Gbps on 100 Gbps link
Growth: 10% monthly
Days until saturation: ~90 days
Order lead time: 60 days
Order now: 60 days ahead of saturation
```

### 22.5.3 Dynamic Load Balancing

SR Policy enables dynamic rebalancing:

```
Dynamic Load Balancing with SR Policy:

1. Monitor Utilization:
   - Per-link utilization from telemetry
   - Per-SR-policy load from accounting

2. Threshold Detection:
   - High threshold: 75% utilization
   - Critical threshold: 85% utilization

3. Trigger Rebalancing:
   - Find elephant flows on high-util links
   - Compute alternative paths
   - Move flows via SR Policy update

4. Execute Move:
   - Make-before-break on SR Policy
   - Gradual flow migration
   - Monitor for anomalies

Example Rebalancing:
Link L1-A-B utilization: 88% (critical)
Alternative path L2-A-X-B: 45% utilization

Action:
- Select flows using L1-A-B
- Move via SR Policy to L2-A-X-B
- New L1-A-B: 65%, L2-A-X-B: 55%
```

### 22.5.4 Multi-Class Optimization

Traffic matrix enables per-class optimization:

```
Multi-Class Optimization:

Matrix with Classes:
TM_Realtime: low latency requirement
TM_Bulk: high bandwidth requirement
TM_Default: standard delivery

Optimization Strategy:
1. Realtime flows:
   - Route via minimum-latency path
   - Reserve bandwidth
   - TI-LFA mandatory

2. Bulk flows:
   - Route via maximum-capacity path
   - Load-balance across available bandwidth
   - No FRR required

3. Default flows:
   - Use any available capacity
   - Fill remaining bandwidth
   - Best-effort delivery

Implementation:
SR Policy per class:
- policy_REALTIME: color 100, minimize-latency
- policy_BULK: color 200, minimize-te, bandwidth-aware
- policy_DEFAULT: color 0, default IGP
```

## 22.6 Automated TE Tuning

### 22.6.1 Closed-Loop Automation

Automated TE uses feedback loops:

```
Closed-Loop TE Architecture:

[Measure] -> [Analyze] -> [Plan] -> [Execute]
    ^                               |
    |_____________ Feedback _________|

Components:
1. Measurement:
   - Traffic matrix collector
   - Utilization telemetry
   - Performance monitors

2. Analysis:
   - Anomaly detection
   - Hot-spot identification
   - Trend analysis

3. Planning:
   - Re-optimization computation
   - Candidate path evaluation
   - Risk assessment

4. Execution:
   - SR Policy updates
   - PCE commands
   - Validation

Automation Levels:
- Manual: Human analyzes, human acts
- Semi-automatic: System proposes, human approves
- Full automatic: System acts, monitors, adjusts
```

### 22.6.2 PCE-Driven Auto-Tuning

PCE can automate TE adjustments:

```
PCE Auto-Tuning Functions:

1. Continuous Monitoring:
   - PCE polls utilization via telemetry
   - Tracks per-link, per-path metrics
   - Maintains real-time traffic matrix

2. Threshold Alerts:
   - Link utilization > threshold
   - Path latency exceeds SLA
   - Path failure detected

3. Auto-Optimization:
   - PCE computes rebalancing
   - Updates SR Policy via PCEP
   - Validates with telemetry

4. Schedule-Based:
   - Daily re-optimization window
   - Pre-event capacity adjustment
   - Post-failure rebalancing

PCE Auto-Tuning Configuration:
segment-routing traffic-eng
 pce
  auto-tunnel
   monitor utilization
   threshold 75
   action rebalance
  !
 !
!
```

### 22.6.3 Performance-Based Triggers

Auto-tuning based on measured performance:

```
Performance Triggers:

1. Latency Trigger:
   condition: latency > SLA threshold
   action: find lower-latency path
   example: Latency > 10ms for EF traffic

2. Jitter Trigger:
   condition: jitter > threshold
   action: find less congested path
   example: Jitter > 5ms for video

3. Packet Loss Trigger:
   condition: loss > threshold
   action: reroute to reliable path
   example: Loss > 0.1% for any traffic

4. Reorder Trigger:
   condition: reorder% > threshold
   action: reduce ECMP or change path
   example: Reorder > 1% indicates path issue

Example Trigger Configuration:
auto-tunnel
 trigger latency
  metric delay
  threshold 10 ms
  tolerance 2 ms  ! Don't oscillate
  action reoptimize
  !
!
```

### 22.6.4 Safety Mechanisms

Auto-tuning requires safeguards:

```
Safety Mechanisms:

1. Rate Limiting:
   - Max % traffic moved per interval
   - Prevents sudden shifts
   - Example: Max 10% of traffic moved per 5 minutes

2. Change Approval:
   - Semi-automatic mode
   - Human approves major changes
   - Automatic handles minor adjustments

3. Rollback Capability:
   - Keep previous SR Policy state
   - Automatic rollback on failure
   - Example: Revert if latency worse after move

4. Monitoring Amplification:
   - Extra monitoring after changes
   - Faster detection of problems
   - Quick rollback if needed

5. Blackout Periods:
   - No changes during critical windows
   - Example: No changes during business hours
   - Emergency override available

Rollback Example:
policy change from [A,B,C,D] to [A,X,C,D]
monitor for 5 minutes:
  if latency increased > 20%:
    rollback to previous segment list
```

## 22.7 Traffic Matrix Applications

### 22.7.1 Capacity Planning

Traffic matrix drives capacity planning:

```
Capacity Planning Workflow:

1. Current State Assessment:
   - Measure current traffic matrix
   - Document link capacities
   - Calculate current utilization

2. Demand Forecasting:
   - Historical growth analysis
   - Organic growth projections
   - Event-based adjustments

3. Future State Planning:
   - Forecast traffic matrix (6-12 months)
   - Identify required capacity
   - Plan link additions/upgrades

4. Validation:
   - Post-deployment measurement
   - Confirm accuracy of forecasts
   - Adjust planning models

Example Planning:
Current: 100 Gbps total
Growth: 20% annually
6-month forecast: 110 Gbps
12-month forecast: 120 Gbps

Current capacity: 150 Gbps
No action needed for 12 months
Order 200 Gbps capacity for 18 months
```

### 22.7.2 Anomaly Detection

Traffic matrix reveals anomalies:

```
Anomaly Detection:

Types of Anomalies:
1. Traffic Spikes:
   - Sudden increase in traffic
   - May indicate attack or flash crowd
   - Example: 10x normal volume

2. Traffic Drops:
   - Sudden decrease in traffic
   - May indicate failure or issue
   - Example: Complete loss to specific destination

3. Path Deviation:
   - Traffic on unexpected path
   - May indicate SR Policy misconfiguration
   - Example: Traffic via backup when primary available

4. Latency Spikes:
   - Delay increase on specific path
   - May indicate congestion
   - Example: Latency 5x normal

Detection Methods:
- Statistical: deviation from baseline
- ML-based: pattern recognition
- Threshold: absolute value triggers
```

### 22.7.3 SLA Validation

Traffic matrix validates SLA compliance:

```
SLA Validation Process:

SLA Metrics:
- Availability: 99.99%
- Latency: < 10ms (p99)
- Jitter: < 5ms (p99)
- Packet Loss: < 0.01%

Validation via Traffic Matrix:
1. Availability:
   - Measure uptime per OD pair
   - Calculate % compliant

2. Latency:
   - IOAM or TWAMP measurement
   - Per-OD pair statistics
   - Calculate p99 values

3. Jitter:
   - Measure latency variation
   - Per-OD pair statistics

4. Loss:
   - IOAM sequence numbers
   - Calculate loss rate

Reporting:
Per OD pair SLA compliance:
OD Pair          Latency  Jitter   Loss    Available
Site-A -> DC1     8.2ms    2.1ms    0.001%  99.99%
Site-A -> DC2     9.8ms    4.2ms    0.008%  99.97%
Site-B -> DC1     9.1ms    3.1ms    0.002%  99.99%
```

## 22.8 Traffic Matrix Collection Infrastructure

### 22.8.1 Collection Architecture

```
Traffic Matrix Collection Architecture:

Components:
1. Data Sources (at each node):
   - Interface SNMP counters
   - NetFlow/IPFIX exporter
   - IOAM data generator
   - PCE telemetry

2. Collection Infrastructure:
   - Flow collector cluster
   - Time-series database
   - Stream processor

3. Analysis Platform:
   - Traffic matrix engine
   - Anomaly detector
   - Planning tool

4. northbound API:
   - PCE integration
   - NMS integration
   - Customer portal

Data Flow:
[Routers] --IPFIX--> [Collector Cluster]
    |                        |
    | --SNMP--> [EMS/NMS]---+
    |                        |
    +---Telemetry---------> [PCE]
                               |
                               v
                         [TE Server]
```

### 22.8.2 Scalability Considerations

```
Collection Scalability:

Challenges:
- Millions of flows
- High-speed interfaces (100G+)
- Real-time processing requirements

Solutions:
1. Flow Sampling:
   - Sample 1:100 or 1:1000
   - Reduces collector load
   - Statistical accuracy

2. Aggregation:
   - Pre-aggregate at router
   - Export aggregated records
   - Reduces export volume

3. Streaming:
   - Real-time stream processing
   - In-memory aggregation
   - No persistent storage bottleneck

4. Distributed Collection:
   - Regional collectors
   - Hierarchical aggregation
   - Central correlation

Scale Numbers:
- 100 routers x 10G flow/sec = 1B flows/minute
- Sampling 1:1000 -> 1M flows/minute
- 3 collectors x 333K flows/minute -> tractable
```

### 22.8.3 Data Storage

```
Traffic Matrix Storage:

Time-Series Database:
- Stores traffic matrix over time
- Efficient range queries
- Supports analytics

Schema:
tm_data:
  time_bucket timestamp
  origin_id
  destination_id
  class_id
  volume_bps
  packet_count
  flow_count

Retention:
- Raw data: 24 hours
- 1-minute aggregates: 7 days
- 5-minute aggregates: 30 days
- 1-hour aggregates: 1 year
- Daily aggregates: Forever

Query Examples:
- Get traffic matrix for past week
- Compare today's peak to historical
- Identify growth trends
```

## 22.9 Practical Considerations

### 22.9.1 Measurement Accuracy

```
Accuracy Considerations:

Sampling Impact:
- 1:1000 sampling = 0.1% accuracy
- Elephant flows captured well
- Mouse flows may be missed

Timing Impact:
- Counter wrap-around
- Polling interval gaps
- Clock synchronization

Classification Accuracy:
- DSCP may be marked incorrectly
- Application classification errors
- VPN traffic identification

Validation:
- Compare multiple sources
- Cross-check with interface counters
- Periodic full Census (no sampling)
```

### 22.9.2 Operational Integration

```
Operational Integration:

NMS Integration:
- Traffic matrix as NMS data source
- Topology visualization with demand
- Alert on anomalies

Change Management:
- Pre-change traffic matrix capture
- Post-change validation
- Impact analysis

Capacity Planning:
- Regular reporting
- Forecast updates
- Procurement triggers

Billing/Chargeback:
- Per-tenant traffic volumes
- Inter-facility bandwidth
- SLA compliance billing
```

### 22.9.3 Security Considerations

```
Security Considerations:

Data Protection:
- Traffic matrix reveals business relationships
- Consider sensitivity of OD pairs
- Control access to collector

Telemetry Security:
- IPFIX over IPsec
- REST API authentication
- SNMPv3

Privacy:
- Flow details may reveal applications
- Anonymization for external analysis
- GDPR considerations
```

## 22.10 Summary

The traffic matrix is the foundation of effective traffic engineering in SRv6 networks:

- **Measurement**: Traffic matrices are derived from multiple sources—NetFlow/IPFIX for flow-level detail, SNMP interface counters for validation, IOAM for path-level telemetry, and BGP Flowspec for rule-level measurement. Each source has trade-offs in granularity, overhead, and accuracy.

- **Analysis**: The traffic matrix reveals demand distribution across origin-destination pairs, temporal patterns (diurnal, weekly, seasonal), class-of-service breakdown, and path utilization. Most networks exhibit the Pareto principle—20% of pairs carry 80% of traffic.

- **TE Optimization**: Armed with accurate traffic matrices, operators can detect hot spots, rebalance elephant flows across under-utilized paths, right-size capacity, and optimize per-class. SR Policy provides the mechanism to implement changes dynamically.

- **Automation**: Closed-loop TE automation continuously measures, analyzes, plans, and executes adjustments. PCE-driven auto-tuning monitors utilization and triggers rebalancing when thresholds are exceeded. Safety mechanisms (rate limiting, rollback) prevent destabilizing oscillations.

- **Practical Deployment**: Production traffic matrix systems require scalable collection infrastructure, time-series databases, and operational integration with NMS and capacity planning tools. Measurement accuracy considerations include sampling rates, timing, and classification reliability.

Understanding and leveraging the traffic matrix transforms SRv6 networks from reactive to proactive—continuously optimized based on actual demand rather than static configuration.

---

