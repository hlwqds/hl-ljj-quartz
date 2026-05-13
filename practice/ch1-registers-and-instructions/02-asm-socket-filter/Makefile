CLANG ?= clang
LLVM_OBJDUMP ?= llvm-objdump

# Socket filter 不需要 libbpf，使用内核头文件即可
CFLAGS := -O2 -target bpf -g -Wall \
          -I/usr/include

.PHONY: all clean inspect

all: asm_filter.o

asm_filter.o: asm_filter.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o

inspect: asm_filter.o
	$(LLVM_OBJDUMP) -d $<
