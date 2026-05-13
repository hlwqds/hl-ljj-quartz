#!/usr/bin/env bash
# 04-kfuncs: kfuncs 与弱链接 + 不存在的 kfunc 实验
#
# 对应文档 Section 5
#
# 三个实验:
#   kfunc_demo.bpf.o            → 正常 kfunc 调用 (bpf_obj_new_impl)
#   kfunc_unsupported.bpf.o     → 非 __weak 调用不存在的 kfunc (加载失败)
#   kfunc_unsupported_weak.bpf.o → __weak 调用不存在的 kfunc (加载成功)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 编译
echo "=========================================="
echo "  Step 1: 编译"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make
echo ""

# Step 2: 字节码分析
echo "=========================================="
echo "  Step 2: kfunc 字节码分析"
echo "=========================================="

section "kfunc_demo: 正常 kfunc 调用"
warn "call -0x1 = kfunc 占位符，加载时 libbpf 通过 BTF ID 替换"
echo ""
llvm-objdump -d kfunc_demo.bpf.o | grep -E 'call|<kfunc' | head -10
echo ""

section "kfunc_unsupported: 不存在的 kfunc (非 weak)"
warn "字节码看起来和正常 kfunc 完全一样 — 都是 call -0x1"
warn "区别在加载阶段: libbpf 查 BTF 找不到符号 → 报错"
echo ""
llvm-objdump -d kfunc_unsupported.bpf.o | grep -E 'call|<kfunc' | head -10
echo ""

section "kfunc_unsupported_weak: 不存在的 kfunc (__weak)"
warn "多了一条 if r1 == 0x0 (bpf_ksym_exists 检查)"
warn "如果 kfunc 不存在 → 跳过调用，直接 return"
echo ""
llvm-objdump -d kfunc_unsupported_weak.bpf.o | grep -E 'call|if r1|<kfunc' | head -10
echo ""

# Step 3: 加载测试
echo "=========================================="
echo "  Step 3: 加载测试 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装"
    exit 0
fi

warn "清理残留 pin 文件..."
sudo rm -f /sys/fs/bpf/kfunc_demo /sys/fs/bpf/kfunc_test /sys/fs/bpf/kfunc_weak_test 2>/dev/null

# Case 1: 正常 kfunc
section "Case 1: 正常 kfunc (bpf_obj_new_impl)"
sudo rm -f /sys/fs/bpf/kfunc_demo 2>/dev/null
verify_log=$(mktemp)
bpftool prog load kfunc_demo.bpf.o /sys/fs/bpf/kfunc_demo \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — kfunc 在当前内核可用"
    sudo rm -f /sys/fs/bpf/kfunc_demo 2>/dev/null
else
    warn "加载失败 — 当前内核不支持 bpf_obj_new_impl"
fi

# Case 2: 不存在的 kfunc，非 __weak (强引用)
unset ret || true
section "Case 2: 不存在的 kfunc (非 __weak，强引用)"
warn "bpf_do_something_magical: 随便编的名字，内核里不存在"
warn "预期: libbpf 报 'not found in kernel or module BTFs'"
echo ""
sudo rm -f /sys/fs/bpf/kfunc_test 2>/dev/null
verify_log=$(mktemp)
bpftool prog load kfunc_unsupported.bpf.o /sys/fs/bpf/kfunc_test \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -E 'not found|Error|invalid|pin' "$verify_log" || tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外)"
    sudo rm -f /sys/fs/bpf/kfunc_test 2>/dev/null
else
    info "加载失败 ✓ — libbpf 在加载时找不到 kfunc 符号"
    warn "这是 __weak 的价值: 没有 __weak 时，缺少 kfunc = 完全无法加载"
fi
# Case 2 失败时可能残留 pin，强制清理
sudo rm -f /sys/fs/bpf/kfunc_test 2>/dev/null

# Case 3: 不存在的 kfunc，__weak (弱引用)
unset ret || true
section "Case 3: 不存在的 kfunc (__weak，弱引用)"
warn "bpf_do_something_magical_weak: 同样不存在，但标记了 __weak __ksym"
warn "预期: 加载成功，运行时 bpf_ksym_exists 返回 false → 跳过调用"
echo ""
sudo rm -f /sys/fs/bpf/kfunc_weak_test 2>/dev/null
verify_log=$(mktemp)
bpftool prog load kfunc_unsupported_weak.bpf.o /sys/fs/bpf/kfunc_weak_test \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -E 'not found|Error|invalid|pin' "$verify_log" || tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — __weak 允许缺失 kfunc，程序正常加载"

    section "xlated 字节码: 不存在的 kfunc 被裁掉了"
    warn "对比原始 .o: 有 call -0x1 + if 分支"
    warn "加载后 xlated: 只有 r1=0, w0=0, exit — kfunc 调用路径被 dead code elimination"
    echo ""
    sudo bpftool prog dump xlated pinned /sys/fs/bpf/kfunc_weak_test 2>&1
    echo ""

    section "Case 2 对比: 非 __weak 无法加载，没有 xlated 可看"
    warn "这就是 __weak 的核心价值:"
    warn "  - 非 __weak: libbpf 直接报错，程序根本进不了内核"
    warn "  - __weak:    libbpf 裁掉不存在的 kfunc 路径，程序正常加载运行"

    sudo rm -f /sys/fs/bpf/kfunc_weak_test 2>/dev/null
else
    warn "加载失败 (意外: __weak 应该允许缺失 kfunc)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
echo ""
warn "关键结论:"
warn "  1. 编译阶段: 无论 __weak 与否，都能编译通过 (编译器不检查 kfunc 是否存在)"
warn "  2. 加载阶段:"
warn "     - 非 __weak: libbpf 查 BTF 找不到符号 → 加载失败"
warn "     - __weak:    libbpf 跳过找不到的 kfunc → 加载成功"
warn "  3. 运行阶段:"
warn "     - bpf_ksym_exists() 检查 kfunc 是否存在"
warn "     - 如果不存在 → 程序走 fallback 逻辑"
warn "  4. 这就是为什么生产代码中 kfunc 总是标记 __weak __ksym"
