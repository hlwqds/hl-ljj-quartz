# Chapter 12: SRv6 Vanity SID - Compressed uSID Format for Production Scale

## 12.1 Overview

The 128-bit SRv6 SID, while architecturally elegant and infinitely programmable, presents practical challenges for production deployment. A single path through 20 nodes, each contributing a 128-bit SID, consumes 2,560 bits (320 bytes) of header overhead—clearly unsustainable at scale. The SRv6 Vanity SID (also called uSID or microSID) addresses this through compression: packing essential SID information into a compact 32-bit format that fits efficiently in hardware TCAM and reduces per-packet overhead dramatically.

This chapter explains the uSID architecture, its encoding formats (uN for node segments, uSF for service functions, uA for adapter segments), the hardware FIB implications, and the migration path from full 128-bit SIDs to compressed uSID deployment.

## 12.2 The SID Size Problem

### 12.2.1 Header Overhead at Scale

Consider a practical SRv6 deployment in a tier-1 ISP backbone:

```
Path: 15 nodes across 5 PoPs
Each segment = 128-bit SID
Packet header overhead per segment: 16 bytes (128 bits / 8)

Total SRH overhead:
- Base SRH: 8 bytes
- 15 segments × 16 bytes = 240 bytes
- Total: 248 bytes overhead

Vs. traditional IPv6 (40 bytes) or SR-MPLS (4 bytes per label, 15 labels = 60 bytes)
```

At 100 Gbps line rate, 248 bytes overhead per packet represents substantial bandwidth waste and processing overhead. For latency-sensitive traffic using short packets, the overhead compounds: a 64-byte VoIP packet carrying 248 bytes of SRv6 header represents approximately 80% overhead.

### 12.2.2 Hardware TCAM Constraints

Network ASICs use TCAM (Ternary Content-Addressable Memory) for FIB lookup. TCAM entries are typically 64, 128, or 256 bits wide—fitting a single 128-bit SID comfortably, but with limited total capacity. A carrier-scale FIB with 100,000 routes × 128 bits per entry requires significant TCAM resources.

More critically, the **locator prefix** (the network-visible portion of the SID used for FIB entry) is often much shorter than the full 128 bits. If a node uses FC00:0:1:1::/48 as its locator and SID values within that prefix, only 48 bits are needed for longest-prefix match. The remaining 80 bits (function + argument) are processed after the FIB lookup, consuming expensive TCAM for what could be a lookup-only operation.

### 12.2.3 The uSID Solution

uSID (microSID, pronounced "you-sid") compresses the SID by exploiting structure in how SIDs are allocated. Instead of treating each SID as an independent 128-bit value, uSID recognizes that:

1. **Most SIDs are node segments** (locator-based, single-hop) requiring only node identification
2. **Service function SIDs** follow predictable allocation patterns
3. **Arguments are often zero** or small values

By defining fixed-position fields within the 128-bit SID space, uSID enables 32-bit encoding for the common cases while preserving the ability to express arbitrary function/argument values when needed.

## 12.3 uSID Architecture

### 12.3.1 The uSID Block

The uSID architecture reserves a portion of the 128-bit SID space for compressed microsegments. The IETF draft specifies:

```
uSID Block Allocation:
- Bits 0-15: uSID identifier (0xFC000 if standard)
- Bits 16-47: Microsegment value (32 bits)
- Bits 48-127: Reserved for future use or argument extension
```

When a packet carries a uSID, the **entire 128-bit SID field** in the IPv6 DA contains the uSID value. No SRH modification is required—uSID is a SID encoding optimization, not a protocol change. Transit and endpoint nodes process the compressed value identically to full SIDs.

### 12.3.2 uSID Allocation Structure

Network operators allocate uSID blocks hierarchically:

```
Global uSID Allocation Example:
+-------------------------+
| Operator ID (16 bits)   |  Identifies the operator/carrier
+-------------------------+
| PoP ID (8 bits)         |  Identifies the Point of Presence
+-------------------------+
| Node ID (8 bits)         |  Identifies the node within PoP
+-------------------------+
| Function (16 bits)      |  Identifies the behavior at this node
+-------------------------+

Total: 48 bits for uSID addressing
Remaining bits for argument/metadata
```

This structure allows:

- Up to 65,536 operators
- 256 PoPs per operator
- 256 nodes per PoP
- 65,536 function codes per node

