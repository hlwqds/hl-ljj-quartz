# ch06-uart-framing -- UART 成帧协议状态机（QEMU mps2-an385）
#
# 基于 ch04-baremetal-template：启动链（startup.S/mps2_an385.ld）原样复用。
#
#   make            编译 + 链接（产物在 build/）
#   make run        QEMU 交互运行：键盘输入直接进 UART0 RX（Ctrl-A X 退出）
#   make test       生成注入流 -> QEMU 回环 -> 打印运行日志（自动化实证）
#   make disasm     反汇编摘录
#   make clean      清理

CROSS   ?= arm-none-eabi-
CC       := $(CROSS)gcc
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size

TARGET   := ch06-uart-framing
BUILD    := build
ELF      := $(BUILD)/$(TARGET).elf

MCUFLAGS := -mcpu=cortex-m3 -mthumb
CFLAGS   := $(MCUFLAGS) -Og -g3 -ffreestanding -fno-common \
            -Wall -Wextra -ffunction-sections -fdata-sections
# -lgcc：main.c 的 uart_putdec 用到除法，需要 libgcc 的 __aeabi_uidiv
LDFLAGS  := $(MCUFLAGS) -nostdlib -lgcc -T mps2_an385.ld \
            -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map

QEMU     ?= qemu-system-arm

SRCS_S   := startup.S
SRCS_C   := main.c
OBJS     := $(patsubst %.S,$(BUILD)/%.o,$(SRCS_S)) \
            $(patsubst %.c,$(BUILD)/%.o,$(SRCS_C))

.PHONY: all run test disasm clean

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

# 交互版：-nographic 把 UART0 接到终端，键盘输入即 UART RX
run: $(ELF)
	$(QEMU) -M mps2-an385 -kernel $(ELF) -nographic

# 自动化实证：gen_input.py 生成注入流（好帧 + 五类坏帧/噪声），
# 重定向进 QEMU stdin（-serial stdio -> UART0 RX），日志落 build/run.log。
# timeout 到期杀 QEMU（程序收完字节后自旋等待）属预期，故前缀 '-'
test: $(ELF)
	python3 gen_input.py > $(BUILD)/in.bin
	-timeout 5 $(QEMU) -M mps2-an385 -kernel $(ELF) \
	  -display none -serial stdio < $(BUILD)/in.bin > $(BUILD)/run.log 2>&1
	@echo '---- build/run.log ----'
	@cat $(BUILD)/run.log

disasm: $(ELF)
	$(OBJDUMP) -d $(ELF) | head -60
	@echo '... (完整反汇编见 make disasm | less)'

clean:
	rm -rf $(BUILD)
