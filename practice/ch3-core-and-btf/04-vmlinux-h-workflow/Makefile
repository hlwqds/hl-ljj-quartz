CLANG ?= clang
BPFTOOL ?= bpftool
CFLAGS := -O2 -target bpf -g -Wall

# vmlinux.h: CO-RE 的核心依赖
# 首次 make 时自动从 /sys/kernel/btf/vmlinux 生成
# 后续只在手动删除后才重新生成 (避免每次编译都读取 6MB BTF)
VMLINUX_H := vmlinux.h

.PHONY: all clean regenerate-vmlinux-h

all: core_workflow.bpf.o

# 生成 vmlinux.h (仅在文件不存在时触发)
$(VMLINUX_H):
	@echo "[GEN] Generating $(VMLINUX_H) from /sys/kernel/btf/vmlinux..."
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX_H)
	@echo "[GEN] Done. $(shell wc -l < $(VMLINUX_H)) lines generated."

# 编译 BPF 程序
%.bpf.o: %.bpf.c $(VMLINUX_H)
	$(CLANG) $(CFLAGS) -c $< -o $@

# 强制重新生成 vmlinux.h (内核升级后使用)
regenerate-vmlinux-h:
	rm -f $(VMLINUX_H)
	$(MAKE) all

clean:
	rm -f *.o
