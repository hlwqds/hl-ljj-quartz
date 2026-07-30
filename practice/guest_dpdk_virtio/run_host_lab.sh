#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$LAB_DIR/generated/qemu-env.sh}"
USER_MEM_SIZE_SET="${MEM_SIZE+x}"
USER_MEM_SIZE_VALUE="${MEM_SIZE:-}"
USER_SMP_SET="${SMP+x}"
USER_SMP_VALUE="${SMP:-}"
USER_QEMU_CPUSET_SET="${QEMU_CPUSET+x}"
USER_QEMU_CPUSET_VALUE="${QEMU_CPUSET:-}"
USER_QEMU_BIN_SET="${QEMU_BIN+x}"
USER_QEMU_BIN_VALUE="${QEMU_BIN:-}"

GUEST_IMAGE="${GUEST_IMAGE:-}"
GUEST_IMAGE_FORMAT="${GUEST_IMAGE_FORMAT:-qcow2}"
VM_NAME="${VM_NAME:-dpdk-guest}"
MEM_SIZE="${MEM_SIZE:-1024M}"
SMP="${SMP:-2}"
QUEUES="${QUEUES:-1}"
BRIDGE="${BRIDGE:-br-dpdk}"
VHOST_PORT="${VHOST_PORT:-vhost-user0}"
VHOST_SOCKET="${VHOST_SOCKET:-/var/run/openvswitch/vhost-user0.sock}"
TRAFFIC_PORT="${TRAFFIC_PORT:-host-traffic0}"
TRAFFIC_PACKETS="${TRAFFIC_PACKETS:-256}"
TRAFFIC_WAIT="${TRAFFIC_WAIT:-8}"
TRAFFIC_INTERVAL="${TRAFFIC_INTERVAL:-0.005}"
HUGEPAGES_2M="${HUGEPAGES_2M:-1024}"
SOCKET_MEM="${SOCKET_MEM:-}"
CLOUD_INIT_ISO="${CLOUD_INIT_ISO:-}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_CPUSET="${QEMU_CPUSET:-}"
QEMU_NICE="${QEMU_NICE:-10}"
ALLOW_CPU_OVERSUBSCRIBE="${ALLOW_CPU_OVERSUBSCRIBE:-0}"
AUTO_PREPARE_GUEST="${AUTO_PREPARE_GUEST:-0}"
SKIP_OVS="${SKIP_OVS:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"
ALLOW_SELINUX_PERMISSIVE="${ALLOW_SELINUX_PERMISSIVE:-1}"
AUTO_RUN_GUEST="${AUTO_RUN_GUEST:-1}"
CLEANUP_OLD_VM="${CLEANUP_OLD_VM:-1}"
KEEP_VM_AFTER_RUN="${KEEP_VM_AFTER_RUN:-0}"
GUEST_USER="${GUEST_USER:-dpdk}"
MGMT_SSH_PORT="${MGMT_SSH_PORT:-10022}"
SSH_KEY="${SSH_KEY:-}"
SSH_WAIT_TIMEOUT="${SSH_WAIT_TIMEOUT:-240}"
CLOUD_INIT_WAIT_TIMEOUT="${CLOUD_INIT_WAIT_TIMEOUT:-180}"
QEMU_PIDFILE="${QEMU_PIDFILE:-$LAB_DIR/generated/qemu.pid}"
QEMU_LOG="${QEMU_LOG:-$LAB_DIR/generated/qemu.log}"
AUTO_REBUILD_GUEST="${AUTO_REBUILD_GUEST:-0}"

log_step() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

detect_ssh_key() {
  if [[ -n "$SSH_KEY" ]]; then
    return
  fi

  local home_dir="${HOME:-}"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    home_dir="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  fi

  if [[ -r "$home_dir/.ssh/id_rsa" ]]; then
    SSH_KEY="$home_dir/.ssh/id_rsa"
  elif [[ -r "$home_dir/.ssh/id_ed25519" ]]; then
    SSH_KEY="$home_dir/.ssh/id_ed25519"
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo GUEST_IMAGE=/path/to/guest.qcow2 $0" >&2
    exit 1
  fi
}

install_host_deps() {
  if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
    return
  fi

  if [[ -x "$LAB_DIR/host/00_install_fedora_deps.sh" ]]; then
    if ! command -v ovs-vsctl >/dev/null || ! command -v qemu-img >/dev/null || ! command -v cloud-localds >/dev/null; then
      log_step "AUTO_INSTALL_DEPS=1: install missing Fedora host dependencies"
      "$LAB_DIR/host/00_install_fedora_deps.sh"
    fi
  fi
}

