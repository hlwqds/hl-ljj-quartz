CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump

CFLAGS  := -mcpu=cortex-m3 -mthumb -nostdlib -nostartfiles -Os
LDFLAGS := -T ch03.ld -Wl,--gc-sections -Wl,-Map=build/ch03.map

TARGET  := build/ch03.elf

all: $(TARGET) build/ch03.lst

$(TARGET): startup.s ch03.ld
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) startup.s -o $@

build/ch03.lst: $(TARGET)
	$(OBJDUMP) -d $< > $@

run: $(TARGET)
	qemu-system-arm -M mps2-an385 -nographic -kernel $(TARGET) -S -s

clean:
	rm -rf build

.PHONY: all run clean
