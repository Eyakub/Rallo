//! `TZ` is process-wide, so this binary holds exactly one test: the user's own
//! zone, Asia/Dhaka (+6, no DST).
//!
//! macOS `mktime` with `tm_isdst = 1` returns an instant one hour early in a
//! zone without DST; the read-back filter in `instant` is what keeps this exact.

use rallo_platform_macos::local_time::{instant, wall_clock};
use time::macros::datetime;

#[test]
fn dhaka_has_no_dst_and_resolves_exactly() {
    // SAFETY: the only test in this binary; no other thread reads the environment yet.
    unsafe { std::env::set_var("TZ", "Asia/Dhaka") };
    unsafe extern "C" {
        fn tzset();
    }
    unsafe { tzset() };

    let evening = instant(datetime!(2026-10-09 17:00)).unwrap();
    assert_eq!(evening, datetime!(2026-10-09 11:00 UTC));
    assert_eq!(evening.offset().whole_hours(), 6);
    assert_eq!(wall_clock(evening.unix_timestamp() * 1000), datetime!(2026-10-09 17:00));

    let winter = instant(datetime!(2026-01-15 09:00)).unwrap();
    assert_eq!(winter, datetime!(2026-01-15 03:00 UTC));
    assert_eq!(winter.offset().whole_hours(), 6);
}
