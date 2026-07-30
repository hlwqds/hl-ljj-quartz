#define _GNU_SOURCE

#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

#define CACHE_LINE 64
#define RING_SIZE 1024
#define RING_MASK (RING_SIZE - 1)

#define PRODUCERS 2
#define OPS_PER_PRODUCER 5000000
#define TOTAL_OPS ((uint64_t)PRODUCERS * OPS_PER_PRODUCER)

#define RTS_PUBLISH_INTERVAL 32
#define RTS_PUBLISH_BUDGET 64

struct stats {
    atomic_ulong cas_retry;
    atomic_ulong tail_spin;
    atomic_ulong publish_cas;
    atomic_ulong publish_slots;
};

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}

static void print_result(const char *name, double sec, struct stats *s) {
    printf("%-10s time: %.3f sec, throughput: %.2f Mops/sec",
           name, sec, (double)TOTAL_OPS / sec / 1000000.0);

    printf(", cas_retry: %lu, tail_spin: %lu, publish_cas: %lu, publish_slots: %lu\n",
           atomic_load(&s->cas_retry),
           atomic_load(&s->tail_spin),
           atomic_load(&s->publish_cas),
           atomic_load(&s->publish_slots));
}

/*
 * ============================================================
 * MT ring: CAS prod_head + strict prod_tail sync
 * ============================================================
 */

struct mt_ring {
    uint64_t data[RING_SIZE];

    _Alignas(CACHE_LINE) atomic_uint prod_head;
    _Alignas(CACHE_LINE) atomic_uint prod_tail;

    _Alignas(CACHE_LINE) atomic_uint cons_head;
    _Alignas(CACHE_LINE) atomic_uint cons_tail;

    _Alignas(CACHE_LINE) struct stats stats;
};

static struct mt_ring mt;

static void mt_init(void) {
    atomic_store(&mt.prod_head, 0);
    atomic_store(&mt.prod_tail, 0);
    atomic_store(&mt.cons_head, 0);
    atomic_store(&mt.cons_tail, 0);

    atomic_store(&mt.stats.cas_retry, 0);
    atomic_store(&mt.stats.tail_spin, 0);
    atomic_store(&mt.stats.publish_cas, 0);
    atomic_store(&mt.stats.publish_slots, 0);
}

static void mt_enqueue(uint64_t value) {
    uint32_t old_head;
    uint32_t new_head;

    for (;;) {
        old_head = atomic_load_explicit(&mt.prod_head, memory_order_relaxed);
        uint32_t cons_tail = atomic_load_explicit(&mt.cons_tail, memory_order_acquire);

        if ((old_head - cons_tail) == RING_SIZE) {
            continue;
        }

        new_head = old_head + 1;

        if (atomic_compare_exchange_weak_explicit(
                &mt.prod_head,
                &old_head,
                new_head,
                memory_order_acquire,
                memory_order_relaxed)) {
            break;
        }

        atomic_fetch_add(&mt.stats.cas_retry, 1);
    }

    mt.data[old_head & RING_MASK] = value;

    while (atomic_load_explicit(&mt.prod_tail, memory_order_acquire) != old_head) {
        atomic_fetch_add(&mt.stats.tail_spin, 1);
    }

    atomic_store_explicit(&mt.prod_tail, new_head, memory_order_release);
    atomic_fetch_add(&mt.stats.publish_slots, 1);
}

static int mt_dequeue(uint64_t *out) {
    uint32_t old_head;
    uint32_t new_head;

    for (;;) {
        old_head = atomic_load_explicit(&mt.cons_head, memory_order_relaxed);
        uint32_t prod_tail = atomic_load_explicit(&mt.prod_tail, memory_order_acquire);

        if (old_head == prod_tail) {
            return 0;
        }

        new_head = old_head + 1;

        if (atomic_compare_exchange_weak_explicit(
                &mt.cons_head,
                &old_head,
                new_head,
                memory_order_acquire,
                memory_order_relaxed)) {
            break;
        }

        atomic_fetch_add(&mt.stats.cas_retry, 1);
    }

    *out = mt.data[old_head & RING_MASK];

    while (atomic_load_explicit(&mt.cons_tail, memory_order_acquire) != old_head) {
        atomic_fetch_add(&mt.stats.tail_spin, 1);
    }

    atomic_store_explicit(&mt.cons_tail, new_head, memory_order_release);

    return 1;
}

