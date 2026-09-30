//! Fills a data directory with plain notes via the public core API, for
//! benchmarking `rallo list`/`rallo search` at scale (build plan §11).
//!
//!   cargo run --release -p rallo-core --example seed -- <dir> <count>
//!
//! Each note is its own durable, `synchronous=FULL` commit (`Store::open`
//! never relaxes that for a benchmark), so seeding 10,000 items is expected
//! to take real wall-clock time; this is a one-time setup step, not part of
//! the measured scenario.

use std::env;
use std::process::ExitCode;

use rallo_core::{Store, StoreOptions};

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let (Some(dir), Some(count)) = (args.next(), args.next()) else {
        eprintln!("usage: seed <dir> <count>");
        return ExitCode::FAILURE;
    };
    let count: usize = match count.parse() {
        Ok(count) => count,
        Err(_) => {
            eprintln!("count must be a non-negative integer, got {count:?}");
            return ExitCode::FAILURE;
        }
    };

    let mut store = Store::open(StoreOptions::new(dir)).expect("store opens");
    for i in 0..count {
        store.create_note(&format!("seed note {i}"), None).expect("create_note succeeds");
    }
    println!("seeded {count} notes");
    ExitCode::SUCCESS
}
