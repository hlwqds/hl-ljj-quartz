# Chapter 13: TI-LFA - Topology-Independent Loop-Free Alternates for SRv6

## 13.1 Overview

Network reliability requires rapid failure recovery—when a link or node fails, traffic must reroute before application timeouts cause visible service degradation. Traditional IP convergence through IGP reconvergence takes seconds, far exceeding the sub-50ms threshold required for carrier-grade service. LFA (Loop-Free Alternates) and its extension TI-LFA (Topology-Independent LFA) provide pre-computed backup paths that activate in milliseconds, independent of topology structure.

This chapter explains the LFA concept, its topology-dependence limitations, and how TI-LFA leverages SRv6's source routing model to provide protection even in topologies where traditional LFA fails. We examine the TI-LFA computation algorithm, the SR Policy integration that installs backup paths, and the operational characteristics of TI-LFA protection in production networks.

## 13.2 The Failure Recovery Challenge

### 13.2.1 IGP Convergence Timeline

When a link fails in a traditional IP network, the following sequence occurs:

```
IGP Convergence Timeline:
1. Link failure detected (physical layer, ms)
2. IGP LSAs flooded (seconds, depending on network size)
3. SPF recalculated at each node (O(K) where K = network links)
4. FIB updated at each node (hardware programming time)
5. Traffic resumes on new path

Total convergence time: 1-10 seconds typical
Acceptable for data: Yes
Acceptable for VoIP: No (250ms threshold exceeded)
Acceptable for financial trading: Absolutely not (microsecond requirements)
```

The fundamental issue: **the network must collectively discover the failure, recompute paths, and update forwarding state** before traffic can recover. This distributed consensus process inherently takes time.

### 13.2.2 Protection vs. Restoration

Network recovery strategies fall into two categories:

**Restoration**: React to failure, find a new path, install it. IGP convergence is restoration—it discovers failure and computes new paths reactively.

**Protection**: Pre-compute backup paths and install them before any failure occurs. When failure is detected, activate the pre-computed backup immediately. Protection provides faster recovery because computation already happened.

TI-LFA is a protection mechanism: for every primary segment in an SRv6 path, compute a backup segment that guarantees loop-free forwarding to the next primary segment, then install this backup as a pre-computed SR Policy.

### 13.2.3 The Loop-Free Requirement

A backup path must be **loop-free**: traffic forwarded along the backup should not return to the node that sent it, nor should it loop through the protected segment. The loop-free condition is expressed as:

```
Loop-Free Condition for backup path to protected segment S:
Distance(backup_next_hop, S) < Distance(node, S)

Where Distance is the IGP metric

Meaning: The backup next-hop must be closer to the protected segment
than the node itself is. This guarantees traffic won't loop back.
```

This inequality is the heart of all LFA formulations. Traditional LFA can compute such a backup only when the topology provides a loop-free alternate—the inequality must hold for some neighbor.

## 13.3 Classical LFA

### 13.3.1 LFA Principles