With argument space extending into bits 48-127, the architecture scales to most practical deployment scenarios.

### 12.3.3 uSID vs. Full SID Comparison

| Property           | Full 128-bit SID    | uSID (32-bit)     | Savings    |
| ------------------ | ------------------- | ----------------- | ---------- |
| SID size in DA     | 128 bits            | 128 bits (packed) | Same       |
| SID storage in FIB | 128 bits            | 32 bits (mapped)  | 75%        |
| SRH segment entry  | 128 bits            | 32 bits (packed)  | 75%        |
| Argument space     | Built-in (variable) | Bits 48-127       | Same       |
| Behavior lookup    | Full SID table      | Locator+function  | Simplified |

The key insight: the **packet encoding remains 128 bits** for DA compatibility, but the **SID table storage** and **SRH segment entry encoding** use 32-bit compressed values. This is a SID allocation and FIB design optimization, not a protocol modification.

## 12.4 uSID Formats

### 12.4.1 uN (microNode-SID)

**uN** is the fundamental microsegment format for single-hop node segments—the most common SID type in SRv6 deployments.

```
uN Format:
Bits: | 16      | 8        | 8         | 16              | 80
      | 0xFC00  | PoP-ID   | Node-ID   | Function (End)  | Argument (often zero)
Hex representation: FC00:<pop>:<node>:<func>::<arg>

Example uN SID:
FC00:0:1:1::1
  Where:
  - 0xFC00 = uSID identifier
  - 0:1 = PoP-ID:Node-ID
  - 1 = Function code (End)
  - ::1 = Argument
```

When encoded as a uN microsegment, this becomes a 32-bit value that maps to the full SID:

```
uN Encoding (32 bits):
Bits 0-15: 0xFC00 (uSID marker)
Bits 16-23: PoP-ID (8)
Bits 24-31: Node-ID (8)
Bits 32-47: Function code (16)
Total: 48 bits in SID space, 32 bits stored in FIB

In SRH segment list, this 32-bit value represents what would be 128 bits:
FC00:0001:0001:0001::  (simplified)
```

### 12.4.2 uSF (microService-Function)

**uSF** encodes service function segments—behavior invocations that are chainable and reusable across multiple paths.

```
uSF Format:
Bits: | 16      | 16         | 16         | 16           | 64
      | 0xFC00  | SF-ID      | Chain-ID   | Function     | Argument

Example uSF SID:
FC00:0:2:100:1::200
  Where:
  - 0xFC00 = uSID identifier
  - 0:2 = Operator:PoP
  - 100 = Service Function ID (e.g., firewall)
  - 1 = Function code (End)
  - ::200 = Argument (specific flow or tenant)
```

uSF enables service chaining without per-flow state in transit nodes. The SF-ID identifies a shared service function, and the argument carries flow-specific metadata (tenant ID, flow label, etc.).

### 12.4.3 uA (microAdapter)

**uA** encodes interface or adapter-specific segments for scenarios requiring interface-level steering.

```
uA Format:
Bits: | 16      | 8        | 8          | 8          | 8         | 16          | 64
      | 0xFC00  | Operator | PoP-ID     | Node-ID    | IF-ID     | Function    | Arg

Example uA SID:
FC00:0:1:1:5:1::1
  Where:
  - 0xFC00 = uSID identifier
  - 0:1:1:5 = Operator:PoP:Node:Interface
  - 1 = Function (End.X for cross-connect)
  - ::1 = Argument
```

uA allows steering traffic to specific interfaces—for example, directing traffic through a particular link or interface on a multi-homed node.

## 12.5 uSID FIB Design

### 12.5.1 Two-Tier FIB Architecture

Hardware FIB implementation with uSID typically uses a two-tier lookup:

```
Tier 1 - Locator Lookup (TCAM):
- Key: DA[0:47] (48-bit locator prefix)
- Result: Next-hop + uSID block information
- Size: O(N) where N = number of nodes

Tier 2 - uSID Resolution (Exact Match):
- Key: uSID value (32 bits)
- Result: Complete 128-bit SID + behavior pointer
- Size: O(S) where S = number of active uSIDs
```

The Tier 1 lookup (locator-based) handles transit forwarding at line rate. The Tier 2 lookup (uSID-based) occurs only at segment endpoints and only for packets carrying uSID-encoded segments.

### 12.5.2 FIB Entry Reduction

Consider a network with 1,000 nodes, each publishing 10 SIDs (various behaviors):

