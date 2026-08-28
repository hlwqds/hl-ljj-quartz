# lwIP 深度解析（五）实验工程：内存池、堆与耗尽实验

对应文章：`content/2026-08-26-lwip-deep-dive-ch5-memory-management.md`

## 内容

基于 ch3 联网模板（openeth + DHCP + TCP echo），固件内含四个阶段的内存实验：

| 阶段    | 实验                                                            | 构建变体 |
| ------- | --------------------------------------------------------------- | -------- |
| PHASE-A | heap_caps 分区记账 + LWIP_STATS 协议统计 + echo 前后堆快照 diff | 默认     |
| PHASE-B | 故障注入：`CONFIG_LWIP_MAX_ACTIVE_TCP=2` 的 PCB 耗尽            | SLIM     |
| PHASE-C | 故障注入：应用侧吃光 libc 堆，观察 RX 失败传播与自愈            | 默认     |
| PHASE-D | 碎片化探针：free vs largest 分叉 / 回填 / 合并                  | 默认     |

## 构建（默认基线，跑 A/C/D）

```bash
. ~/esp/esp-idf/export.sh
idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true      # 生成 qemu_flash.bin/qemu_efuse.bin
```

运行（hostfwd 用 8005 = 8000+章号约定）：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 150 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8005-:8888 -nographic -no-reboot 2>&1 | tee run.log
```

主机侧配合动作按 `run.log` 里的 `[MARKER]` 提示进行（round-1 单次对话 → 持续灌流覆盖
starve 窗口 → WINDOW2 做 round-2 恢复证明），具体命令见文章。

## 实验 B 变体（PCB 耗尽）

取消 `sdkconfig.defaults` 尾部三行注释，然后**删除 `sdkconfig` 重新生成**：

```bash
rm sdkconfig && idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true
```

窗口打开后从主机并发开 6 路连接即可复现"第 3+ 个连接被静默丢弃"。
跑完把注释还原并重建。

## 产物

- `run-a-definitive.log`：基线构建完整一次运行（A/C/D 全阶段）
- `run-b-pcb-exhaust.log`：SLIM 构建的 PCB 耗尽注入
