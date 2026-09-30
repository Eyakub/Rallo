//! Local wall-clock rendering for human output (build plan §7, 0003 §11).
//!
//! The CLI is single-threaded, so `libc::localtime_r` is used directly
//! instead of adding a timezone crate: no other thread can race a concurrent
//! `tzset`/`localtime` call within one process.

/// Formats a UTC millisecond timestamp as local date/time with an explicit
/// numeric UTC offset, e.g. `2026-10-01 15:20 -06:00`. Deadlines never carry
/// fractional seconds worth displaying to a human.
pub fn format_local(deadline_ms: i64) -> String {
    let seconds = deadline_ms.div_euclid(1000);
    let time = seconds as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        libc::localtime_r(&time, &mut tm);
    }
    let offset_seconds = tm.tm_gmtoff;
    let sign = if offset_seconds < 0 { '-' } else { '+' };
    let offset_seconds = offset_seconds.unsigned_abs();
    let offset_hours = offset_seconds / 3600;
    let offset_minutes = (offset_seconds % 3600) / 60;
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02} {sign}{offset_hours:02}:{offset_minutes:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
    )
}