prepare_guest_image() {
  if [[ "$AUTO_PREPARE_GUEST" != "1" ]]; then
    return
  fi

  if [[ -f "$ENV_FILE" && "$AUTO_REBUILD_GUEST" != "1" ]]; then
    if generated_guest_config_is_stale; then
      AUTO_REBUILD_GUEST=1
      log_step "Generated guest config is stale; rebuild guest image and seed ISO"
    else
      log_step "AUTO_PREPARE_GUEST=1: generated guest image is already up to date"
      return 0
    fi
  fi

  if ! command -v ansible-playbook >/dev/null; then
    echo "AUTO_PREPARE_GUEST=1 requested, but ansible-playbook was not found" >&2
    exit 1
  fi

  log_step "AUTO_PREPARE_GUEST=1: build guest image with Ansible"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$SUDO_USER" \
      ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
      ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
      ansible-playbook -i "$LAB_DIR/ansible/inventory.ini" "$LAB_DIR/ansible/guest_image.yml" \
        -e "recreate_guest_image=$AUTO_REBUILD_GUEST"
  else
    ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
    ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
      ansible-playbook -i "$LAB_DIR/ansible/inventory.ini" "$LAB_DIR/ansible/guest_image.yml" \
        -e "recreate_guest_image=$AUTO_REBUILD_GUEST"
  fi
}

generated_guest_config_is_stale() {
  local user_data="$LAB_DIR/generated/user-data"

  if [[ -r "$user_data" ]] && rg -q 'vm\.nr_hugepages=1024|sysctl -w vm\.nr_hugepages=1024' "$user_data"; then
    return 0
  fi

  if [[ -r "$user_data" ]] && ! rg -q 'linux-modules-extra-\$\(uname -r\)' "$user_data"; then
    return 0
  fi

  if [[ -r "$ENV_FILE" ]] && rg -q '^MEM_SIZE=2048M$|^SMP=4$' "$ENV_FILE"; then
    return 0
  fi

  return 1
}

detect_socket_mem() {
  local per_socket_mb="${OVS_SOCKET_MEM_PER_NODE:-512}"
  local nodes=()

  if compgen -G "/sys/devices/system/node/node[0-9]*" >/dev/null; then
    local node_dir
    for node_dir in /sys/devices/system/node/node[0-9]*; do
      [[ -d "$node_dir" ]] || continue
      nodes+=("${node_dir##*/node}")
    done
  fi

  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "$per_socket_mb"
    return
  fi

  local result="$per_socket_mb"
  local i
  for ((i = 1; i < ${#nodes[@]}; i++)); do
    result+=",$per_socket_mb"
  done
  echo "$result"
}

detect_qemu_cpuset() {
  local cpus
  cpus="$(nproc 2>/dev/null || echo 1)"

  if (( cpus >= SMP + 2 )); then
    local start=2
    local end=$((start + SMP - 1))
    echo "$start-$end"
  elif (( cpus >= SMP )); then
    echo "0-$((SMP - 1))"
  else
    echo "0"
  fi
}

mem_size_to_mb() {
  local value="$1"
  local number unit

  if [[ "$value" =~ ^([0-9]+)([KkMmGgTt]?)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
  else
    echo "unsupported MEM_SIZE format: $value" >&2
    return 1
  fi

  case "$unit" in
    "") echo "$number" ;;
    k) echo $(((number + 1023) / 1024)) ;;
    m) echo "$number" ;;
    g) echo $((number * 1024)) ;;
    t) echo $((number * 1024 * 1024)) ;;
    *)
      echo "unsupported MEM_SIZE unit: $value" >&2
      return 1
      ;;
  esac
}

cpuset_cpu_count() {
  local cpuset="$1"
  local total=0
  local part start end

  [[ -n "$cpuset" ]] || {
    echo 0
    return
  }

  IFS=',' read -ra parts <<< "$cpuset"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( end >= start )); then
        total=$((total + end - start + 1))
      fi
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      total=$((total + 1))
    fi
  done

  echo "$total"
}

