# Guest DPDK virtio/vhost-user Lab

This practice demonstrates a commercial-style NFV path:

```text
Host OVS-DPDK / vhost-user backend
  -> QEMU virtio-net PCI device
  -> Guest DPDK virtio PMD
  -> Guest dpdk-testpmd
```

The goal is to make the roles clear:

```text
Guest:
  DPDK app owns the virtio-net device through the virtio PMD.

QEMU/KVM:
  Creates the virtio-net PCI device and passes guest memory, vring addresses,
  and eventfds to the host backend over the vhost-user socket.

Host:
  OVS-DPDK owns the vhost-user backend port and connects it to a userspace
  datapath.
```

The automated smoke test also creates Host-side test traffic:

```text
Host raw Ethernet sender
  -> OVS internal port host-traffic0
  -> OVS-DPDK br-dpdk
  -> vhost-user0
  -> QEMU virtio-net data port
  -> Guest testpmd port 0
```

Without this traffic source, `testpmd` can still prove that the virtio PMD
starts and the link is up, but RX/TX packet counters remain zero.

## Files

```text
practice/guest_dpdk_virtio/
├── README.md
├── run_host_lab.sh
├── host/
│   ├── 00_install_fedora_deps.sh
│   ├── 01_setup_hugepages.sh
│   ├── 02_setup_ovs_dpdk_vhost_user.sh
│   ├── 03_setup_test_traffic_port.sh
│   └── 04_send_test_traffic.py
├── qemu/
│   └── start_guest_vhost_user.sh
└── guest/
    ├── run_guest_lab.sh
    ├── 01_setup_hugepages.sh
    ├── 02_bind_virtio_to_vfio.sh
    └── 03_run_testpmd.sh
```

## Architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Host                                                                 │
│                                                                      │
│  OVS-DPDK                                                            │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ br-dpdk                                                      │    │
│  │   vhost-user0  <---- Unix socket ---->  QEMU virtio-net      │    │
│  │   dpdk physical port or another vhost port                   │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  QEMU/KVM                                                            │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ virtio-net-pci                                               │    │
│  │ guest memory backend: hugepage, share=on, prealloc=on        │    │
│  └──────────────────────────────────────────────────────────────┘    │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ virtqueue in guest memory
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Guest VM                                                              │
│                                                                      │
│  dpdk-testpmd                                                         │
│    -> DPDK virtio PMD                                                 │
│    -> virtio-net PCI device                                           │
│                                                                      │
│  The virtio-net device is bound to vfio-pci/uio, so packets bypass    │
│  the guest Linux network stack.                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## One-command Flow

There are two one-command scripts because Host setup and Guest setup run in
different operating systems.

If you prefer Ansible for the Host side:

```bash
ansible-playbook -i ansible/inventory.ini ansible/guest_image.yml
ansible-playbook -i ansible/inventory.ini ansible/host_lab.yml \
  -e guest_image=generated/images/dpdk-guest.qcow2
```

The Ansible path downloads a cloud guest image, writes cloud-init configuration,
prepares host hugepages, OVS-DPDK, the vhost-user port, and writes
`generated/qemu-env.sh`. See `ansible/README.md`.

After `generated/qemu-env.sh` exists, `sudo ./run_host_lab.sh` will load it
automatically if `GUEST_IMAGE` is not set explicitly.

For the most automated path:

```bash
sudo AUTO_PREPARE_GUEST=1 ./run_host_lab.sh
```

This makes `run_host_lab.sh` call `ansible/guest_image.yml` first when
`generated/qemu-env.sh` is missing, start QEMU in the background, wait for the
guest management SSH port, copy the guest scripts, run the guest smoke test, and
then stop QEMU again so hugepage memory is released.

Useful automation knobs:

```bash
# Default resource limit: 1 GiB Guest memory, 2 vCPUs, QEMU pinned by taskset.
# Override only when you intentionally want more.
sudo AUTO_PREPARE_GUEST=1 MEM_SIZE=2048M SMP=4 QEMU_CPUSET=4-7 ./run_host_lab.sh

# Keep the VM running after the automated smoke test.
sudo AUTO_PREPARE_GUEST=1 KEEP_VM_AFTER_RUN=1 ./run_host_lab.sh

# Manual mode: leave QEMU attached to the terminal and run guest commands yourself.
sudo AUTO_RUN_GUEST=0 ./run_host_lab.sh

# Recreate the generated cloud image and cloud-init seed ISO.
sudo AUTO_PREPARE_GUEST=1 AUTO_REBUILD_GUEST=1 ./run_host_lab.sh
```

The script also cleans up an old lab QEMU process before starting a new one.
Disable that only if you are intentionally running the VM yourself:

```bash
sudo CLEANUP_OLD_VM=0 KEEP_VM_AFTER_RUN=1 ./run_host_lab.sh
```

By default QEMU is started through `taskset` and `nice`:

```text
MEM_SIZE=1024M
SMP=2
QEMU_CPUSET=2-3     # auto-detected when possible
QEMU_NICE=10
Host HUGEPAGES_2M=1024
Guest HUGEPAGES_2M=256
TRAFFIC_PACKETS=256
TRAFFIC_WAIT=8
```

This keeps the lab from consuming all host CPUs and limits hugepage
preallocation to 1 GiB for the VM plus a small OVS-DPDK budget unless you
override it.

