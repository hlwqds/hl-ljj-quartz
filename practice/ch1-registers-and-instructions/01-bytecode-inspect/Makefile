CLANG ?= clang
LLVM_OBJDUMP ?= llvm-objdump

# -target bpf: 编译为 BPF 字节码
# -O2: 优化（生成更紧凑的字节码）
# -g: 生成调试信息（BTF，便于阅读）
CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean inspect

all: simple_prog.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o

# 快速查看字节码
inspect: simple_prog.bpf.o
	$(LLVM_OBJDUMP) -d $<
