CLANG ?= clang
LLVM_OBJDUMP ?= llvm-objdump

CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean inspect

all: percpu_vstack.bpf.o stack_overflow_fail.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o

inspect: all
	$(LLVM_OBJDUMP) -d percpu_vstack.bpf.o
