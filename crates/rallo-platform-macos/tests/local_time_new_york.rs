//! `TZ` is process-wide, so this binary holds exactly one test (0016's
//! clock-change rules, under a zone that has them; Asia/Dhaka has none).

use rallo_platform_macos::local_time::{instant, wall_clock};
use time::macros::datetime;

#[test]
fn new_york_clock_changes() {
    // SAFETY: the only test in this binary; no other thread reads the environment yet.
    unsafe { std::env::set_var("TZ", "America/New_York") };
    unsafe extern "C" {
        fn tzset();
    }
    unsafe { tzset() };

    // Ordinary summer time, EDT (-4).
    let summer = instant(datetime!(2026-07-01 09:00)).unwrap();
    assert_eq!(summer, datetime!(2026-07-01 13:00 UTC));
    assert_eq!(summer.offset().whole_hours(), -4);
    assert_eq!(wall_clock(summer.unix_timestamp() * 1000), datetime!(2026-07-01 09:00));

    // Spring forward, Sun 8 Mar 2026: 02:30 doesn't exist -> 03:30 EDT.
    let gap = instant(datetime!(2026-03-08 02:30)).unwrap();
    assert_eq!(gap, datetime!(2026-03-08 07:30 UTC));
    assert_eq!(wall_clock(gap.unix_timestamp() * 1000), datetime!(2026-03-08 03:30));

    // Fall back, Sun 1 Nov 2026: 01:30 happens twice -> the earlier, EDT.
    let twice = instant(datetime!(2026-11-01 01:30)).unwrap();
    assert_eq!(twice, datetime!(2026-11-01 05:30 UTC));
    assert_eq!(twice.offset().whole_hours(), -4);

    // The target date's offset, not today's: Mon 2 Nov is EST (-5).
    let after_change = instant(datetime!(2026-11-02 17:00)).unwrap();
    assert_eq!(after_change, datetime!(2026-11-02 22:00 UTC));
    assert_eq!(after_change.offset().whole_hours(), -5);
}