| Without uSID FIB                 | With uSID FIB                  |
| -------------------------------- | ------------------------------ |
| 10,000 SID entries @ 128 bits    | 10,000 uSID entries @ 32 bits  |
| 1,280,000 bits stored            | 320,000 bits stored            |
| ~2,560 TCAM rows (512 bits each) | ~640 TCAM rows (512 bits each) |

Additionally, uSID enables **aggregation**: SIDs sharing the same locator can share a single Tier-1 TCAM entry, with the uSID value determining the specific behavior after FIB lookup.

### 12.5.3 Hardware Processing Pipeline

A typical uSID-capable ASIC processes packets as follows:

```
Hardware Pipeline:
1. Parse IPv6 DA
2. Check DA[0:15] == 0xFC00?
   - Yes: uSID detected
   - No: Normal 128-bit SID processing
3. If uSID:
   a. Extract uSID value (DA[16:47])
   b. Tier-2 lookup in SRAM (exact match)
   c. Get behavior + full SID mapping
   d. Execute behavior
4. If normal SID:
   a. Full SID FIB lookup in TCAM
   b. Execute behavior
5. Update DA from segment list (SRH lookup if SL > 0)
6. Forward
```

The uSID path adds one SRAM lookup but avoids the much slower TCAM lookup in the common case. For networks where most segments are node SIDs, this optimization significantly improves forwarding performance.

## 12.6 SRH Encoding with uSID

### 12.6.1 Compressed Segment Entries

When uSID is used, each segment entry in the SRH can be compressed from 128 bits to 32 bits:

```
Standard SRH Segment Entry: 128 bits
uSID SRH Segment Entry: 32 bits

SRH with 4 uN segments:
- Base SRH: 8 bytes
- Segments: 4 × 4 bytes = 16 bytes
- Total SRH: 24 bytes

Equivalent with full 128-bit SIDs:
- Base SRH: 8 bytes
- Segments: 4 × 16 bytes = 64 bytes
- Total SRH: 72 bytes

Savings: 48 bytes per packet (67% reduction)
```

This compression is transparent to the SRH processing logic—the segment entries are simply smaller values that resolve to full SIDs via lookup.

### 12.6.2 Mixed uSID and Full SID

SRH can carry a mix of uSID-encoded and full 128-bit segments:

```
Mixed Segment List Example:
Segments:
  1. uN (32-bit) → Node A End
  2. uN (32-bit) → Node B End.X
  3. Full SID (128-bit) → Complex behavior C
  4. uN (32-bit) → Node D End

SRH processing must handle this mixed encoding:
- Lookup each segment individually
- uSID segments resolve via uSID table
- Full SID segments use direct FIB
```

### 12.6.3 uSID Discovery and Distribution

uSID allocation is distributed via IGP (IS-IS or OSPFv3) extensions that carry both the full SID and its uSID encoding:

```
IGP Advertisement:
- Node-ID: router-id
- Locator: FC00:0:1:1::/64
- SID: FC00:0:1:1::1 (full)
- uSID: 0xFC00000100010001 (compressed)
- Behavior: End
```

The IGP carries the mapping between full SID and uSID, allowing all nodes in the domain to resolve uSID values correctly. This distribution is identical to how regular SIDs are advertised—the IGP simply carries the additional uSID field.

## 12.7 Operational Considerations

### 12.7.1 uSID Allocation Planning

Successful uSID deployment requires careful allocation planning:

1. **Operator ID**: Reserve a block for your organization (assigned via IANA or use enterprise-specific value)
2. **PoP Structure**: Map physical PoPs to PoP-ID values
3. **Node Hierarchy**: Assign Node-IDs reflecting your node naming/numbering scheme
4. **Function Allocation**: Document behavior codes per node for consistency
5. **Argument Space**: Reserve argument bits for tenant/flow identification

A well-designed allocation scheme enables:

- Route aggregation based on PoP-ID
- Easy identification of segment source from uSID value
- Predictable function code mapping across nodes

### 12.7.2 Migration from Full SID

Migrating from full 128-bit SIDs to uSID follows this sequence:

