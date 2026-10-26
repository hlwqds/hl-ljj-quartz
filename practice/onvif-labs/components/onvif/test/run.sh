#!/usr/bin/env bash
# 宿主单元测试：onvif_digest（RFC 2617 向量 + 解析/组合/重放/注入面）。
# 用法：./run.sh   （需要 gcc；不依赖 IDF）
set -euo pipefail
cd "$(dirname "$0")"
gcc -Wall -Wextra -I stub -I ../include -o /tmp/test_digest \
    test_digest.c ../src/onvif_digest.c
/tmp/test_digest