Before QEMU starts, `run_host_lab.sh` now validates two things:

```text
free hugepage memory >= MEM_SIZE
number of CPUs in QEMU_CPUSET >= SMP
```

For example, `SMP=4 QEMU_CPUSET=3` is rejected because it creates four guest
vCPUs but pins QEMU to only one host CPU. Use `SMP=1 QEMU_CPUSET=3` or
`SMP=2 QEMU_CPUSET=2-3` for a small desktop-friendly lab.

On Fedora, `run_host_lab.sh` also installs missing host dependencies by default:

```text
openvswitch-dpdk
dpdk
dpdk-tools
qemu-kvm
qemu-img
genisoimage
cloud-utils-cloud-localds
pciutils
```

Disable this if you want to install packages manually:

```bash
sudo AUTO_INSTALL_DEPS=0 AUTO_PREPARE_GUEST=1 ./run_host_lab.sh
```

`run_host_lab.sh` auto-detects the Host NUMA node count for OVS-DPDK
`dpdk-socket-mem`. On a single-node machine it uses `512`; on a two-node
machine it uses `512,512`. Override it only when you need a specific layout:

```bash
sudo SOCKET_MEM=1024 ./run_host_lab.sh
sudo SOCKET_MEM=1024,1024 ./run_host_lab.sh
```

If OVS-DPDK is not installed yet and you only want to boot the guest image first:

```bash
sudo SKIP_OVS=1 ./run_host_lab.sh
```

This skips Host OVS-DPDK backend setup. The guest can boot, but the vhost-user
network has no Host backend until OVS-DPDK or another backend is installed.

On the Host:

```bash
cd practice/guest_dpdk_virtio
sudo GUEST_IMAGE=/var/lib/libvirt/images/dpdk-guest.qcow2 ./run_host_lab.sh
```

The Host script prints each important step:

```text
Step 1/3: prepare host hugepages
Step 2/3: configure OVS-DPDK bridge and vhost-user client port
Step 3/3: start QEMU with virtio-net + vhost-user
```

Inside the Guest:

```bash
cd practice/guest_dpdk_virtio
sudo ./guest/run_guest_lab.sh 0000:00:03.0
```

The Guest script prints each important step:

```text
Step 1/4: prepare guest hugepages
Step 2/4: use or auto-detect virtio-net PCI device
Step 3/4: bind virtio-net device to DPDK driver
Step 4/4: start dpdk-testpmd
```

If there is exactly one virtio-net device, the Guest script can usually detect
it automatically:

```bash
sudo ./guest/run_guest_lab.sh
```

The automated lab defaults to `uio_pci_generic` for the Guest virtio-net device.
That is intentional: this is a nested QEMU virtio lab, not physical PCI
passthrough, and `vfio-pci` often fails inside the guest unless IOMMU/VFIO is
configured for that VM.

To force a different driver:

```bash
sudo DRIVER=vfio-pci ./guest/run_guest_lab.sh 0000:00:03.0
```

## Manual Run Order

### 1. Host hugepages

```bash
cd practice/guest_dpdk_virtio
sudo ./host/01_setup_hugepages.sh
```

### 2. Host OVS-DPDK vhost-user port

This assumes OVS was built with DPDK support and the service is installed.

```bash
sudo ./host/02_setup_ovs_dpdk_vhost_user.sh
```

The script creates a userspace bridge and a `dpdkvhostuserclient` port:

```text
br-dpdk
  vhost-user0 -> /var/run/openvswitch/vhost-user0.sock
```

### 3. Start QEMU

Set `GUEST_IMAGE` to an existing VM disk image:

```bash
export GUEST_IMAGE=/var/lib/libvirt/images/dpdk-guest.qcow2
sudo ./qemu/start_guest_vhost_user.sh
```

QEMU creates the vhost-user socket in server mode. OVS-DPDK connects to it.
If the disk image is not qcow2, set `GUEST_IMAGE_FORMAT=raw` or another QEMU
format name.

### 4. Inside Guest: hugepages

```bash
sudo ./guest/01_setup_hugepages.sh
```

### 5. Inside Guest: bind virtio PCI device

Find the virtio-net PCI address:

```bash
sudo dpdk-devbind.py -s
```

Then bind it:

```bash
sudo ./guest/02_bind_virtio_to_vfio.sh 0000:00:03.0
```

Manual bind example:

```bash
sudo DRIVER=uio_pci_generic ./guest/02_bind_virtio_to_vfio.sh 0000:00:03.0
```

### 6. Inside Guest: run testpmd

```bash
sudo ./guest/03_run_testpmd.sh
```

In the testpmd prompt:

```text
testpmd> show port info all
testpmd> set fwd io
testpmd> start
testpmd> show port stats all
```

## Notes

- This lab is a template. Real machines need matching CPU pinning, NUMA, NIC,
  and OVS-DPDK configuration.
- For one-port testing, `testpmd` can verify that the guest virtio PMD probes
  the device and can start queues. For throughput tests, add a second vhost port
  or a physical DPDK port on the host bridge.
- If you want a VM-to-VM test, create two vhost-user ports and start two VMs.
- If you want an external traffic test, add a host physical DPDK port to
  `br-dpdk`.
