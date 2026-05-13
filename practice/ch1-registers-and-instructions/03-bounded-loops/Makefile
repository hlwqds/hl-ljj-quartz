CLANG ?= clang
LLVM_OBJDUMP ?= llvm-objdump

CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean inspect

all: valid_loop.bpf.o invalid_loop.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o

inspect: all
	@echo "=== Valid Loop (bounded) ==="
	$(LLVM_OBJDUMP) -d valid_loop.bpf.o
	@echo ""
	@echo "=== Invalid Loop (unbounded) ==="
	$(LLVM_OBJDUMP) -d invalid_loop.bpf.o
