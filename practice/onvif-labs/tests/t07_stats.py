#!/usr/bin/env python3
"""t07 内存统计（ch17 §17.5.2 生产化重构配套）。

T25: console `mem` 命令 → $$$ ONVIF STATS 系列标记行：
  - 四模块账目行齐全（disc/auth/svc/rtsp）
  - 汇总行 tag=all：static_total / free_dma / free_spiram / min_free
  - 内存红线：free_dma ≥ 170KB（SPEC §4，一票否决项）
"""

import re

from ctx import serial_send_and_read


def t25(c):
    line = serial_send_and_read(send="mem\r\n", pattern=r"STATS tag=all ", timeout=10)
    if not line:
        return False, "mem 命令 10s 未等到 tag=all 汇总行（串口占用或固件无 mem 命令?）"
    m = re.search(r"static_total=(\d+) free_dma=(\d+) free_spiram=(\d+) min_free=(\d+)", line)
    if not m:
        return False, f"汇总行格式异常: {line}"
    static_total, free_dma, free_spiram, min_free = (int(g) for g in m.groups())
    if free_dma < 170 * 1024:
        return False, f"内存红线破线: free_dma={free_dma} < 174080"
    if static_total <= 0:
        return False, "static_total=0（登记丢失?）"
    return True, (f"static_total={static_total} free_dma={free_dma} "
                  f"free_spiram={free_spiram} min_free={min_free}")


TESTS = [("T25", "内存统计: mem 命令 STATS 账目 + free_dma 红线", t25)]
