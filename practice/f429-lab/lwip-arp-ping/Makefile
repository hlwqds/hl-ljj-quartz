TARGET = lwip_arp_ping
CROSS  = arm-none-eabi-
CC     = $(CROSS)gcc
CPU    = -mcpu=cortex-m4 -mthumb -mfloat-abi=soft
CFLAGS = $(CPU) -O2 -std=gnu11 -Wall -Wno-unused-parameter -ffreestanding
INC    = -Ilwip-src/include -Iport
LD     = $(CPU) -nostdlib -T stm32f429.ld -Wl,--gc-sections -lgcc

# lwIP 2.2.0（vendor 裁剪版）：只编 ARP+ICMP+raw+IPv4 闭包；
# TCP/UDP/DNS 等源文件未 vendor，ch22 打流实验再补。
LWIP_SRC = \
	lwip-src/core/def.c \
	lwip-src/core/inet_chksum.c \
	lwip-src/core/init.c \
	lwip-src/core/ip.c \
	lwip-src/core/mem.c \
	lwip-src/core/memp.c \
	lwip-src/core/netif.c \
	lwip-src/core/pbuf.c \
	lwip-src/core/raw.c \
	lwip-src/core/stats.c \
	lwip-src/core/sys.c \
	lwip-src/core/timeouts.c \
	lwip-src/core/udp.c \
	lwip-src/core/ipv4/acd.c \
	lwip-src/core/ipv4/autoip.c \
	lwip-src/core/ipv4/dhcp.c \
	lwip-src/core/ipv4/etharp.c \
	lwip-src/core/ipv4/icmp.c \
	lwip-src/core/ipv4/igmp.c \
	lwip-src/core/ipv4/ip4_addr.c \
	lwip-src/core/ipv4/ip4.c \
	lwip-src/core/ipv4/ip4_frag.c \
	lwip-src/netif/ethernet.c

APP_SRC = startup.S main.c ethernetif.c port/support.c

$(TARGET).bin: $(TARGET).elf
	$(CROSS)objcopy -O binary $< $@
	$(CROSS)size $<

$(TARGET).elf: $(APP_SRC) $(LWIP_SRC) stm32f429.ld port/lwipopts.h port/arch/cc.h port/arch/sys_arch.h
	$(CC) $(CFLAGS) $(INC) $(APP_SRC) $(LWIP_SRC) $(LD) -o $@

flash: $(TARGET).elf
	openocd -f interface/cmsis-dap.cfg -f target/stm32f4x.cfg \
	  -c "adapter speed 2000; program $< verify reset exit"

term:
	minicom -D /dev/ttyUSB0 -b 115200 || picocom -b 115200 /dev/ttyUSB0

clean:
	rm -f $(TARGET).elf $(TARGET).bin
.PHONY: flash term clean
