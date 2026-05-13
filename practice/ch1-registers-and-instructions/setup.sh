#!/usr/bin/env bash
# eBPF Chapter 1 实践环境安装脚本
# 支持 Debian/Ubuntu 和 Fedora/RHEL
set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

detect_pkg_manager() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        error "Unsupported package manager. Please install dependencies manually."
        exit 1
    fi
}

install_deps() {
    local pkg_mgr="$1"
    case "$pkg_mgr" in
        dnf)
            info "Detected Fedora/RHEL, using dnf..."
            sudo dnf install -y \
                clang \
                llvm \
                libbpf-devel \
                bpftool \
                make \
                linux-devel \
                elfutils-libelf-devel \
                zlib-devel
            ;;
        apt)
            info "Detected Debian/Ubuntu, using apt..."
            sudo apt-get update
            sudo apt-get install -y \
                clang \
                llvm \
                libbpf-dev \
                linux-headers-$(uname -r) \
                linux-tools-common \
                linux-tools-$(uname -r) \
                make \
                libelf-dev \
                zlib1g-dev
            # bpftool 通常包含在 linux-tools 中
            ;;
        pacman)
            info "Detected Arch Linux, using pacman..."
            sudo pacman -S --noconfirm \
                clang \
                llvm \
                libbpf \
                bpftool \
                make \
                linux-headers \
                libelf \
                zlib
            ;;
    esac
}

verify_install() {
    local failed=0

    echo ""
    info "Verifying installation..."

    for cmd in clang llvm-objdump bpftool make; do
        if command -v "$cmd" &>/dev/null; then
            local version
            version=$("$cmd" --version 2>/dev/null | head -1)
            info "  $cmd: $version"
        else
            error "  $cmd: NOT FOUND"
            failed=1
        fi
    done

    # Check BPF target support
    if clang --print-targets 2>/dev/null | grep -q bpf; then
        info "  clang BPF target: supported"
    else
        warn "  clang BPF target: not found (may need reinstall clang)"
        failed=1
    fi

    # Check kernel BPF support
    if [[ -f /proc/sys/kernel/unprivileged_bpf_disabled ]]; then
        local val
        val=$(cat /proc/sys/kernel/unprivileged_bpf_disabled)
        if [[ "$val" == "1" ]]; then
            warn "  kernel BPF: restricted to root only (unprivileged_bpf_disabled=1)"
        else
            info "  kernel BPF: available for all users"
        fi
    fi

    # Check BTF support
    if [[ -f /sys/kernel/btf/vmlinux ]]; then
        info "  kernel BTF: /sys/kernel/btf/vmlinux exists"
    else
        warn "  kernel BTF: not found (CO-RE features may not work)"
    fi

    echo ""
    if [[ $failed -eq 0 ]]; then
        info "All dependencies installed successfully!"
    else
        error "Some dependencies are missing. Please check the errors above."
        return 1
    fi
}

main() {
    echo "=========================================="
    echo "  eBPF Chapter 1 - Environment Setup"
    echo "=========================================="
    echo ""

    if [[ "${1:-}" == "--verify" ]]; then
        verify_install
        return
    fi

    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)

    info "Package manager: $pkg_mgr"
    echo ""

    if [[ "${1:-}" == "--check" ]]; then
        verify_install
        return
    fi

    install_deps "$pkg_mgr"
    verify_install

    echo ""
    info "You can now run the practice examples:"
    echo "  cd 01-bytecode-inspect && make && bash inspect.sh"
    echo "  cd 02-asm-socket-filter && make && bash test.sh"
    echo "  cd 03-bounded-loops && make && bash verify.sh"
    echo "  cd 04-stack-workaround && make"
    echo "  cd 05-jit-debug && make && sudo bash jit_inspect.sh"
}

main "$@"
