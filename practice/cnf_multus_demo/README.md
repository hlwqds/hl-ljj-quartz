# CNF Data Plane Demo: VPP + DPDK + memif

Demonstrates a real **Cloud-Native Network Function (CNF)** data plane using
VPP as the forwarding engine, with DPDK-style I/O and memif shared-memory
interfaces.

## What This Demo Covers

| Tier | Technology       | Data Path                  | Requirements       |
| ---- | ---------------- | -------------------------- | ------------------ |
| 0    | Linux forwarding | veth + kernel `ip_forward` | None (baseline)    |
| 1    | VPP + AF_PACKET  | veth + VPP userspace       | `vpp` package      |
| 2    | VPP + memif      | shared memory zero-copy    | `vpp` package      |
| 3    | K8s + Multus     | vhost-user / SR-IOV        | Kubernetes cluster |

Tier 0 is the "before" picture. Tiers 1-2 are the real CNF data plane.
Tier 3 shows how this maps to production Kubernetes.

## Data Path Comparison

```
Tier 0: Linux Kernel Forwarding (baseline)
┌────────┐    veth     ┌──────────────┐    veth     ┌────────┐
│  App   │────────────▶│ Linux netns  │────────────▶│  WAN   │
│        │  syscall    │ ip_forward=1 │  syscall    │        │
│        │  (copy)     │  (copy)      │  (copy)     │        │
└────────┘             └──────────────┘             └────────┘
  ~3 context switches per packet, ~1-5 μs latency

Tier 1: VPP + AF_PACKET (userspace forwarding)
┌────────┐    veth     ┌──────────────────────┐    veth     ┌────────┐
│  App   │────────────▶│        VPP           │────────────▶│  WAN   │
│        │             │ AF_PACKET rx/tx      │             │        │
│        │             │ userspace forwarding │             │        │
│        │             │ node graph pipeline  │             │        │
└────────┘             └──────────────────────┘             └────────┘
  1 context switch, VPP does L2/L3/L4 in userspace
  ~500 ns - 1 μs per packet (single core)

Tier 2: VPP + memif (zero-copy shared memory)
┌────────┐             ┌──────────────────────┐             ┌────────┐
│  App   │   memif     │        VPP           │   memif     │  WAN   │
│ (VPP   │◄═══════════▶│     CNF Instance     │◄═══════════▶│ (VPP   │
│  agent)│ shared mem  │  zero-copy forwarding│ shared mem  │  agent)│
└────────┘             └──────────────────────┘             └────────┘
  No context switches, no syscall, no copy
  ~100-300 ns per packet (shared memory ring)
```

## Architecture

```
Kubernetes / Multus production shape:

  App Pod                CNF Pod                      WAN / External
┌─────────┐         ┌─────────────────┐          ┌──────────────┐
│         │ net1    │  ┌───────────┐  │  net2    │              │
│  App    │────────▶│  │    VPP    │  │─────────▶│  Physical    │
│         │ veth/   │  │ DPDK/memif│  │ vhost/   │  NIC / VF    │
│         │ memif   │  │ node graph│  │ SR-IOV   │              │
│         │         │  └───────────┘  │          │              │
│         │         │  ┌───────────┐  │          │              │
│         │         │  │  Control  │  │          │              │
│         │         │  │  Agent    │  │          │              │
│         │         │  └───────────┘  │          │              │
└─────────┘         └─────────────────┘          └──────────────┘
                     privileged + hugepages
                     + Multus dual-network
```

## Quick Start

### Prerequisites

```bash
# Tier 0: No prerequisites (uses Linux kernel)

# Tier 1-2: podman + VPP container image
sudo dnf install -y podman        # Fedora
sudo apt install -y podman        # Ubuntu

# Pull VPP image (automatically pulled by scripts if not present)
podman pull docker.io/calicovpp/vpp:latest
```

### Run

```bash
cd practice/cnf_multus_demo

# Tier 0: Linux baseline (always works)
sudo ./01_setup_ns.sh
sudo ./02_test_linux.sh          # ping through kernel forwarding

# Tier 1: VPP as CNF (requires vpp package)
sudo ./03_setup_vpp.sh
sudo ./04_test_vpp.sh            # ping through VPP userspace forwarding

# Tier 2: memif zero-copy (requires VPP + memif plugin)
sudo ./05_setup_memif.sh
sudo ./06_test_memif.sh          # traffic through shared memory

# Cleanup everything
sudo ./99_cleanup.sh
```

## How This Maps to Real CNF

| Demo Component    | Production Equivalent                |
| ----------------- | ------------------------------------ |
| Network namespace | Kubernetes Pod (netns per Pod)       |
| veth pair         | Multus secondary interface           |
| VPP in namespace  | VPP container in CNF Pod             |
| AF_PACKET on veth | AF_XDP / virtio-pmd / ice-pmd        |
| memif ring        | memif between containers (same node) |
| vppctl            | gRPC / RESTCONF management API       |
| ip route add      | Multus + IPAM (Whereabouts / Calico) |

### Real CNF Pod Spec

See `manifests/cnf-vpp-pod.yaml` for a production-style Kubernetes manifest with:

- `privileged: true` + hugepage mounts for DPDK
- Multus dual-network annotations
- VPP with memif + AF_XDP plugins
- Resource limits for dedicated CPU cores and hugepages

### Real Multus + SR-IOV

See `manifests/sriov-network.yaml` for SR-IOV based CNF data path:

```
App Pod
  └─ net1: SR-IOV VF (PF: ens1f0)
       │
       ▼
CNF Pod (DPDK userspace driver on VF)
  net1: SR-IOV VF → DPDK ice PMD
  net2: memif → another CNF Pod on same node
       │
       ▼
External network
```

## Key CNF Concepts Demonstrated

1. **Userspace packet processing**: VPP's node graph pipeline runs entirely in
   userspace, bypassing the kernel network stack.

2. **Zero-copy data path**: memif uses shared memory rings between VPP instances,
   no syscall or data copy required.

3. **DPDK PMD drivers**: In production, veth is replaced by DPDK poll-mode drivers
   (vfio-pci) for direct NIC access.

4. **vhost-user**: For VM-based CNFs, vhost-user provides zero-copy shared memory
   between the VM and the host's VPP/OVS-DPDK instance.

5. **Single writer per cache line**: VPP's internal data structures follow the
   same principles as DPDK ring — each worker thread owns its own packet vector,
   avoiding false sharing on the hot path.
