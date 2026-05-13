CLANG ?= clang
CFLAGS := -O2 -target bpf -g -Wall

.PHONY: all clean

all: helpers_demo.bpf.o

%.bpf.o: %.bpf.c
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o
