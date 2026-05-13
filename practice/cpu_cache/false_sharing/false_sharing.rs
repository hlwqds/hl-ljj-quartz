use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const THREADS: usize = 8;
const ITERS: u64 = 100_000_000;

struct Bad {
    counters: [AtomicU64; THREADS],
}

#[repr(align(64))]
struct Padded(AtomicU64);

struct Good {
    counters: [Padded; THREADS],
}

fn run_bad() {
    let x = Arc::new(Bad {
        counters: std::array::from_fn(|_| AtomicU64::new(0)),
    });

    let start = Instant::now();
    let mut handles = vec![];

    for tid in 0..THREADS {
        let x = x.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..ITERS {
                x.counters[tid].fetch_add(1, Ordering::Relaxed);
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    println!("bad false sharing: {:?}", start.elapsed());
}

fn run_good() {
    let x = Arc::new(Good {
        counters: std::array::from_fn(|_| Padded(AtomicU64::new(0))),
    });

    let start = Instant::now();
    let mut handles = vec![];

    for tid in 0..THREADS {
        let x = x.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..ITERS {
                x.counters[tid].0.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    println!("good padded:        {:?}", start.elapsed());
}

fn main() {
    run_bad();
    run_good();
}
