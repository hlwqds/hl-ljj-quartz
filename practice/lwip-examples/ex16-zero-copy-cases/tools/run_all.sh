#!/usr/bin/env bash
# ex16 全案例归档脚本：按序重建 → 出图 → 运行 → 校验 READY 行
# 用法：tools/run_all.sh [案例号...]   缺省 = 全部六个（一次跑不完就分段传参，
#                                    例如 tools/run_all.sh 0 1 / tools/run_all.sh 2 3）
set -u
cd "$(dirname "$0")/.." || exit 1
. ~/esp/esp-idf/export.sh >/dev/null 2>&1

CASES=${*:-"0 1 2 3 4 5"}
for C in $CASES; do
  echo "== build-case$C =="
  rm -f sdkconfig
  export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.case$C"
  idf.py -B "build-case$C" build >/dev/null 2>&1 || { echo "BUILD FAIL case$C"; exit 1; }
  # 显式出图：monitor 因无 TTY 失败属预期；重复构建后还可能静默不出图
  # （Batch 6 教训），故先跑一次再用 merge-bin 兜底重生成。
  idf.py -B "build-case$C" qemu monitor </dev/null >/dev/null 2>&1 || true
  if [ ! -s "build-case$C/qemu_flash.bin" ] ||
     [ "build-case$C/qemu_flash.bin" -ot "build-case$C/ex16_zero_copy_cases.bin" ]; then
    (cd "build-case$C" && python -m esptool --chip esp32 merge-bin \
      -o qemu_flash.bin --pad-to-size 4MB @flash_args) >/dev/null 2>&1
  fi
  python3 -c "open('build-case$C/qemu_efuse.bin','wb').write(b'\x00'*124)"
  ls "build-case$C/qemu_flash.bin" "build-case$C/qemu_efuse.bin" >/dev/null || {
    echo "IMG FAIL case$C"; exit 1; }
  unset SDKCONFIG_DEFAULTS

  echo "== run case$C =="
  BUILD_DIR="build-case$C" LOG="runs/case$C.log" tools/run_qemu.sh 100 >/dev/null 2>&1

  if ! grep -q '\$\$\$ EXREADY' "runs/case$C.log"; then
    echo "VERIFY FAIL: runs/case$C.log has no EXREADY"
    exit 1
  fi
  grep -m1 '\$\$\$ EXDONE' "runs/case$C.log"
done
echo ALL_DONE
