# ch08-timers -- 定时器实验（QEMU mps2-an385）
#
#   make            编译 + 链接（产物在 build/）
#   make run        QEMU 运行（Ctrl-A X 退出；实验全程约 8 秒）
#   make disasm     反汇编摘录（向量表 + 处理函数）
#   make gdb        QEMU 起 gdbserver 等待远程调试
#   make capture    批量运行并捕获输出到 build/run.log
#   make clean      清理

CROSS   ?= arm-none-eabi-
CC       := $(CROSS)gcc
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size

TARGET   := ch08-timers
BUILD    := build
ELF      := $(BUILD)/$(TARGET).elf

MCUFLAGS := -mcpu=cortex-m3 -mthumb
CFLAGS   := $(MCUFLAGS) -Og -g3 -ffreestanding -fno-common \
            -Wall -Wextra -ffunction-sections -fdata-sections
LDFLAGS  := $(MCUFLAGS) -nostdlib -T mps2_an385.ld \
            -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map

QEMU     ?= qemu-system-arm
QEMUFLAGS := -M mps2-an385 -kernel $(ELF) -nographic

SRCS_S   := startup.S
SRCS_C   := main.c
OBJS     := $(patsubst %.S,$(BUILD)/%.o,$(SRCS_S)) \
            $(patsubst %.c,$(BUILD)/%.o,$(SRCS_C))

.PHONY: all run disasm gdb capture clean

all: $(ELF)
	$(SIZE) $(ELF)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: %.S | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(ELF): $(OBJS) mps2_an385.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

run: $(ELF)
	$(QEMU) $(QEMUFLAGS)

disasm: $(ELF)
	$(OBJDUMP) -d $(ELF) | head -60

gdb: $(ELF)
	$(QEMU) $(QEMUFLAGS) -S -s

capture: $(ELF)
	timeout 15 $(QEMU) $(QEMUFLAGS) | tee $(BUILD)/run.log
	@echo '(timeout 杀掉 QEMU 属预期——程序打印完 summary 后静默 wfi)'

clean:
	rm -rf $(BUILD)