static void *mt_producer(void *arg) {
    uint64_t id = (uint64_t)(uintptr_t)arg;

    for (uint64_t i = 0; i < OPS_PER_PRODUCER; i++) {
        mt_enqueue((id << 48) | i);
    }

    return NULL;
}

static void *mt_consumer(void *arg) {
    (void)arg;

    uint64_t cnt = 0;
    uint64_t v;

    while (cnt < TOTAL_OPS) {
        if (mt_dequeue(&v)) {
            cnt++;
        }
    }

    return NULL;
}

static void bench_mt(void) {
    pthread_t p[PRODUCERS];
    pthread_t c;

    mt_init();

    double start = now_sec();

    pthread_create(&c, NULL, mt_consumer, NULL);

    for (uint64_t i = 0; i < PRODUCERS; i++) {
        pthread_create(&p[i], NULL, mt_producer, (void *)(uintptr_t)i);
    }

    for (int i = 0; i < PRODUCERS; i++) {
        pthread_join(p[i], NULL);
    }

    pthread_join(c, NULL);

    double end = now_sec();

    print_result("MT", end - start, &mt.stats);
}

/*
 * ============================================================
 * RTS-like real ring
 *
 * 核心：
 * 1. producer CAS 抢 prod_head
 * 2. producer 写 slot
 * 3. producer 标记 slot ready
 * 4. 不是每次都 publish
 * 5. publish 时扫描连续 ready slot
 * 6. 一次 CAS 把 prod_tail 推进多个位置
 * ============================================================
 */

struct rts_slot {
    uint64_t data;
    atomic_uint ready_seq;
};

struct rts_ring {
    struct rts_slot slots[RING_SIZE];

    _Alignas(CACHE_LINE) atomic_uint prod_head;
    _Alignas(CACHE_LINE) atomic_uint prod_tail;

    _Alignas(CACHE_LINE) atomic_uint cons_head;
    _Alignas(CACHE_LINE) atomic_uint cons_tail;

    _Alignas(CACHE_LINE) struct stats stats;
};

static struct rts_ring rts;

static void rts_init(void) {
    atomic_store(&rts.prod_head, 0);
    atomic_store(&rts.prod_tail, 0);
    atomic_store(&rts.cons_head, 0);
    atomic_store(&rts.cons_tail, 0);

    atomic_store(&rts.stats.cas_retry, 0);
    atomic_store(&rts.stats.tail_spin, 0);
    atomic_store(&rts.stats.publish_cas, 0);
    atomic_store(&rts.stats.publish_slots, 0);

    for (int i = 0; i < RING_SIZE; i++) {
        rts.slots[i].data = 0;
        atomic_store(&rts.slots[i].ready_seq, 0);
    }
}

static void rts_try_publish(void) {
    for (;;) {
        uint32_t tail = atomic_load_explicit(&rts.prod_tail, memory_order_acquire);
        uint32_t scan = tail;

        for (int n = 0; n < RTS_PUBLISH_BUDGET; n++) {
            struct rts_slot *s = &rts.slots[scan & RING_MASK];

            uint32_t ready = atomic_load_explicit(&s->ready_seq, memory_order_acquire);

            if (ready != scan + 1) {
                break;
            }

            scan++;
        }

        if (scan == tail) {
            return;
        }

        uint32_t expected = tail;

        if (atomic_compare_exchange_weak_explicit(
                &rts.prod_tail,
                &expected,
                scan,
                memory_order_release,
                memory_order_relaxed)) {
            atomic_fetch_add(&rts.stats.publish_cas, 1);
            atomic_fetch_add(&rts.stats.publish_slots, scan - tail);
            return;
        }

        atomic_fetch_add(&rts.stats.cas_retry, 1);
    }
}