validate_qemu_resources() {
  local mem_mb free_pages page_kb free_mb cpuset_count
  mem_mb="$(mem_size_to_mb "$MEM_SIZE")"
  free_pages="$(awk '/HugePages_Free:/ {print $2}' /proc/meminfo)"
  page_kb="$(awk '/Hugepagesize:/ {print $2}' /proc/meminfo)"
  free_mb=$((free_pages * page_kb / 1024))
  cpuset_count="$(cpuset_cpu_count "$QEMU_CPUSET")"

  log_step "Validate QEMU resource limits"
  cat <<EOF
  qemu memory requested: ${mem_mb} MB
  free hugepage memory:  ${free_mb} MB
  qemu vcpus:            $SMP
  qemu cpuset CPUs:      ${cpuset_count:-0}
EOF

  if (( free_mb < mem_mb )); then
    cat >&2 <<EOF
Not enough free hugepage memory for QEMU.

QEMU uses preallocated hugepage memory in this lab:
  MEM_SIZE=$MEM_SIZE requires about ${mem_mb} MB
  free hugepage memory is about ${free_mb} MB

Use a smaller VM:
  sudo MEM_SIZE=768M SMP=1 QEMU_CPUSET=3 ./run_host_lab.sh

Or allocate more host hugepages before running:
  sudo HUGEPAGES_2M=1536 MEM_SIZE=1024M ./run_host_lab.sh
EOF
    exit 1
  fi

  if (( cpuset_count > 0 && SMP > cpuset_count && ALLOW_CPU_OVERSUBSCRIBE != 1 )); then
    cat >&2 <<EOF
QEMU CPU limit is inconsistent.

SMP=$SMP creates $SMP guest vCPUs, but QEMU_CPUSET=$QEMU_CPUSET contains only
$cpuset_count host CPU(s). For this lab, keep them aligned:

  sudo SMP=1 QEMU_CPUSET=3 ./run_host_lab.sh
  sudo SMP=2 QEMU_CPUSET=2-3 ./run_host_lab.sh

If you intentionally want to oversubscribe, set:
  ALLOW_CPU_OVERSUBSCRIBE=1
EOF
    exit 1
  fi
}

prepare_fedora_selinux() {
  if [[ "$ALLOW_SELINUX_PERMISSIVE" != "1" ]]; then
    return
  fi

  if ! command -v getenforce >/dev/null || [[ "$(getenforce)" != "Enforcing" ]]; then
    return
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  if [[ "${ID:-}" != "fedora" ]]; then
    return
  fi

  log_step "ALLOW_SELINUX_PERMISSIVE=1: allow OVS-DPDK hugepage mmap on Fedora"
  if command -v semanage >/dev/null; then
    semanage permissive -a openvswitch_t 2>/dev/null || true
    echo "Set SELinux domain openvswitch_t to permissive for this lab."
  else
    setenforce 0
    echo "semanage not found; temporarily set global SELinux mode to Permissive."
  fi
}

ssh_base_args() {
  local args=(
    -p "$MGMT_SSH_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -o BatchMode=yes
  )

  if [[ -n "$SSH_KEY" ]]; then
    args+=(-i "$SSH_KEY")
  fi

  printf '%q ' "${args[@]}"
}

scp_base_args() {
  local args=(
    -P "$MGMT_SSH_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -o BatchMode=yes
  )

  if [[ -n "$SSH_KEY" ]]; then
    args+=(-i "$SSH_KEY")
  fi

  printf '%q ' "${args[@]}"
}

stop_pid() {
  local pid="$1"
  local label="$2"

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || ! -d "/proc/$pid" ]]; then
    return
  fi

  echo "Stop $label pid=$pid"
  kill "$pid" 2>/dev/null || true

  local i
  for i in {1..20}; do
    if [[ ! -d "/proc/$pid" ]]; then
      return
    fi
    sleep 0.2
  done

  echo "Force stop $label pid=$pid"
  kill -9 "$pid" 2>/dev/null || true
}

cleanup_lab_qemu() {
  local reason="${1:-cleanup old lab QEMU}"
  local pid
  local pids=()

  log_step "$reason"

  if [[ -r "$QEMU_PIDFILE" ]]; then
    pid="$(tr -dc '0-9' < "$QEMU_PIDFILE" || true)"
    if [[ -n "$pid" ]]; then
      pids+=("$pid")
    fi
  fi

  if command -v pgrep >/dev/null; then
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      pids+=("$pid")
    done < <(pgrep -f "qemu-system.*-name ${VM_NAME}" || true)

    if [[ -n "$GUEST_IMAGE" ]]; then
      while read -r pid; do
        [[ -n "$pid" ]] || continue
        pids+=("$pid")
      done < <(pgrep -f "qemu-system.*${GUEST_IMAGE}" || true)
    fi
  fi

  local seen=" "
  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" != "$$" ]] || continue
    if [[ "$seen" == *" $pid "* ]]; then
      continue
    fi
    seen+="$pid "
    stop_pid "$pid" "$VM_NAME"
  done

  rm -f "$QEMU_PIDFILE" "$VHOST_SOCKET"
}

