# ch03 实验：向量表与异常栈帧验证（QEMU mps2-an385）

《嵌入式硬件基础（三）：Cortex-M 解剖》的配套裸机工程。约 70 行汇编，无 C 环境、
无库，只为在 QEMU 上验证三件事：

1. 复位时 CPU 从地址 0 取初始 MSP、从地址 4 取 Reset PC（`startup.s` 的 `.isr_vector`）；
2. `svc` 触发异常后，硬件自动把 R0-R3/R12/LR/PC/xPSR 按固定顺序压入 MSP 栈帧；
3. 异常返回（`bx lr`，LR=EXC_RETURN 0xFFFFFFF9）后出栈，MSP 复原、寄存器复原。

## 工具链（本机实测，Fedora 43）

- `arm-none-eabi-gcc` 15.2.0（Fedora 包）
- `qemu-system-arm` 10.1.5（Fedora 包）
- gdb：本机**没有** `arm-none-eabi-gdb` / `gdb-multiarch`，但 Fedora 原生
  `gdb` 17.1 是多目标构建，`set architecture arm` 后可直接连 QEMU 的 ARM gdbstub，
  本工程全部会话用它完成。

## 复现步骤

```bash
make                       # 编译 build/ch03.elf + 反汇编 build/ch03.lst
qemu-system-arm -M mps2-an385 -nographic -kernel build/ch03.elf -S -s &   # 另一个终端
gdb -q build/ch03.elf
(gdb) set architecture arm
(gdb) target remote localhost:1234
```

`-s` 是 `-gdb tcp::1234` 的简写；若 1234 被占（本仓库多章实验并行时常见），换
`-gdb tcp::1235` 并 `target remote localhost:1235`。注意 gdb 的 `detach` 会放行
QEMU 继续执行；想保持暂停用 `disconnect`，或每轮实验重启带 `-S` 的 QEMU。

继续会话：

```
(gdb) info registers pc sp          # sp = 0x20400000 = 向量表 word0
(gdb) x/16wx 0x0                    # 向量表前 16 项
(gdb) break SVC_Handler
(gdb) continue                      # 停在 handler 入口
(gdb) info registers sp lr          # lr = 0xfffffff9 (EXC_RETURN)
(gdb) x/8wx $sp                     # 栈帧：R0,R1,R2,R3,R12,LR,PC,xPSR
(gdb) break after_svc
(gdb) continue                      # 异常返回后
(gdb) info registers sp r0 r1 r2 r3 r12   # MSP 复原、魔数回寄存器
```

内存映射（QEMU `-M mps2-an385`，Cortex-M3）：0x00000000 4MB SRAM 当"Flash"用，
0x20000000 4MB SRAM 做栈。`build/` 已被仓库 `.gitignore`（`practice/*/build*/`）排除。
