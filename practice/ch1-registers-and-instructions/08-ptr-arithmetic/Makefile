CLANG ?= clang
CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean

all: var_offset_bad.bpf.o var_offset_good.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o
