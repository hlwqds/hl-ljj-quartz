CLANG ?= clang
LLVM_OBJDUMP ?= llvm-objdump

CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean

all: jit_demo.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o
