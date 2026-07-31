# Makefile — 编译 LED 内核模块（out-of-tree）
#
# 用法：
#   make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C ../linux-6.19 M=$(pwd) modules
#
# 产物：led_module.ko（ARM 内核模块）

obj-m += led_module.o

# 指向内核源码树（必须与客户机内核同源编译）
KDIR ?= ../linux-6.19

all:
	$(MAKE) ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C $(KDIR) M=$(CURDIR) clean