```
Phase 1: Dual-Stack Operation
- Configure new nodes with both full SID and uSID
- IGP advertises both encodings
- Existing full-SID paths continue working
- New paths can use uSID

Phase 2: uSID-Only for New Paths
- New SR Policies use uSID segment lists
- Existing paths continue with full SID
- Measure uSID adoption rate

Phase 3: Migration of Existing Paths
- Convert existing SR Policies to uSID
- Verify behavior equivalence
- Monitor for any anomalies

Phase 4: Full uSID Operation
- Remove full SID configurations (or keep for backward compat)
- All paths use uSID encoding
- Monitor and optimize uSID FIB size
```

### 12.7.3 Troubleshooting uSID

uSID issues typically manifest as:

1. **Packet Drop at Endpoint**: uSID not resolved, behavior not found
   - Verify IGP advertisement includes uSID mapping
   - Check uSID table consistency across nodes

2. **Behavior Mismatch**: Wrong behavior executed
   - uSID function code mismatch
   - Verify function code allocation matches across nodes

3. **Forwarding Loops**: Packets circling network
   - uSID lookup failure causing DA not to update
   - Transit nodes forwarding based on unresolved uSID as DA

Debugging tools include:

- `show srv6 sid` - display local SID table with uSID mappings
- `show srv6 fib` - display FIB entries (both locator and uSID)
- Packet capture with uSID filter to examine compressed segment lists

## 12.8 uSID Deployments in Practice

### 12.8.1 Carrier Backbone Example

A tier-1 ISP deploying SRv6 across 50 PoPs with 20 nodes each:

```
Allocation:
- Operator ID: 0x0001 (assigned)
- PoP IDs: 0x01-0x32 (50 PoPs)
- Node IDs: 0x01-0x14 (20 nodes per PoP)
- Functions: 0x0001 (End), 0x0002 (End.X), etc.

Example uSID for Node 5 in PoP 12:
- Full SID: FC00:0001:0C05:0001::1
- uSID: 0xFC0000010C050001
- Meaning: Operator 1, PoP 12, Node 5, Function End

Path across 3 PoPs (3 uN segments):
- PoP-12:Node-5:End
- PoP-18:Node-8:End.X(via interface 3)
- PoP-23:Node-2:End.DT6(VRF tenant-100)

SRH with uSID: 3 × 4 bytes = 12 bytes (vs 48 bytes with full SID)
```

### 12.8.2 Data Center Fabric Example

In a large-scale data center using SRv6 for VM migration and service chaining:

```
Allocation:
- Operator ID: 0x0001 (enterprise)
- PoP equivalent: Pod-ID (8 bits, up to 256 pods)
- Node ID: Top-of-Rack switch ID
- Function: Behavior code

uSF for firewall service:
- SF-ID: 0x0100 (firewall)
- Chain-ID: 0x01 (chain-1)
- uSF value encodes both service and chain membership

When VM migration traverses firewall:
1. Packet DA = uN for ToR switch at source
2. SRH contains uSF for firewall (service function)
3. After firewall processing, uN for destination ToR
```

## 12.9 Summary

uSID compression is essential for practical SRv6 deployment at scale:

- **Header Efficiency**: 32-bit segment encoding reduces SRH overhead by 75% compared to full 128-bit SIDs, enabling practical deployment with long segment lists.

- **Hardware Optimization**: Two-tier FIB (TCAM for locators, SRAM for uSID) provides line-rate transit forwarding while keeping uSID state in fast memory.

- **Hierarchical Allocation**: The uSID block structure (Operator/PoP/Node/Function) enables route aggregation, easy debugging, and predictable allocation.

- **Three Formats**: uN (node segments), uSF (service functions), and uA (adapter segments) cover the common cases: single-hop node routing, service chaining, and interface-specific steering.

- **Protocol Transparent**: uSID is a SID encoding and FIB optimization, not a protocol change. Packets carry 128-bit values; the compression is in SID table storage and SRH segment encoding.

- **Migration Path**: Phase migration from full SID to uSID maintains operational continuity while progressively adopting the compressed format.

For production SRv6 deployments beyond trivial scale, uSID is not optional—it is a fundamental requirement for efficient hardware forwarding and reasonable header overhead. The IETF standardization of uSID provides vendor interoperability and a clear migration path from early full-SID deployments.

---

**References**

- IETF Draft: SRv6 Microsegment (uSID)
- IETF Draft: SRv6 Network Programming - Compressed SID Format
- RFC 8986: SRv6 Network Programming
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8402: Segment Routing Architecture
- RFC 8667: IS-IS SRv6 Extensions
- RFC 8668: OSPFv3 Extensions for SRv6
