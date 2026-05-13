CLANG ?= clang
CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean

all: bpf_call_demo.bpf.o stack_overflow.bpf.o stack_overflow_nopriv.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o
