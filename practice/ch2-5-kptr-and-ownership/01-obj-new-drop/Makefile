CLANG ?= clang
CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean

all: basic_alloc.bpf.o leak_fail.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o
