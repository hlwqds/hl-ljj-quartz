# ch05-gpio-clock -- GPIO 与时钟树（双目标：F407 编译验证 + QEMU 实跑）
#
#   make            构建两个目标并打印 size
#   make run        QEMU 运行（串口接终端，Ctrl-A X 退出）
#   make run-log    QEMU 批量取证：4s 超时，串口 + guest_errors/unimp 日志落盘 build/run.log
#   make disasm     F407 目标反汇编摘录（文章编译证据）
#   make clean      清理
#
# 目标一 ch05-gpio-qemu：-mcpu=cortex-m3，mps2-an385 内存映射，可在 QEMU 实跑
# 目标二 ch05-gpio-f407：-mcpu=cortex-m4，STM32F407 真机内存映射（f407.ld），
#                        编译验证目标（QEMU 无 F407 机型，不运行）

CROSS   ?= arm-none-eabi-
CC       := $(CROSS)gcc
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size

BUILD    := build
QEMU_TGT := ch05-gpio-qemu
F407_TGT := ch05-gpio-f407

QEMU_MCU := -mcpu=cortex-m3 -mthumb
F407_MCU := -mcpu=cortex-m4 -mthumb

CFLAGS   := -Og -g3 -ffreestanding -fno-common -Wall -Wextra \
            -ffunction-sections -fdata-sections
LDFLAGS  := -nostdlib -Wl,--gc-sections

QEMU     ?= qemu-system-arm
QEMUFLAGS := -M mps2-an385 -kernel $(BUILD)/$(QEMU_TGT).elf

.PHONY: all run run-log disasm clean

all: $(BUILD)/$(QEMU_TGT).elf $(BUILD)/$(F407_TGT).elf
	$(SIZE) $(BUILD)/$(QEMU_TGT).elf $(BUILD)/$(F407_TGT).elf

$(BUILD):
	mkdir -p $(BUILD)

# ---- QEMU 目标（Cortex-M3，可直接跑） ----
$(BUILD)/startup_qemu.o: startup.S | $(BUILD)
	$(CC) $(QEMU_MCU) $(CFLAGS) -c -o $@ $<

$(BUILD)/qemu_main.o: qemu_main.c | $(BUILD)
	$(CC) $(QEMU_MCU) $(CFLAGS) -c -o $@ $<

$(BUILD)/$(QEMU_TGT).elf: $(BUILD)/startup_qemu.o $(BUILD)/qemu_main.o mps2_an385.ld
	$(CC) $(QEMU_MCU) $(LDFLAGS) -T mps2_an385.ld \
	  -Wl,-Map=$(BUILD)/$(QEMU_TGT).map -o $@ $(BUILD)/startup_qemu.o $(BUILD)/qemu_main.o

# ---- F407 目标（Cortex-M4，编译验证） ----
$(BUILD)/startup_f407.o: startup.S | $(BUILD)
	$(CC) $(F407_MCU) $(CFLAGS) -c -o $@ $<

$(BUILD)/f407_gpio.o: f407_gpio.c | $(BUILD)
	$(CC) $(F407_MCU) $(CFLAGS) -c -o $@ $<

$(BUILD)/$(F407_TGT).elf: $(BUILD)/startup_f407.o $(BUILD)/f407_gpio.o f407.ld
	$(CC) $(F407_MCU) $(LDFLAGS) -T f407.ld \
	  -Wl,-Map=$(BUILD)/$(F407_TGT).map -o $@ $(BUILD)/startup_f407.o $(BUILD)/f407_gpio.o

run: $(BUILD)/$(QEMU_TGT).elf
	$(QEMU) $(QEMUFLAGS) -nographic

run-log: $(BUILD)/$(QEMU_TGT).elf
	timeout 4 $(QEMU) $(QEMUFLAGS) -display none -serial stdio \
	  -d guest_errors,unimp > $(BUILD)/run.log 2>&1 || true
	cat $(BUILD)/run.log

disasm: $(BUILD)/$(F407_TGT).elf
	$(OBJDUMP) -d $< | sed -n '/<led_init>:/,/^$$/p; /<led_on>:/,/^$$/p'

clean:
	rm -rf $(BUILD)
