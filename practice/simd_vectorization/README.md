# SIMD Vectorization Practice

This practice demonstrates scalar vs AVX2 SIMD processing for a simple
`uint32_t` array addition:

```text
dst[i] = a[i] + b[i]
```

The AVX2 path processes 8 `uint32_t` elements per vector instruction:

```text
256-bit register / 32-bit element = 8 lanes
```

Build and run:

```bash
make
./simd_demo
```

Optional arguments:

```bash
./simd_demo <elements> <iterations>
```

Example:

```bash
./simd_demo 16777216 10
```

If the compiler target does not enable AVX2, the program still builds and only
runs the scalar path. The default Makefile uses `-march=native`, so AVX2 will be
enabled automatically on most modern x86 hosts that support it.
