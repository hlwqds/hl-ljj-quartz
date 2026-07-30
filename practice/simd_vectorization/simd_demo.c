#define _POSIX_C_SOURCE 200112L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__AVX2__)
#include <immintrin.h>
#endif

#define DEFAULT_ELEMENTS (16u * 1024u * 1024u)
#define DEFAULT_ITERS 10u
#define ALIGNMENT 32u

static double
now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void *
xaligned_alloc(size_t alignment, size_t size)
{
    void *ptr = NULL;
    if (posix_memalign(&ptr, alignment, size) != 0) {
        fprintf(stderr, "posix_memalign failed: alignment=%zu size=%zu\n",
                alignment, size);
        exit(1);
    }
    return ptr;
}

static void
init_arrays(uint32_t *a, uint32_t *b, size_t n)
{
    uint32_t seed = 0x12345678u;

    for (size_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        a[i] = seed;
        seed = seed * 1664525u + 1013904223u;
        b[i] = seed;
    }
}

#if defined(__GNUC__) && !defined(__clang__)
__attribute__((noinline, optimize("no-tree-vectorize")))
#else
__attribute__((noinline))
#endif
static void
add_scalar(uint32_t *dst, const uint32_t *a, const uint32_t *b, size_t n)
{
    for (size_t i = 0; i < n; i++)
        dst[i] = a[i] + b[i];
}

#if defined(__AVX2__)
__attribute__((noinline))
static void
add_avx2(uint32_t *dst, const uint32_t *a, const uint32_t *b, size_t n)
{
    size_t i = 0;

    for (; i + 8 <= n; i += 8) {
        __m256i va = _mm256_load_si256((const __m256i *)(const void *)&a[i]);
        __m256i vb = _mm256_load_si256((const __m256i *)(const void *)&b[i]);
        __m256i vc = _mm256_add_epi32(va, vb);

        _mm256_store_si256((__m256i *)(void *)&dst[i], vc);
    }

    for (; i < n; i++)
        dst[i] = a[i] + b[i];
}
#endif

static uint64_t
checksum_u32(const uint32_t *data, size_t n)
{
    uint64_t sum = 0;

    for (size_t i = 0; i < n; i++)
        sum += data[i];

    return sum;
}

static double
bench_add(const char *name,
          void (*fn)(uint32_t *, const uint32_t *, const uint32_t *, size_t),
          uint32_t *dst, const uint32_t *a, const uint32_t *b,
          size_t n, unsigned int iterations)
{
    double start;
    double end;

    memset(dst, 0, n * sizeof(*dst));

    start = now_sec();
    for (unsigned int iter = 0; iter < iterations; iter++)
        fn(dst, a, b, n);
    end = now_sec();

    double seconds = end - start;
    double bytes = (double)n * sizeof(uint32_t) * 3.0 * iterations;
    double gib_per_sec = bytes / seconds / (1024.0 * 1024.0 * 1024.0);

    printf("%-8s time: %.6f sec, bandwidth: %.2f GiB/s, checksum: %llu\n",
           name, seconds, gib_per_sec,
           (unsigned long long)checksum_u32(dst, n));

    return seconds;
}

int
main(int argc, char **argv)
{
    size_t n = DEFAULT_ELEMENTS;
    unsigned int iterations = DEFAULT_ITERS;

    if (argc >= 2)
        n = strtoull(argv[1], NULL, 10);
    if (argc >= 3)
        iterations = (unsigned int)strtoul(argv[2], NULL, 10);

    size_t bytes = n * sizeof(uint32_t);
    uint32_t *a = xaligned_alloc(ALIGNMENT, bytes);
    uint32_t *b = xaligned_alloc(ALIGNMENT, bytes);
    uint32_t *scalar = xaligned_alloc(ALIGNMENT, bytes);
    uint32_t *vector = xaligned_alloc(ALIGNMENT, bytes);

    init_arrays(a, b, n);

    printf("elements: %zu, iterations: %u\n", n, iterations);
    printf("array bytes: %.2f MiB each\n", (double)bytes / 1024.0 / 1024.0);

    double scalar_sec = bench_add("scalar", add_scalar, scalar, a, b,
                                  n, iterations);

#if defined(__AVX2__)
    double avx2_sec = bench_add("avx2", add_avx2, vector, a, b,
                                n, iterations);

    if (memcmp(scalar, vector, bytes) != 0) {
        fprintf(stderr, "verification failed: scalar and avx2 differ\n");
        free(a);
        free(b);
        free(scalar);
        free(vector);
        return 1;
    }

    printf("speedup: %.2fx\n", scalar_sec / avx2_sec);
#else
    printf("avx2    skipped: compiler target does not define __AVX2__\n");
#endif

    free(a);
    free(b);
    free(scalar);
    free(vector);

    return 0;
}