IP LFA (Loop-Free Loop-Free Alternates), specified in RFC 5286, provides per-prefix backup paths computed using only local information (the node's local LSDB and SPF tree).

```
Classical LFA Computation:
For each route R with next-hop N:
1. Compute shortest path tree (SPT) rooted at this node
2. For each neighbor X of this node:
   a. If Distance(X, R) < Distance(this_node, R):
      - X is loop-free for R
      - Traffic to R via X won't loop back to this node
3. Among loop-free neighbors, select one as LFA for R
```

The intuition: if a neighbor is closer to the destination than this node is, sending traffic to that neighbor won't cause it to return (loop).

### 13.3.2 LFA Coverage Gap

Classical LFA fails when no neighbor satisfies the loop-free condition. Consider this topology:

```
      B
     /|
    / |
   /  |
  A---C
   \ |
    \|
     D
```

A is trying to reach B. A's neighbors are C and D. Let's say all links have metric 10.

- Distance(A, B) = 10 (direct via C)
- Distance(C, B) = 20 (C→B via C's other interface?)

Actually, let me draw this properly:

```
      B (metric 10 from A via C)
     /|
    / |
   /  |
  A---C
   \ |
    \|
     D
```

If A→C→B is the primary path (metric 10+10=20), then A's loop-free alternates to B would require a neighbor X where Distance(X, B) < Distance(A, B).

- Distance(C, B) = 10 (direct link C-B)
- Distance(D, B) = ? D→A→C→B = 10+10+10 = 30

Neither C nor D is loop-free for B (neither is closer to B than A is). LFA provides no coverage here.

### 13.3.3 Remote LFA (RLFA)

Remote LFA extends LFA coverage by finding a **PQ node** that can serve as an intermediate for tunneled backup:

```
RLFA Algorithm:
1. For protected destination D with primary next-hop N:
   a. Find the region where SPF would route from other nodes to D via N
   b. This region is the "P-space" (nodes whose shortest path to D goes through N)
   c. Compute Q-space: nodes that are loop-free with respect to this node for D
   d. Find a node Q in both P-space and Q-space (PQ node)
   e. Compute shortest path from this node to Q
   f. Compute shortest path from Q to D
   g. If both paths exist, tunnel to Q provides loop-free backup
```

RLFA requires LDP or other tunnel establishment to reach the PQ node—a significant complexity. Additionally, the PQ node must be found per-destination, and in some topologies, no suitable PQ node exists.

## 13.4 TI-LFA: Topology-Independent Protection

### 13.4.1 The TI-LFA Insight

TI-LFA (Topology-Independent LFA), introduced in RFC 9002, provides protection for any topology by computing backup paths using the **segment list** rather than relying on the physical topology's loop-free alternates.

The key insight: **SRv6's source routing model decouples the backup path computation from the physical topology**. Instead of finding a physical neighbor that is loop-free to the destination, TI-LFA computes a **segment list** that reaches the same destination via a loop-free path, encoded as an SR Policy backup.

### 13.4.2 TI-LFA Computation Model

TI-LFA computes backup paths in the **segment list space** rather than the physical topology space:

```
TI-LFA Computation:
For a protected primary path with segments [S1, S2, S3, ...]:
1. Identify each primary segment that needs protection
2. For segment Si (protecting path to Si):
   a. Identify the failure scenario (link failure, node failure)
   b. Compute a post-convergence path to Si using the IGP topology post-failure
   c. If post-convergence path exists, express it as a segment list
   d. This segment list is the TI-LFA backup for Si
3. Install backup segment list as SR Policy
4. Upon failure detection, steer traffic onto backup SR Policy
```

The crucial difference from classical LFA: **TI-LFA's backup path is computed in the segment list domain**. It doesn't matter whether the physical topology has a loop-free alternate—the segment list space can always express a loop-free path, because we can include any nodes necessary.

### 13.4.3 Post-Convergence Path

TI-LFA's backup is derived from the **post-convergence path**—the path the IGP would compute after the failure has been absorbed. This ensures:

1. **Loop-free**: The post-convergence path is by definition loop-free (IGP guarantees this)
2. **Available**: If IGP converges to a path, that path exists post-failure
3. **Consistent**: The backup path is the same path the network will eventually use, avoiding traffic oscillation

```
Post-Convergence Path Example:
Primary: A → B → C → D
Protected: Segment B (node B failure)

Post-convergence path from A to C (B's downstream):
A → X → Y → C (via alternative links)

TI-LFA backup for segment B:
Segment list: [A, X, Y, C]

When B fails:
- Traffic already has backup path encoded in SR Policy
- Immediately switches to backup
- No IGP convergence waiting required
```

### 13.4.4 Protecting Against Different Failure Types

TI-LFA can protect against:

**Link Failure**: The most common failure type. TI-LFA computes the post-convergence path when the protected link is removed from the topology.

```
Link Protection:
Protected element: Link A-B
Post-convergence path from A to B: A-X-Y-B
TI-LFA backup segment list: [A, X, Y, B]
```

**Node Failure**: More complex because the failed node and all its attached links disappear. TI-LFA computes the path that bypasses the node entirely.

```
Node Protection:
Protected element: Node B
Post-convergence path from A to C (next segment after B): A-X-C
TI-LFA backup segment list: [A, X, C]
Skips B entirely
```

**SRLG Failure**: Shared Risk Link Groups (SRLGs) are sets of links that share a common failure point (same fiber, same conduit). TI-LFA can protect against SRLG failure by computing post-convergence paths that avoid all links in the SRLG.

## 13.5 SR Policy Integration

### 13.5.1 TI-LFA as SR Policy

TI-LFA backup paths are installed as **SR Policies** with specific characteristics:

```
TI-LFA SR Policy:
- Name: auto-ti-lfa:<protected-path>:<failure-type>
- Candidate Paths:
  - Primary: explicit segment list [original path]
  - Backup: explicit segment list [post-convergence path]
- Protection: per-segment
- Activation: On failure detection, switch to backup candidate path
```

The SR Policy framework provides the mechanism for expressing backup paths, managing the switchover, and ensuring traffic is properly steered.

### 13.5.2 Candidate Path Design

A TI-LFA-protected SR Policy maintains multiple candidate paths:

```
SR Policy: srte_1_A_to_D
Candidate Paths:
1. Preference 200 (primary):
   - Segment List: [A, B, C, D]
   - Path Type: computed (IGP)
   - Protection: none

2. Preference 100 (TI-LFA backup):
   - Segment List: [A, X, Y, C, D]
   - Path Type: computed (TI-LFA)
   - Protection: link A-B

3. Preference 100 (TI-LFA backup):
   - Segment List: [A, X, Y, D]
   - Path Type: computed (TI-LFA)
   - Protection: node B
```

When the primary path fails, the highest-preference backup with a valid path takes over. This automatic switchover provides the sub-50ms recovery time.

### 13.5.3 Binding SID for TI-LFA

TI-LFA SR Policies use **Binding SID (BSID)** to enable efficient path selection:

```
BSID Integration:
- Each SR Policy has a BSID
- Traffic is steered to SR Policy by referencing its BSID
- When TI-LFA activates backup, BSID continues to work (points to new active path)

Packet Flow:
Original: DA = first segment
With BSID: DA = BSID (resolved via SID table to active candidate path)
```

The BSID indirection means the source doesn't need to change the segment list when switching from primary to backup—the BSID always resolves to the currently active path.

## 13.6 TI-LFA Computation Algorithm

### 13.6.1 Detailed Algorithm Steps

The TI-LFA computation algorithm proceeds as follows:

```
TI-LFA Computation for segment Si:
1. Input:
   - Primary segment list: [S1, S2, S3, ..., Sn]
   - Protected element: Si (either link or node on path to Si)
   - Node performing computation

2. Compute post-convergence topology:
   a. Remove protected element from topology
   b. Run SPF from each node to determine reachability to Si

3. Compute post-convergence path:
   a. From predecessor of Si (node before segment Si) to Si
   b. This path avoids the protected element
   c. If no path exists, no TI-LFA backup possible for this segment

4. Express post-convergence path as segment list:
   a. Map each hop in post-convergence path to SID
   b. Construct segment list [P, X, Y, ..., Si]
   c. This is the TI-LFA backup segment list

5. Install as SR Policy with appropriate preference
```

### 13.6.2 Segment-Based vs. Path-Based Protection

TI-LFA can provide protection at different granularities:

**Segment-Based Protection**: Protect each segment individually. More granular but requires more SR Policy state.

**Path-Based Protection**: Protect entire path with one backup. Less state but broader failure coverage.

Most deployments use segment-based protection for critical segments and path-based for less critical traffic.

### 13.6.3 Coverage Considerations

TI-LFA cannot guarantee protection in all scenarios:

1. **No Post-Convergence Path**: If the protected element is a cut-vertex (its removal disconnects the network), no post-convergence path exists. TI-LFA cannot protect.

2. **Computation Scale**: For networks with N nodes and M potential failure points, computing TI-LFA backups for all possibilities requires significant CPU. Optimization focuses on protecting critical links/nodes first.

3. **SID Availability**: TI-LFA backup paths require SIDs for each hop. If SID allocation doesn't cover backup path nodes, backup cannot be expressed.

## 13.7 TI-LFA in SRv6 Context

### 13.7.1 SRv6 SID Structure Benefits

TI-LFA benefits from SRv6's SID structure:

1. **Locator-Based Forwarding**: Transit nodes forward based on locators, so TI-LFA backup paths work at transit even if individual SIDs differ.

2. **Behavior Execution**: The End behavior works identically whether processing primary or backup segment lists, enabling transparent protection.

3. **uSID Efficiency**: uSID compression ensures TI-LFA backup paths don't consume excessive header overhead.

### 13.7.2 Example: TI-LFA for SRv6 Path

Consider an SRv6 path through 5 nodes:

```
Primary Path (Segment List):
[Node-A:End, Node-B:End, Node-C:End, Node-D:End, Node-E:End]

Node-B has two links: B-C (primary) and B-X-C (backup via X)
```

When B processes a packet and the B-C link fails:

```
Without TI-LFA:
- Packet stuck at B (trying to forward to C via failed link)
- Or B must wait for IGP convergence

With TI-LFA:
- Pre-computed backup: Segment list through X
- Upon B-C failure detection, activate backup
- Next packet: DA updates to X's SID, forwarded via X
- Recovery: sub-50ms (no IGP involved)
```

### 13.7.3 TI-LFA and PSP Interaction

TI-LFA must account for PSP (Penultimate Segment Pop) flavor:

```
PSP + TI-LFA Consideration:
If PSP is set on primary path:
- Penultimate segment pops SRH at Node-D (before Node-E)
- TI-LFA backup must account for SRH removal

When TI-LFA backup activates:
- PSP still applies on backup path
- Penultimate on backup is the segment before final
- Need to verify PSP flavor matches backup path length
```

## 13.8 Implementation Considerations

### 13.8.1 PCE-Based TI-LFA Computation

TI-LFA computation is typically performed by a **PCE (Path Computation Element)** rather than by individual nodes:

```
PCE Architecture for TI-LFA:
- Centralized PCE maintains full topology
- On topology change, PCE recomputes TI-LFA for all protected paths
- Results distributed to nodes via PCEP
- Nodes install TI-LFA SR Policies locally
```

PCE-based computation is more efficient (single computation for entire network) and enables global optimization of backup paths.

### 13.8.2 Failure Detection

TI-LFA activation requires rapid failure detection:

```
Failure Detection Mechanisms:
1. Bidirectional Forwarding Detection (BFD):
   - Sub-50ms detection
   - Runs on protected interface
   - Triggers TI-LFA activation immediately

2. Interface Loss of Signal:
   - Hardware-level detection
   - Fastest detection (microseconds)
   - Triggers BFD session down

3. IGP Death:
   - Slower detection
   - Used as backup to BFD
   - Not suitable for sub-50ms TI-LFA
```

BFD is the standard failure detection mechanism for TI-LFA, providing the rapid notification needed for immediate backup activation.

### 13.8.3 Switchover Time

TI-LFA switchover time is dominated by failure detection:

```
TI-LFA Switchover Timeline:
1. Failure occurs (time = 0)
2. BFD detection (typically 10-50ms depending on configuration)
3. BFD session down notification to routing
4. SR Policy switch to backup candidate path (< 1ms)
5. New segment list installed in FIB (< 1ms)
6. Traffic flows on backup path

Total: typically 15-50ms
Target: < 50ms for carrier-grade service
```

### 13.8.4 Testing and Validation

TI-LFA deployments should be tested for:

1. **Coverage Testing**: Verify TI-LFA exists for all critical segments
2. **Switchover Testing**: Inject failure, measure time to traffic restoration
3. **Return Testing**: After failure recovery, verify traffic returns to primary when primary becomes available
4. **Microloop Prevention**: Verify no traffic loops form during switchover

## 13.9 Summary

TI-LFA provides topology-independent protection for SRv6 paths:

- **Classical LFA Limitations**: Traditional LFA requires physical topology loop-free alternates. Many practical topologies don't provide sufficient coverage.

- **TI-LFA Innovation**: By computing backup paths in segment list space rather than physical topology space, TI-LFA provides protection even when no loop-free physical alternate exists.

- **Post-Convergence Path**: TI-LFA uses the IGP's post-convergence path as its backup, guaranteeing loop-free forwarding that will exist after IGP reconvergence.

- **SR Policy Integration**: TI-LFA backups are expressed as SR Policies with candidate paths, enabling automatic switchover upon failure detection.

- **Failure Types**: TI-LFA protects against link failure, node failure, and SRLG (Shared Risk Link Group) failure.

- **Sub-50ms Recovery**: With BFD failure detection, TI-LFA achieves the carrier-grade 50ms threshold that traditional IGP convergence cannot.

- **PCE-Based Computation**: Centralized TI-LFA computation by PCE is more efficient and enables global optimization.

The combination of SRv6's programmable segment lists and TI-LFA's topology-independent protection delivers the reliability that carrier networks require, without the topology constraints that limit classical LFA deployments.

---

**References**

- RFC 9002: Loop-Free Alternate (LFA) for IPV6 and Segment Routing
- RFC 5286: Basic Specification for IP Loop-Free Alternate (LFA)
- RFC 8402: Segment Routing Architecture
- RFC 9256: Segment Routing Policy Architecture
- RFC 5443: LDP IGP Synchronization
- RFC 6571: Loop-Free Alternate (LFA) Applicability
- IETF Draft: Topology-Independent LFA (TI-LFA) for Segment Routing
