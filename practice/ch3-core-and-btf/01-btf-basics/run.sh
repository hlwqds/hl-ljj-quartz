#!/usr/bin/env bash
# 01-btf-basics: BTF 基础探索
#
# 对应文档 Section 2 (BTF 深度解析)
#
# 本脚本展示 BTF 的核心特征:
#   1. 查看 /sys/kernel/btf/vmlinux 大小
#   2. 列出 BTF 中的结构体类型
#   3. 查看 task_struct 字段布局
#   4. 生成 vmlinux.h (CO-RE 头文件)
#   5. 对比 BTF vs DWARF 体积
#
# 本练习不需要 root 权限，不需要编译 BPF 程序

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 查看 BTF 文件
section "Step 1: 查看 /sys/kernel/btf/vmlinux"
warn "BTF 是内核内置的类型描述文件，2-10 MB"
echo ""

if [[ -f /sys/kernel/btf/vmlinux ]]; then
    ls -lh /sys/kernel/btf/vmlinux
    BTF_SIZE=$(stat -c%s /sys/kernel/btf/vmlinux)
    BTF_MB=$((BTF_SIZE / 1024 / 1024))
    info "BTF 文件大小: ${BTF_MB} MB"
    info "对比: 同内核的 DWARF 调试信息通常 200-500 MB"
    info "BTF 体积约为 DWARF 的 $(( 100 * BTF_SIZE / 300000000 ))%"
else
    warn "/sys/kernel/btf/vmlinux 不存在"
    warn "当前内核 ($(uname -r)) 可能未启用 BTF"
    warn "需要内核编译选项 CONFIG_DEBUG_INFO_BTF=y"
    exit 0
fi

# Step 2: 列出 BTF 中的结构体
section "Step 2: BTF 中的结构体类型"
warn "BTF 使用紧凑的二进制编码记录所有内核类型"
echo ""

if command -v bpftool &>/dev/null; then
    STRUCT_COUNT=$(bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null | grep -c 'STRUCT\|UNION\|ENUM' || echo "0")
    info "STRUCT + UNION + ENUM 总数: ${STRUCT_COUNT}"

    echo ""
    warn "部分知名结构体:"
    echo ""
    for type in task_struct sock sk_buff mm_struct; do
        if bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null | grep -q "STRUCT '${type}'"; then
            info "  ✓ ${type}"
        else
            warn "  ✗ ${type} (未找到)"
        fi
    done
else
    warn "bpftool 未安装，跳过"
fi

# Step 3: 查看 task_struct 布局
section "Step 3: task_struct 字段布局"
warn "BTF 记录了每个字段的名称、类型、偏移量"
warn "这是 CO-RE 重定位的基础 — libbpf 据此修正偏移量"
echo ""

if command -v bpftool &>/dev/null; then
    # 找到 task_struct 并展示前 20 个字段
    bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null \
        | grep -A 30 "STRUCT 'task_struct'" | head -30
    echo ""
    warn "关键字段:"
    for field in comm pid tgid real_parent; do
        OFFSET=$(bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null \
            | grep -A 200 "STRUCT 'task_struct'" | grep "'${field}'" | head -1 | grep -oP 'offset=\K[0-9]+' || echo "?")
        info "  ${field}: offset=${OFFSET}"
    done
fi

# Step 4: 生成 vmlinux.h
section "Step 4: 生成 vmlinux.h"
warn "vmlinux.h 是 CO-RE 编程的核心依赖"
warn "包含所有内核类型的 C 定义，供 BPF 程序 #include"
echo ""

if command -v bpftool &>/dev/null; then
    info "开始生成 vmlinux.h (可能需要几秒)..."
    bpftool btf dump file /sys/kernel/btf/vmlinux format c > "$SCRIPT_DIR/vmlinux.h" 2>/dev/null
    if [[ -f "$SCRIPT_DIR/vmlinux.h" ]]; then
        LINES=$(wc -l < "$SCRIPT_DIR/vmlinux.h")
        SIZE=$(du -h "$SCRIPT_DIR/vmlinux.h" | cut -f1)
        info "vmlinux.h 生成成功: ${LINES} 行, ${SIZE}"

        echo ""
        warn "vmlinux.h 中的 task_struct 定义:"
        grep -A 5 'struct task_struct {' "$SCRIPT_DIR/vmlinux.h" | head -6
        echo "  ..."
        # 找 comm 字段
        grep -n "comm\[" "$SCRIPT_DIR/vmlinux.h" | head -3 | while read -r line; do
            echo "  $line"
        done

        echo ""
        warn "vmlinux.h 中的 preserve_access_index 属性:"
        grep "preserve_access_index" "$SCRIPT_DIR/vmlinux.h" | head -1
        warn "这只是 convenience attribute — 让该 struct 所有字段自动生成 CO-RE 重定位"
        warn "CO-RE 的真正关键是 __builtin_preserve_access_index() (BPF_CORE_READ 内部调用)"
    else
        warn "生成失败"
    fi
else
    warn "bpftool 未安装，跳过"
fi

# Step 5: BTF 编码原理
section "Step 5: BTF 编码原理"
warn "BTF 使用类型 ID 引用避免重复"
warn "例如: 所有 int 字段共享同一个 type ID"
echo ""

if command -v bpftool &>/dev/null; then
    echo "BTF 头部信息:"
    bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null | head -10
    echo ""

    TYPE_COUNT=$(bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null | wc -l)
    info "BTF dump 总行数: ${TYPE_COUNT}"
    info "每个类型有唯一 type_id (递增整数)，CO-RE 重定位记录通过 type_id + field_name 定位字段"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. BTF 是内核内置的紧凑类型描述 (2-10 MB vs DWARF 200-500 MB)"
warn "  2. BTF 记录结构体字段的名称、类型、偏移量"
warn "  3. vmlinux.h 由 BTF 自动生成，是 CO-RE 编程的基础"
warn "  4. CO-RE 的真正关键: __builtin_preserve_access_index() + libbpf 重定位"
warn "  5. libbpf 加载时对比 BTF 重定位记录与目标内核 BTF，修正偏移量"
