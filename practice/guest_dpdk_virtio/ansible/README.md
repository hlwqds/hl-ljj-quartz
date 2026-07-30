# Ansible Host Setup for Guest DPDK virtio/vhost-user Lab

These playbooks automate the lab setup:

```text
guest_image.yml:
  downloads a cloud image
  creates a qcow2 overlay
  writes cloud-init user-data/meta-data
  installs DPDK packages in the guest on first boot
  writes generated/qemu-env.sh

host_lab.yml:
  prepares the host networking side
```

`host_lab.yml` automates:

```text
Host hugepages
OVS-DPDK init
OVS netdev bridge
dpdkvhostuserclient port
QEMU command preview
```

`guest_image.yml` downloads an Ubuntu cloud image by default. You can override
`base_image_url` if you prefer another cloud image.

## Run

From `practice/guest_dpdk_virtio`:

### 1. Build guest image

```bash
ansible-playbook -i ansible/inventory.ini ansible/guest_image.yml
```

This creates:

```text
generated/images/dpdk-guest.qcow2
generated/images/seed.iso
generated/qemu-env.sh
```

The first boot uses cloud-init to install:

```text
dpdk
dpdk-dev
pciutils
build-essential
```

### 2. Prepare Host OVS-DPDK

```bash
ansible-playbook -i ansible/inventory.ini ansible/host_lab.yml \
  -e guest_image=generated/images/dpdk-guest.qcow2
```

For a raw image:

```bash
ansible-playbook -i ansible/inventory.ini ansible/host_lab.yml \
  -e guest_image=/var/lib/libvirt/images/dpdk-guest.raw \
  -e guest_image_format=raw
```

Useful overrides:

```bash
-e hugepages_2m=1024
-e socket_mem=1024        # single NUMA node
-e socket_mem=1024,1024   # two NUMA nodes
-e bridge=br-dpdk
-e vhost_port=vhost-user0
-e vhost_socket=/var/run/openvswitch/vhost-user0.sock
-e qemu_mem=1024M
-e qemu_smp=2
-e queues=1
```

### 3. Start QEMU

After the playbooks succeed, start the VM with:

```bash
sudo ./qemu/start_guest_vhost_user.sh
```

The playbook writes the required environment file to:

```text
generated/qemu-env.sh
```

Load it before starting QEMU:

```bash
set -a
. generated/qemu-env.sh
set +a
sudo -E ./qemu/start_guest_vhost_user.sh
```