cleanup_auto_run() {
  if [[ "$AUTO_RUN_GUEST" == "1" && "$KEEP_VM_AFTER_RUN" != "1" ]]; then
    cleanup_lab_qemu "Stop QEMU and release hugepages"
  fi
}

start_qemu() {
  local cmd=(
    env
    "GUEST_IMAGE=$GUEST_IMAGE"
    "GUEST_IMAGE_FORMAT=$GUEST_IMAGE_FORMAT"
    "VM_NAME=$VM_NAME"
    "MEM_SIZE=$MEM_SIZE"
    "SMP=$SMP"
    "QUEUES=$QUEUES"
    "VHOST_SOCKET=$VHOST_SOCKET"
    "HUGEPAGE_MOUNT=${HUGEPAGE_MOUNT:-/dev/hugepages}"
    "CLOUD_INIT_ISO=$CLOUD_INIT_ISO"
    "QEMU_BIN=$QEMU_BIN"
    "MGMT_SSH_PORT=$MGMT_SSH_PORT"
    "MGMT_MAC=${MGMT_MAC:-52:54:00:12:34:57}"
    "ENABLE_MGMT_NET=1"
    "$LAB_DIR/qemu/start_guest_vhost_user.sh"
  )

  if [[ -n "$QEMU_CPUSET" ]] && command -v taskset >/dev/null; then
    cmd=(taskset -c "$QEMU_CPUSET" "${cmd[@]}")
  fi

  if [[ -n "$QEMU_NICE" ]] && command -v nice >/dev/null; then
    cmd=(nice -n "$QEMU_NICE" "${cmd[@]}")
  fi

  exec "${cmd[@]}"
}

wait_for_guest_ssh() {
  local deadline=$((SECONDS + SSH_WAIT_TIMEOUT))
  local ssh_args
  local scp_args
  ssh_args="$(ssh_base_args)"
  scp_args="$(scp_base_args)"

  log_step "Wait for Guest SSH on 127.0.0.1:$MGMT_SSH_PORT"
  while (( SECONDS < deadline )); do
    if eval "ssh $ssh_args ${GUEST_USER}@127.0.0.1 true" >/dev/null 2>&1; then
      echo "Guest SSH is ready."
      return 0
    fi
    sleep 3
  done

  echo "timed out waiting for Guest SSH on 127.0.0.1:$MGMT_SSH_PORT" >&2
  return 1
}

run_guest_automation() {
  local ssh_args
  local scp_args
  local guest_log="$LAB_DIR/generated/guest-testpmd.log"
  local guest_pid
  ssh_args="$(ssh_base_args)"
  scp_args="$(scp_base_args)"

  wait_for_guest_ssh

  log_step "Wait for cloud-init to finish inside Guest"
  if ! eval "ssh $ssh_args ${GUEST_USER}@127.0.0.1 sudo timeout '$CLOUD_INIT_WAIT_TIMEOUT' cloud-init status --wait"; then
    cat >&2 <<EOF
cloud-init did not finish successfully inside the Guest.

Recent Guest diagnostics:
EOF
    eval "ssh $ssh_args ${GUEST_USER}@127.0.0.1 'sudo cloud-init status --long || true; echo; sudo journalctl -u cloud-init -u cloud-config -u cloud-final -n 80 --no-pager || true; echo; free -h || true; echo; grep -E \"HugePages_Total|HugePages_Free|Hugepagesize\" /proc/meminfo || true'" >&2 || true
    return 1
  fi

  log_step "Copy guest scripts into Guest"
  eval "ssh $ssh_args ${GUEST_USER}@127.0.0.1 mkdir -p /home/${GUEST_USER}/guest_dpdk_virtio"
  eval "scp $scp_args -r '$LAB_DIR/guest' ${GUEST_USER}@127.0.0.1:/home/${GUEST_USER}/guest_dpdk_virtio/"

  log_step "Run Guest DPDK smoke test"
  : > "$guest_log"
  eval "ssh $ssh_args ${GUEST_USER}@127.0.0.1 sudo DRIVER=uio_pci_generic AUTO_TESTPMD=1 TRAFFIC_WAIT='$TRAFFIC_WAIT' /home/${GUEST_USER}/guest_dpdk_virtio/guest/run_guest_lab.sh 0000:00:03.0" >"$guest_log" 2>&1 &
  guest_pid="$!"

  if [[ "$SKIP_OVS" != "1" ]]; then
    sleep 4
    log_step "Send Host test traffic into OVS-DPDK"
    BRIDGE="$BRIDGE" TRAFFIC_PORT="$TRAFFIC_PORT" "$LAB_DIR/host/03_setup_test_traffic_port.sh"
    TRAFFIC_PORT="$TRAFFIC_PORT" \
    TRAFFIC_PACKETS="$TRAFFIC_PACKETS" \
    TRAFFIC_INTERVAL="$TRAFFIC_INTERVAL" \
      "$LAB_DIR/host/04_send_test_traffic.py"
  fi

  if ! wait "$guest_pid"; then
    cat "$guest_log" >&2 || true
    return 1
  fi
  cat "$guest_log"
}

