# lwIP 深度解析（十一）实验工程：TCP 状态机观测台

配套文章：`content/2026-08-26-lwip-deep-dive-ch11-tcp-state-machine.md`。

## 组成

| 文件                       | 作用                                                                    |
| -------------------------- | ----------------------------------------------------------------------- |
| `main/state_lab.c`         | ch3 联网模板 + PCB 观测器 + 双模式演示服务器 + 控制通道 + 故障注入 hook |
| `main/ch11_ip4_hook.h`     | 经根 CMakeLists `-include` 注入 lwIP 组件的 hook 宏与原型               |
| `scripts/exp11.py`         | 主机端实验驱动（a/b/c/d 四个阶段）                                      |
| `sdkconfig.defaults`       | 主固件：`CONFIG_LWIP_MAX_ACTIVE_TCP=96`、`CONFIG_LWIP_STATS=y`          |
| `sdkconfig.ch11d.defaults` | 实验 d 叠加层：`CONFIG_LWIP_MAX_ACTIVE_TCP=2`                           |

## 构建

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch11-tcp-state-machine
idf.py set-target esp32
idf.py build                                   # 主固件（实验 a/b/c）
idf.py -B build_d -D SDKCONFIG=sdkconfig.d11 \
  -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.ch11d.defaults" build   # 实验 d 小池变体
```

## 运行

```bash
# 生成 QEMU 镜像（monitor 因无 TTY 报错可忽略）
idf.py qemu monitor < /dev/null || true        # build_d 用 idf.py -B build_d qemu monitor

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
$QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8014-:8814,hostfwd=tcp::9014-:8813 \
  -nographic -no-reboot > logs/exp_xxx.log 2>&1 &

python3 scripts/exp11.py --phase a_passive     # 或 a_active / b / c / d
```

- 演示服务器：`8014 -> guest:8814`
- 控制通道：`9014 -> guest:8813`，命令：`MODE ACTIVE|PASSIVE`、`OBS <ms>`、
  `GW <n> <port>`、`VICTARM`/`VICTFIRE`、`FREEZE ON|OFF`、`STAT`
- kill QEMU 一律按 PID（`ss -ltnp | grep 9014`），禁止 pkill。
