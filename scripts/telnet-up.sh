#!/bin/bash
# telnet-up.sh — 一键准备 + 启动 + 验证 telnet
#
# 用法：
#   ./scripts/telnet-up.sh              # 复用已有编译产物，组装镜像+验证
#   ./scripts/telnet-up.sh --full       # 从零编译（内核/busybox/dropbear）+ 验证
#
# 内部调用：
#   1. setup-arm-env.sh (--skip-build)  准备 initramfs（含 telnetd + dropbear）
#   2. verify-telnet.sh                 启动 qemu + expect telnet 验证
#
# 退出码：0=成功，非0=失败（原样传递）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="$REPO_DIR/lab"

# 子脚本（setup/verify）各自有 trap EXIT 清理 qemu，wrapper 不重复清理
# 避免误杀用户其他 qemu 或 PID 复用杀错进程

# 参数校验：无参=复用产物(--skip-build)，--full=从零编译，其余报错
SKIP_FLAG="--skip-build"
case "${1:-}" in
    "")        SKIP_FLAG="--skip-build" ;;
    --full)    SKIP_FLAG="" ;;
    -h|--help) echo "用法: $0 [--full]"; echo "  无参    复用已有编译产物，组装镜像+验证"; echo "  --full  从零编译内核/busybox/dropbear+验证"; exit 0 ;;
    *)         echo "未知参数: $1"; echo "用法: $0 [--full]"; exit 2 ;;
esac

echo "=== [1/2] 准备 initramfs ==="
cd "$LAB_DIR"
set +e
bash "$SCRIPT_DIR/setup-arm-env.sh" $SKIP_FLAG
setup_rc=$?
set -e

if [ "$setup_rc" -ne 0 ]; then
    echo "setup 失败 (rc=$setup_rc)"
    exit "$setup_rc"
fi

# setup 子脚本 EXIT trap 已清理 qemu，无需额外处理

echo
echo "=== [2/2] 验证 telnet ==="
cd "$LAB_DIR"
set +e
bash "$SCRIPT_DIR/verify-telnet.sh"
telnet_rc=$?
set -e


echo
if [ "$telnet_rc" -eq 0 ]; then
    echo "✅ telnet 一键验证通过"
else
    echo "❌ telnet 验证失败 (rc=$telnet_rc)"
fi
exit "$telnet_rc"