wait_for_vhost_socket() {
  local deadline=$((SECONDS + 30))

  while (( SECONDS < deadline )); do
    if [[ -S "$VHOST_SOCKET" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "timed out waiting for vhost-user socket: $VHOST_SOCKET" >&2
  return 1
}

fix_vhost_socket_permissions() {
  wait_for_vhost_socket

  log_step "Allow OVS-DPDK to connect to QEMU vhost-user socket"
  local i
  for i in {1..10}; do
    if [[ -S "$VHOST_SOCKET" ]]; then
      chgrp hugetlbfs "$VHOST_SOCKET" 2>/dev/null || true
      if chmod 777 "$VHOST_SOCKET"; then
        break
      fi
    fi
    sleep 1
  done
  if [[ ! -S "$VHOST_SOCKET" ]]; then
    echo "vhost-user socket disappeared before permissions could be fixed: $VHOST_SOCKET" >&2
    return 1
  fi
  ls -l "$VHOST_SOCKET"

  log_step "Recreate OVS-DPDK vhost-user client port after QEMU socket exists"
  ovs-vsctl --timeout=15 --if-exists del-port "$VHOST_PORT" || true
  ovs-vsctl --timeout=15 --may-exist add-port "$BRIDGE" "$VHOST_PORT" \
    -- set Interface "$VHOST_PORT" type=dpdkvhostuserclient \
       options:vhost-server-path="$VHOST_SOCKET" \
       options:vhost-client-reconnect-interval=1000
}

require_guest_image() {
  if [[ -z "$GUEST_IMAGE" ]]; then
    echo "missing GUEST_IMAGE" >&2
    echo "example: sudo GUEST_IMAGE=/var/lib/libvirt/images/dpdk-guest.qcow2 $0" >&2
    echo "or run: ansible-playbook -i ansible/inventory.ini ansible/guest_image.yml" >&2
    echo "or run: sudo AUTO_PREPARE_GUEST=1 $0" >&2
    echo "expected env file: $ENV_FILE" >&2
    exit 1
  fi
}

require_root
detect_ssh_key
install_host_deps
prepare_guest_image
prepare_fedora_selinux

if [[ -z "$GUEST_IMAGE" && -f "$ENV_FILE" ]]; then
  log_step "Load generated QEMU environment: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if [[ -n "$USER_QEMU_BIN_SET" ]]; then
  QEMU_BIN="$USER_QEMU_BIN_VALUE"
fi

if [[ -n "$USER_MEM_SIZE_SET" ]]; then
  MEM_SIZE="$USER_MEM_SIZE_VALUE"
fi

if [[ -n "$USER_SMP_SET" ]]; then
  SMP="$USER_SMP_VALUE"
fi

if [[ -n "$USER_QEMU_CPUSET_SET" ]]; then
  QEMU_CPUSET="$USER_QEMU_CPUSET_VALUE"
fi

if [[ -z "$USER_MEM_SIZE_SET" && ( "$MEM_SIZE" == "4096M" || "$MEM_SIZE" == "2048M" ) ]]; then
  MEM_SIZE="1024M"
fi

if [[ -z "$USER_SMP_SET" && "$SMP" -gt 2 ]]; then
  SMP="2"
fi

if [[ -z "$SOCKET_MEM" ]]; then
  SOCKET_MEM="$(detect_socket_mem)"
fi

if [[ -z "$USER_QEMU_CPUSET_SET" && -z "$QEMU_CPUSET" ]]; then
  QEMU_CPUSET="$(detect_qemu_cpuset)"
fi

require_guest_image

log_step "Host lab configuration"
cat <<EOF
  lab dir:            $LAB_DIR
  guest image:        $GUEST_IMAGE
  guest image format: $GUEST_IMAGE_FORMAT
  vm name:            $VM_NAME
  memory:             $MEM_SIZE
  vcpus:              $SMP
  virtio queues:      $QUEUES
  vhost socket:       $VHOST_SOCKET
  traffic port:       $TRAFFIC_PORT
  traffic packets:    $TRAFFIC_PACKETS
  traffic wait:       ${TRAFFIC_WAIT}s
  cloud-init ISO:     ${CLOUD_INIT_ISO:-<none>}
  qemu binary:        $QEMU_BIN
  qemu cpuset:        ${QEMU_CPUSET:-<none>}
  qemu nice:          ${QEMU_NICE:-<none>}
  cpu oversubscribe:  $ALLOW_CPU_OVERSUBSCRIBE
  host hugepages 2M:  $HUGEPAGES_2M
  ovs socket memory:  $SOCKET_MEM
  skip OVS setup:     $SKIP_OVS
  auto install deps:  $AUTO_INSTALL_DEPS
  auto run guest:     $AUTO_RUN_GUEST
  cleanup old VM:     $CLEANUP_OLD_VM
  keep VM after run:  $KEEP_VM_AFTER_RUN
  auto rebuild guest: $AUTO_REBUILD_GUEST
  mgmt ssh port:      $MGMT_SSH_PORT
  ssh key:            ${SSH_KEY:-<default ssh agent/root config>}
EOF

if [[ "$CLEANUP_OLD_VM" == "1" ]]; then
  cleanup_lab_qemu "Clean up stale QEMU before starting"
fi

log_step "Step 1/3: prepare host hugepages"
HUGEPAGES_2M="$HUGEPAGES_2M" "$LAB_DIR/host/01_setup_hugepages.sh"

log_step "Step 2/3: configure OVS-DPDK bridge and vhost-user client port"
if [[ "$SKIP_OVS" == "1" ]]; then
  cat <<EOF
SKIP_OVS=1 set: skip Host OVS-DPDK backend setup.

QEMU will still create the vhost-user socket, but no Host backend will connect
unless you start OVS-DPDK/VPP manually.
EOF
else
  SOCKET_MEM="$SOCKET_MEM" \
  VHOST_SOCKET="$VHOST_SOCKET" \
  HUGEPAGE_MOUNT="${HUGEPAGE_MOUNT:-/dev/hugepages}" \
    "$LAB_DIR/host/02_setup_ovs_dpdk_vhost_user.sh"
fi

validate_qemu_resources

log_step "Step 3/3: start QEMU with virtio-net + vhost-user"
cat <<EOF
QEMU will create the vhost-user socket as server:
  $VHOST_SOCKET

After the guest boots, copy or keep this practice directory in the guest and run:
  sudo ./guest/run_guest_lab.sh <virtio-net-pci-address>

Inside the guest, find the PCI address with:
  sudo dpdk-devbind.py -s
EOF

if [[ "$AUTO_RUN_GUEST" == "1" ]]; then
  trap cleanup_auto_run EXIT

  mkdir -p "$(dirname "$QEMU_PIDFILE")"
  : > "$QEMU_LOG"
  start_qemu >"$QEMU_LOG" 2>&1 &

  echo "$!" > "$QEMU_PIDFILE"
  echo "QEMU started in background. pid file: $QEMU_PIDFILE"
  echo "QEMU log: $QEMU_LOG"

  sleep 1
  if ! kill -0 "$(cat "$QEMU_PIDFILE")" 2>/dev/null; then
    echo "QEMU exited during startup. Recent log:" >&2
    tail -n 80 "$QEMU_LOG" >&2 || true
    exit 1
  fi

  fix_vhost_socket_permissions
  run_guest_automation

  if [[ "$KEEP_VM_AFTER_RUN" != "1" ]]; then
    cleanup_lab_qemu "Automated run finished; stop QEMU"
    trap - EXIT
  fi
else
  start_qemu
fi
