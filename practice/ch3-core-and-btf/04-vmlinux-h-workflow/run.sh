#!/usr/bin/env bash
# 04-vmlinux-h-workflow: 完整的 CO-RE 开发工作流
#
# 对应文档 Section 5 (vmlinux.h 的生成与使用)
#
# 本脚本展示生产级 CO-RE BPF 程序的完整开发流程:
#   1. 首次编译 → Makefile 自动生成 vmlinux.h
#   2. 编译 BPF 程序 (include vmlinux.h + BPF_CORE_READ)
#   3. 查看编译产物中的 BTF 和 CO-RE 信息
#   4. 加载程序 (libbpf 自动执行 CO-RE 重定位)
#   5. 查看 CO-RE 重定位结果
#
# 工作流:
#   开发者: #include "vmlinux.h" → 用 BPF_CORE_READ 读字段
#   clang:   -g → 生成 CO-RE 重定位记录 (嵌入 .bpf.o)
#   libbpf:  读取 /sys/kernel/btf/vmlinux → 修正偏移量 → 加载

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 编译 (含 vmlinux.h 自动生成)
echo "=========================================="
echo "  Step 1: 编译 (含 vmlinux.h 自动生成)"
echo "=========================================="
cd "$SCRIPT_DIR"

# 删除 vmlinux.h 以演示自动生成
rm -f vmlinux.h

make clean 2>/dev/null || true
echo ""
warn "vmlinux.h 已删除，首次编译将自动生成..."
echo ""

make 2>&1
echo ""

if [[ ! -f core_workflow.bpf.o ]]; then
    warn "编译失败"
    exit 1
fi

if [[ -f vmlinux.h ]]; then
    LINES=$(wc -l < vmlinux.h)
    SIZE=$(du -h vmlinux.h | cut -f1)
    info "vmlinux.h 自动生成: ${LINES} 行, ${SIZE}"
fi

info "编译成功 ✓"

# Step 2: 查看编译产物
section "Step 2: 编译产物分析"
echo ""

info "BPF 对象文件:"
ls -lh core_workflow.bpf.o
echo ""

if command -v bpftool &>/dev/null; then
    info "BPF 程序列表:"
    bpftool prog show file core_workflow.bpf.o 2>/dev/null || true
    echo ""

    info "Map 列表:"
    bpftool map show file core_workflow.bpf.o 2>/dev/null || true
    echo ""

    section "CO-RE 重定位记录"
    warn "每条记录 = 一个需要 libbpf 在加载时修正的偏移量"
    echo ""

    # 查看 .BTF 和 CO-RE 重定位
    bpftool btf dump file core_workflow.bpf.o 2>/dev/null | head -20
    echo ""
    warn "CO-RE 字段重定位:"
    bpftool btf dump file core_workflow.bpf.o 2>/dev/null \
        | grep -i "field\|relo" | head -10 || echo "  (bpftool 不支持直接查看重定位)"
fi

# Step 3: 加载
echo "=========================================="
echo "  Step 3: 加载 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装，跳过"
    exit 0
fi

sudo rm -f /sys/fs/bpf/core_workflow 2>/dev/null
verify_log=$(mktemp)
bpftool prog load core_workflow.bpf.o /sys/fs/bpf/core_workflow \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""

if [[ $ret -ne 0 ]]; then
    warn "加载失败，跳过"
    exit 0
fi

info "加载成功 ✓"
warn "libbpf 已自动执行 CO-RE 重定位:"
warn "  读取 /sys/kernel/btf/vmlinux"
warn "  对比重定位记录与目标 BTF"
warn "  修正字节码中的偏移量"
echo ""

# Step 4: 查看加载后的程序
section "Step 4: 已加载程序信息"
echo ""

PROG_ID=$(bpftool prog show name on_tcp_state_change 2>/dev/null | grep -oP 'id \K[0-9]+' | head -1)
if [[ -n "$PROG_ID" ]]; then
    info "程序 ID: $PROG_ID"
    bpftool prog show id "$PROG_ID" 2>/dev/null
    echo ""

    info "JIT 编译后的字节码 (前 15 行):"
    bpftool prog dump xlated id "$PROG_ID" 2>/dev/null | head -15
else
    warn "无法获取程序 ID"
fi

echo ""

# Step 5: 重新编译 (vmlinux.h 已存在)
section "Step 5: 增量编译 (vmlinux.h 已缓存)"
warn "第二次编译不再重新生成 vmlinux.h"
warn "生产环境: vmlinux.h 通常提交到版本控制"
echo ""

make clean 2>/dev/null || true
START=$(date +%s%N)
make 2>&1
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
echo ""
info "编译耗时: ${ELAPSED}ms"

# 清理
sudo rm -f /sys/fs/bpf/core_workflow 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. Makefile 自动生成 vmlinux.h (仅首次)"
warn "  2. vmlinux.h 包含所有内核类型的 C 定义"
warn "  3. BPF_CORE_READ 告诉 clang 生成 CO-RE 重定位记录"
warn "  4. libbpf 加载时自动对比目标 BTF，修正偏移量"
warn "  5. 运行时零额外开销 — CO-RE 修正只发生在加载阶段"
warn "  6. 生产环境: 将 vmlinux.h 提交到版本控制，内核升级后重新生成"
