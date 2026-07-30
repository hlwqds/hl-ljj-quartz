#!/usr/bin/env bash
set -euo pipefail

make
./simd_demo "$@"
