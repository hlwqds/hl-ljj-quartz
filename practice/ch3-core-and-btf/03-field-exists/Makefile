CLANG ?= clang
CFLAGS := -O2 -target bpf -g -Wall

VMLINUX_H := vmlinux.h

.PHONY: all clean

all: hardcoded_offset_bad.bpf.o core_read_good.bpf.o

$(VMLINUX_H):
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX_H)

%.bpf.o: %.bpf.c $(VMLINUX_H)
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o vmlinux.h
