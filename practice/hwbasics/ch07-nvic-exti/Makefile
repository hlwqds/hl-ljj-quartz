# ch07-nvic-exti -- Cortex-M3 中断实验（QEMU mps2-an385）
#
#   make            编译 + 链接（产物在 build/）
#   make run        QEMU 运行（Ctrl-A X 退出）
#   make run-heart  实验一：只跑 SysTick 心跳，5 秒后自动退出
#   make run-rx     实验二：注入两行输入验证 RX 中断 + 环形缓冲
#   make gdb        QEMU 起 gdbserver（-S -s），另终端 gdb 连 :1234
#   make clean      清理

CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

TARGET  := ch07-nvic-exti
BUILD   := build
ELF     := $(BUILD)/$(TARGET).elf

MCUFLAGS := -mcpu=cortex-m3 -mthumb
CFLAGS   := $(MCUFLAGS) -Og -g3 -ffreestanding -fno-common \
            -Wall -Wextra -ffunction-sections -fdata-sections
LDFLAGS  := $(MCUFLAGS) -nostdlib -T mps2_an385.ld \
            -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map

QEMU     ?= qemu-system-arm
QEMUFLAGS := -M mps2-an385 -kernel $(ELF) -display none -serial stdio

SRCS_S := startup.S
SRCS_C := main.c
OBJS   := $(patsubst %.S,$(BUILD)/%.o,$(SRCS_S)) \
          $(patsubst %.c,$(BUILD)/%.o,$(SRCS_C))

.PHONY: all run run-heart run-rx disasm gdb clean

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

# 实验一：不给 stdin 任何输入，纯看 SysTick 心跳（timeout 杀 QEMU 属预期退出）
run-heart: $(ELF)
	timeout 6 $(QEMU) $(QEMUFLAGS) < /dev/null || test $$? -eq 124

# 实验二：启动 2 秒后注入两行文本，验证 RX 中断 + 环形缓冲 + 行回显
run-rx: $(ELF)
	( sleep 2; printf 'nvic alive\r'; sleep 1; printf 'irq driven uart\n'; sleep 2 ) \
	  | timeout 8 $(QEMU) $(QEMUFLAGS) || test $$? -eq 124

disasm: $(ELF)
	$(OBJDUMP) -d $(ELF) | head -60
	@echo '... (完整反汇编见 make disasm | less)'

gdb: $(ELF)
	$(QEMU) $(QEMUFLAGS) -S -s

clean:
	rm -rf $(BUILD)
