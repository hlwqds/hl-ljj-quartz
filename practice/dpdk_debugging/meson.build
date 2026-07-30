# build.sh — 编译 buggy/fixed_l2fwd 演示程序
#
# 前置: 已安装 DPDK 24.x, RTE_SDK 环境变量指向 DPDK 根目录
#
# 用法:
#   export RTE_SDK=/path/to/dpdk
#   ./build.sh
#
# 编译结果在 build/ 目录

#!/bin/bash
set -e

: ${RTE_SDK:?"Need RTE_SDK env var, e.g. export RTE_SDK=/opt/dpdk"}

RTE_TARGET=x86_64-native-linux-gcc

echo "=== DPDK Build Script ==="
echo "RTE_SDK=$RTE_SDK"
echo "RTE_TARGET=$RTE_TARGET"
echo ""

cd "$(dirname "$0")"
mkdir -p build

# 编译 buggy 版本
echo "--- Compiling buggy_l2fwd ---"
gcc -O0 -g -Wall \
    -I$RTE_SDK/lib/eal/include \
    -I$RTE_SDK/lib/eal/linux/include \
    -I$RTE_SDK/lib/mempool/include \
    -I$RTE_SDK/lib/mbuf/include \
    -I$RTE_SDK/lib/ethdev/include \
    -I$RTE_SDK/lib/net/include \
    -I$RTE_SDK/lib/ring/include \
    -I$RTE_SDK/lib/lcore/include \
    -I$RTE_SDK/lib/kvargs/include \
    -include $RTE_SDK/config/rte_config.h \
    -DALLOW_EXPERIMENTAL_API \
    buggy_l2fwd.c \
    -L$RTE_SDK/lib -L$RTE_SDK/drivers \
    -lrte_eal -lrte_mempool -lrte_mbuf -lrte_ethdev -lrte_net \
    -lrte_ring -lrte_kvargs -lpthread -lm -ldl \
    -o build/buggy_l2fwd 2>&1 | tail -20

# 编译 fixed 版本
echo ""
echo "--- Compiling fixed_l2fwd ---"
gcc -O2 -g -Wall \
    -I$RTE_SDK/lib/eal/include \
    -I$RTE_SDK/lib/eal/linux/include \
    -I$RTE_SDK/lib/mempool/include \
    -I$RTE_SDK/lib/mbuf/include \
    -I$RTE_SDK/lib/ethdev/include \
    -I$RTE_SDK/lib/net/include \
    -I$RTE_SDK/lib/ring/include \
    -I$RTE_SDK/lib/lcore/include \
    -I$RTE_SDK/lib/kvargs/include \
    -include $RTE_SDK/config/rte_config.h \
    -DALLOW_EXPERIMENTAL_API \
    fixed_l2fwd.c \
    -L$RTE_SDK/lib -L$RTE_SDK/drivers \
    -lrte_eal -lrte_mempool -lrte_mbuf -lrte_ethdev -lrte_net \
    -lrte_ring -lrte_kvargs -lpthread -lm -ldl \
    -o build/fixed_l2fwd 2>&1 | tail -20

echo ""
echo "=== Build complete ==="
ls -lh build/