static void rts_enqueue(uint64_t value) {
    uint32_t old_head;
    uint32_t new_head;

    for (;;) {
        old_head = atomic_load_explicit(&rts.prod_head, memory_order_relaxed);
        uint32_t cons_tail = atomic_load_explicit(&rts.cons_tail, memory_order_acquire);

        if ((old_head - cons_tail) == RING_SIZE) {
            rts_try_publish();
            continue;
        }

        new_head = old_head + 1;

        if (atomic_compare_exchange_weak_explicit(
                &rts.prod_head,
                &old_head,
                new_head,
                memory_order_acquire,
                memory_order_relaxed)) {
            break;
        }

        atomic_fetch_add(&rts.stats.cas_retry, 1);
    }

    struct rts_slot *s = &rts.slots[old_head & RING_MASK];

    s->data = value;

    atomic_store_explicit(&s->ready_seq, old_head + 1, memory_order_release);

    /*
     * 关键：不要每次都 publish。
     */
    if ((old_head & (RTS_PUBLISH_INTERVAL - 1)) == (RTS_PUBLISH_INTERVAL - 1)) {
        rts_try_publish();
    }
}

static int rts_dequeue(uint64_t *out) {
    uint32_t old_head;
    uint32_t new_head;

    for (;;) {
        old_head = atomic_load_explicit(&rts.cons_head, memory_order_relaxed);
        uint32_t prod_tail = atomic_load_explicit(&rts.prod_tail, memory_order_acquire);

        if (old_head == prod_tail) {
            return 0;
        }

        new_head = old_head + 1;

        if (atomic_compare_exchange_weak_explicit(
                &rts.cons_head,
                &old_head,
                new_head,
                memory_order_acquire,
                memory_order_relaxed)) {
            break;
        }

        atomic_fetch_add(&rts.stats.cas_retry, 1);
    }

    struct rts_slot *s = &rts.slots[old_head & RING_MASK];

    *out = s->data;

    while (atomic_load_explicit(&rts.cons_tail, memory_order_acquire) != old_head) {
        atomic_fetch_add(&rts.stats.tail_spin, 1);
    }

    atomic_store_explicit(&rts.cons_tail, new_head, memory_order_release);

    return 1;
}

static void *rts_producer(void *arg) {
    uint64_t id = (uint64_t)(uintptr_t)arg;

    for (uint64_t i = 0; i < OPS_PER_PRODUCER; i++) {
        rts_enqueue((id << 48) | i);
    }

    /*
     * 退出前补一次，避免最后一批 ready slot 没被 publish。
     */
    rts_try_publish();

    return NULL;
}

static void *rts_consumer(void *arg) {
    (void)arg;

    uint64_t cnt = 0;
    uint64_t v;

    while (cnt < TOTAL_OPS) {
        if (rts_dequeue(&v)) {
            cnt++;
        } else {
            /*
             * consumer 发现 prod_tail 没推进时，也帮忙 publish。
             * 这点很重要，否则 producer 不频繁 publish 时，consumer 可能空转。
             */
            rts_try_publish();
        }
    }

    return NULL;
}

static void bench_rts(void) {
    pthread_t p[PRODUCERS];
    pthread_t c;

    rts_init();

    double start = now_sec();

    pthread_create(&c, NULL, rts_consumer, NULL);

    for (uint64_t i = 0; i < PRODUCERS; i++) {
        pthread_create(&p[i], NULL, rts_producer, (void *)(uintptr_t)i);
    }

    for (int i = 0; i < PRODUCERS; i++) {
        pthread_join(p[i], NULL);
    }

    pthread_join(c, NULL);

    double end = now_sec();

    print_result("RTS-real", end - start, &rts.stats);
}

int main(void) {
    printf("producers: %d\n", PRODUCERS);
    printf("ops per producer: %d\n", OPS_PER_PRODUCER);
    printf("total ops: %lu\n", (unsigned long)TOTAL_OPS);
    printf("ring size: %d\n", RING_SIZE);
    printf("RTS publish interval: %d\n", RTS_PUBLISH_INTERVAL);
    printf("RTS publish budget: %d\n\n", RTS_PUBLISH_BUDGET);

    bench_mt();
    bench_rts();

    return 0;
}
