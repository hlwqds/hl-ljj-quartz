use std::hint::spin_loop;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const PRODUCERS: usize = 4;
const CONSUMERS: usize = 4;
const ITERS: u64 = 20_000_000;
const RING_SIZE: u64 = 1024;

struct BadRing {
    prod_head: AtomicU64,
    prod_tail: AtomicU64,
    cons_head: AtomicU64,
    cons_tail: AtomicU64,
}

#[repr(align(64))]
struct ProducerState {
    head: AtomicU64,
    tail: AtomicU64,
}

#[repr(align(64))]
struct ConsumerState {
    head: AtomicU64,
    tail: AtomicU64,
}

struct GoodRing {
    prod: ProducerState,
    cons: ConsumerState,
}

fn run_bad() {
    let ring = Arc::new(BadRing {
        prod_head: AtomicU64::new(0),
        prod_tail: AtomicU64::new(0),
        cons_head: AtomicU64::new(0),
        cons_tail: AtomicU64::new(0),
    });

    let start = Instant::now();
    let mut handles = vec![];

    for _ in 0..PRODUCERS {
        let r = ring.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..ITERS {
                loop {
                    let head = r.prod_head.load(Ordering::Relaxed);
                    let tail = r.cons_tail.load(Ordering::Acquire);

                    if head - tail >= RING_SIZE {
                        spin_loop();
                        continue;
                    }

                    if r.prod_head
                        .compare_exchange_weak(head, head + 1, Ordering::Acquire, Ordering::Relaxed)
                        .is_ok()
                    {
                        while r.prod_tail.load(Ordering::Acquire) != head {
                            spin_loop();
                        }

                        r.prod_tail.store(head + 1, Ordering::Release);
                        break;
                    }
                }
            }
        }));
    }

    for _ in 0..CONSUMERS {
        let r = ring.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..ITERS {
                loop {
                    let head = r.cons_head.load(Ordering::Relaxed);
                    let tail = r.prod_tail.load(Ordering::Acquire);

                    if tail <= head {
                        spin_loop();
                        continue;
                    }

                    if r.cons_head
                        .compare_exchange_weak(head, head + 1, Ordering::Acquire, Ordering::Relaxed)
                        .is_ok()
                    {
                        while r.cons_tail.load(Ordering::Acquire) != head {
                            spin_loop();
                        }

                        r.cons_tail.store(head + 1, Ordering::Release);
                        break;
                    }
                }
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    println!("bad ring:  {:?}", start.elapsed());
}

fn run_good() {
    let ring = Arc::new(GoodRing {
        prod: ProducerState {
            head: AtomicU64::new(0),
            tail: AtomicU64::new(0),
        },
        cons: ConsumerState {
            head: AtomicU64::new(0),
            tail: AtomicU64::new(0),
        },
    });

    let start = Instant::now();
    let mut handles = vec![];

    for _ in 0..PRODUCERS {
        let r = ring.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..ITERS {
                loop {
                    let head = r.prod.head.load(Ordering::Relaxed);
                    let tail = r.cons.tail.load(Ordering::Acquire);

                    if head - tail >= RING_SIZE {
                        spin_loop();
                        continue;
                    }

                    if r.prod
                        .head
                        .compare_exchange_weak(head, head + 1, Ordering::Acquire, Ordering::Relaxed)
                        .is_ok()
                    {
                        while r.prod.tail.load(Ordering::Acquire) != head {
                            spin_loop();
                        }

                        r.prod.tail.store(head + 1, Ordering::Release);
                        break;
                    }
                }
            }
        }));
    }

    for _ in 0..CONSUMERS {
        let r = ring.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..ITERS {
                loop {
                    let head = r.cons.head.load(Ordering::Relaxed);
                    let tail = r.prod.tail.load(Ordering::Acquire);

                    if tail <= head {
                        spin_loop();
                        continue;
                    }

                    if r.cons
                        .head
                        .compare_exchange_weak(head, head + 1, Ordering::Acquire, Ordering::Relaxed)
                        .is_ok()
                    {
                        while r.cons.tail.load(Ordering::Acquire) != head {
                            spin_loop();
                        }

                        r.cons.tail.store(head + 1, Ordering::Release);
                        break;
                    }
                }
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    println!("good ring: {:?}", start.elapsed());
}

fn main() {
    run_bad();
    run_good();
}
