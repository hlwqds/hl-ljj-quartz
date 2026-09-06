TARGET  = rcc_uart_read
CROSS   = arm-none-eabi-
CC      = $(CROSS)gcc
CPU     = -mcpu=cortex-m4 -mthumb -mfloat-abi=soft
CFLAGS  = $(CPU) -O2 -Wall -Wextra -ffreestanding -nostdlib
LD      = $(CPU) -nostdlib -T stm32f429.ld -Wl,--gc-sections

$(TARGET).bin: $(TARGET).elf
	$(CROSS)objcopy -O binary $< $@
	$(CROSS)size $<

$(TARGET).elf: startup.S main.c stm32f429.ld
	$(CC) $(CFLAGS) startup.S main.c $(LD) -o $@

flash: $(TARGET).elf
	openocd -f interface/cmsis-dap.cfg -f target/stm32f4x.cfg \
	  -c "adapter speed 2000; program $< verify reset exit"

term:
	minicom -D /dev/ttyUSB0 -b 115200 || picocom -b 115200 /dev/ttyUSB0

clean:
	rm -f $(TARGET).elf $(TARGET).bin
.PHONY: flash term clean
