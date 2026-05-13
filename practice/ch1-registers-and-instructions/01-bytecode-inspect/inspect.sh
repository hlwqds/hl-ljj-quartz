#!/usr/bin/env bash
# 01-bytecode-inspect: eBPF 字节码查看与分析
#
# 对应文档 Section 3.3 - 查看实际字节码
#
# 本脚本展示如何查看编译后的 eBPF 字节码，
# 并标注各类指令（ALU、内存访问、跳转、Helper 调用）

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OBJ_FILE="${SCRIPT_DIR}/simple_prog.bpf.o"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }

# Step 1: 编译
echo "=========================================="
echo "  Step 1: 编译 BPF 程序"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make
echo ""

# Step 2: 反汇编 - 完整字节码
echo "=========================================="
echo "  Step 2: 反汇编字节码 (llvm-objdump)"
echo "=========================================="
warn "以下每条指令都是 64-bit (8 字节)，对应文档中的指令编码格式："
echo "  +----------------+----------------+----------------+----------------+"
echo "  |   imm (32bit)  |   off (16bit)  | src (4) | dst (4) | opcode (8)  |"
echo "  +----------------+----------------+----------------+----------------+"
echo ""
info "完整反汇编输出："
echo "---"
llvm-objdump -d "$OBJ_FILE"
echo "---"
echo ""

# Step 3: 指令分类标注
echo "=========================================="
echo "  Step 3: 指令分类解读"
echo "=========================================="
warn "对照文档 Section 3.2 的指令分类："
echo ""

info "--- ALU 运算指令 (BPF_ALU / BPF_ALU64) ---"
echo "  操作码 class = 01 (64-bit) 或 00 (32-bit)"
echo "  示例: w0 = w1   → 32-bit 移动 (BPF_ALU)"
echo "  示例: r1 += r2  → 64-bit 加法 (BPF_ALU64)"
llvm-objdump -d "$OBJ_FILE" | grep -E '(add|sub|mul|div|lsh|rsh|or|and|xor|neg|arsh|mov)' --color=always || echo "  (使用 -g 编译时 ALU 指令会显示助记符)"
echo ""

info "--- 内存访问指令 (BPF_LDX / BPF_STX / BPF_ST) ---"
echo "  从内存加载到寄存器 (LDX) 或存储到内存 (STX/ST)"
echo "  寻址模式: [base_reg + offset]"
llvm-objdump -d "$OBJ_FILE" | grep -E '(ldx|stx|st)\s' --color=always || echo "  (见完整反汇编中的内存访问指令)"
echo ""

info "--- 条件跳转指令 (BPF_JMP) ---"
echo "  opcode class = 10 (PC 相对跳转)"
echo "  有符号偏移量 (off) 决定跳转目标"
llvm-objdump -d "$OBJ_FILE" | grep -E '(jgt|jge|jeq|jne|jlt|jle|jset|jsgt|jsge|jslt|jsle|ja)' --color=always || echo "  (见完整反汇编中的跳转指令)"
echo ""

info "--- Helper 函数调用 (BPF_CALL) ---"
echo "  opcode class = 11 (末端指令)"
echo "  imm 字段 = Helper 函数编号 (bpf_map_lookup_elem = 1)"
llvm-objdump -d "$OBJ_FILE" | grep -E 'call' --color=always || echo "  (见完整反汇编中的 call 指令)"
echo ""

info "--- 返回指令 (BPF_EXIT) ---"
echo "  程序返回，R0 中存放返回值"
llvm-objdump -d "$OBJ_FILE" | grep -E 'exit|goto' --color=always || echo "  (见完整反汇编中的 exit 指令)"
echo ""

# Step 4: ELF 信息
echo "=========================================="
echo "  Step 4: ELF Section 信息"
echo "=========================================="
info "BPF 程序存储在 ELF 文件的特定 section 中："
llvm-objdump -h "$OBJ_FILE" | grep -E '(Sections|xdp|maps|license)' --color=always
echo ""
warn "关键 section:"
echo "  .text / xdp_bytecode_demo - 程序字节码"
echo "  .maps                       - Map 定义 (BTF 格式)"
echo "  license                     - GPL 许可证标识"
echo ""

# Step 5: BTF 信息（如果存在）
if llvm-objdump -s -j .BTF "$OBJ_FILE" &>/dev/null; then
    echo "=========================================="
    echo "  Step 5: BTF (BPF Type Format) 信息"
    echo "=========================================="
    info "BTF 包含类型信息，让 Verifier 理解内存布局："
    echo ""
    # 用 bpftool 查看 BTF（如果可用）
    if command -v bpftool &>/dev/null; then
        bpftool btf dump file "$OBJ_FILE" 2>/dev/null | head -40 || echo "  (bpftool 无法解析此 BTF)"
    else
        warn "安装 bpftool 可查看详细 BTF 信息"
    fi
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "尝试修改 simple_prog.bpf.c 中的代码，重新编译查看字节码变化"
warn "重点关注: 新增/删除变量、改变运算类型、增加分支时的字节码差异"
