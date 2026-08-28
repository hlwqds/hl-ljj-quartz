#!/usr/bin/env bash
# ex15 全场景归档脚本：按序重建 → 出图 → 运行 → 校验 FACT 行
# 用法：tools/run_all.sh [场景号...]   缺省 = 0 1 2 3 4
set -u
cd "$(dirname "$0")/.." || exit 1
. ~/esp/esp-idf/export.sh >/dev/null 2>&1

SCS=${*:-"0 1 2 3 4"}
for SC in $SCS; do
  echo "== build-sc$SC =="
  rm -f sdkconfig
  export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.sc$SC"
  idf.py -B "build-sc$SC" build >/dev/null 2>&1 || { echo "BUILD FAIL sc$SC"; exit 1; }
  # 显式带同一份配置出图（monitor 因无 TTY 失败属预期，镜像已生成）
  idf.py -B "build-sc$SC" qemu monitor < /dev/null >/dev/null 2>&1 || true
  ls "build-sc$SC/qemu_flash.bin" "build-sc$SC/qemu_efuse.bin" >/dev/null || { echo "IMG FAIL sc$SC"; exit 1; }
  unset SDKCONFIG_DEFAULTS

  echo "== run sc$SC =="
  BUILD_DIR="build-sc$SC" LOG="runs/sc$SC.log" tools/run_qemu.sh 110 >/dev/null 2>&1

  if ! grep -q "\$\$\$ EXREADY sc=$SC(" "runs/sc$SC.log"; then
    echo "VERIFY FAIL: runs/sc$SC.log has no EXREADY sc=$SC"
    exit 1
  fi
  grep -m1 "\$\$\$ EXDONE" "runs/sc$SC.log"
done
echo ALL_DONE
