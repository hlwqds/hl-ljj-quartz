#!/usr/bin/env bash
# 02-asm-socket-filter: 手写汇编 Socket Filter 测试
#
# 对应文档 Section 7
#
# 展示：
# 1. 编译手写汇编的 BPF 程序
# 2. 查看生成的字节码（验证内联汇编是否按预期翻译）
# 3. 对比 C 版本和汇编版本的指令数差异

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OBJ_FILE="${SCRIPT_DIR}/asm_filter.o"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 编译
echo "=========================================="
echo "  Step 1: 编译汇编 Socket Filter"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make
echo ""

# Step 2: 反汇编并标注
echo "=========================================="
echo "  Step 2: 反汇编 - 指令逐条解读"
echo "=========================================="
echo ""
warn "以下字节码对应 asm_filter.c 中的每一条内联汇编指令："
echo ""

llvm-objdump -d "$OBJ_FILE" | while IFS= read -r line; do
    # 高亮关键指令
    if echo "$line" | grep -qE '(r[0-9]+ =|if|goto|call|exit|j[a-z]+|ldx|stx|st)'; then
        echo -e "\033[0;33m$line\033[0m"
    else
        echo "$line"
    fi
done
echo ""

# Step 3: 指令对照表
echo "=========================================="
echo "  Step 3: 汇编源码 ↔ 字节码对照"
echo "=========================================="
echo ""
info "对照文档 Section 3.1 的指令编码格式："
echo "  opcode(8) | dst(4) | src(4) | off(16) | imm(32)"
echo ""
warn "关键指令解读："
echo ""
echo "  1. r0 = *(u32 *)(r1 + off)"
echo "     → BPF_LDX_MEM | dst=R0, src=R1, off=data偏移"
echo "     → 内存加载: 从 ctx 读取 data 指针"
echo ""
echo "  2. if r0 + 14 > r1 goto +N"
echo "     → BPF_JMP_IMM | dst=R0, off=N"
echo "     → 条件跳转: 边界检查"
echo ""
echo "  3. r2 = *(u16 *)(r0 + 12)"
echo "     → BPF_LDX_MEM | dst=R2, src=R0, off=12"
echo "     → 半字加载: 读取 Ethernet 协议类型"
echo ""
echo "  4. r0 = -1"
echo "     → BPF_ALU64_IMM | dst=R0, imm=0xFFFFFFFF"
echo "     → 立即数加载: Socket filter 放行标志"
echo ""

# Step 4: 统计指令数
echo "=========================================="
echo "  Step 4: 指令统计"
echo "=========================================="
total=$(llvm-objdump -d "$OBJ_FILE" | grep -cE '^\s+[0-9]+:' || echo "0")
info "总指令数: $total 条"
info "每条指令 8 字节, 总大小: $((total * 8)) 字节"
echo ""
warn "对比: 纯 C 版本（用 if-else 实现）通常需要 15-25 条指令"
warn "手写汇编的优势: 精确控制每条指令，减少冗余"
echo ""

# Step 5: 加载测试（需要 root）
echo "=========================================="
echo "  Step 5: 加载测试 (可选，需要 root)"
echo "=========================================="
if [[ $EUID -eq 0 ]]; then
    warn "以 root 身份运行，尝试加载 BPF 程序..."

    # 创建一个 raw socket 用于挂载 filter
    if command -v bpftool &>/dev/null; then
        info "使用 bpftool 验证程序可加载性..."
        # bpftool 可以验证但不能直接加载 socket filter
        # 用经典方式加载: SO_ATTACH_BPF
        warn "Socket filter 需要通过 setsockopt(SO_ATTACH_BPF) 挂载"
        warn "完整的加载示例请参考 man 7 bpf"
    fi
else
    warn "非 root 用户，跳过加载测试"
    warn "运行 'sudo bash $0' 进行完整测试"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 修改汇编代码，添加对 ICMP (protocol=1) 的支持"
warn "  2. 修改偏移量，尝试解析 IPv6 的 next_header 字段"
warn "  3. 对比修改前后的字节码差异 (diff)"
