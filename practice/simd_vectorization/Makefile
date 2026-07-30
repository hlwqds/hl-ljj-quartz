CC ?= gcc
CFLAGS ?= -O3 -march=native -Wall -Wextra
LDFLAGS ?=

TARGET := simd_demo

.PHONY: all run clean

all: $(TARGET)

$(TARGET): simd_demo.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)
