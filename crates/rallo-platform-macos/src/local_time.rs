//! Local wall-clock time <-> UTC instants (0016), via `localtime_r`/`mktime`
//! so the CLI and the app read the Mac's time zone, and its clock changes,
//! the same way. Both are reentrant; nothing in Rallo sets `TZ` at run time.

use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time, UtcOffset};

// `libc::time_t` is `i64` on macOS, so seconds pass between it and `time`'s
// `i64` timestamps without casts.
fn tm_at(unix_seconds: libc::time_t) -> libc::tm {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        libc::localtime_r(&unix_seconds, &mut tm);
    }
    tm
}

fn wall(tm: &libc::tm) -> Option<PrimitiveDateTime> {
    let month = Month::try_from(u8::try_from(tm.tm_mon + 1).ok()?).ok()?;
    let date = Date::from_calendar_date(tm.tm_year + 1900, month, u8::try_from(tm.tm_mday).ok()?).ok()?;
    // A leap second (tm_sec 60) is shown as :59.
    let second = u8::try_from(tm.tm_sec.min(59)).ok()?;
    let time = Time::from_hms(u8::try_from(tm.tm_hour).ok()?, u8::try_from(tm.tm_min).ok()?, second).ok()?;
    Some(PrimitiveDateTime::new(date, time))
}

/// The local wall-clock time at `unix_ms`.
pub fn wall_clock(unix_ms: i64) -> PrimitiveDateTime {
    wall(&tm_at(unix_ms.div_euclid(1000))).expect("localtime_r yields a valid calendar date")
}

/// The instant the local wall-clock time `local` names, carrying the offset in
/// force then. A time skipped by a spring-forward change moves forward by the
/// gap; a time that occurs twice resolves to the earlier one (0016). `mktime`
/// is asked under both DST assumptions; a candidate that reads back as `local`
/// is exact (the earliest wins), else the later one is the forward-moved time.
pub fn instant(local: PrimitiveDateTime) -> Option<OffsetDateTime> {
    let candidates: Vec<libc::time_t> = [0, 1]
        .into_iter()
        .filter_map(|is_dst| {
            let mut tm: libc::tm = unsafe { std::mem::zeroed() };
            tm.tm_year = local.year() - 1900;
            tm.tm_mon = i32::from(u8::from(local.month())) - 1;
            tm.tm_mday = i32::from(local.day());
            tm.tm_hour = i32::from(local.hour());
            tm.tm_min = i32::from(local.minute());
            tm.tm_sec = i32::from(local.second());
            tm.tm_isdst = is_dst;
            let seconds = unsafe { libc::mktime(&mut tm) };
            (seconds != -1).then_some(seconds)
        })
        .collect();
    let exact = candidates.iter().copied().filter(|&seconds| wall(&tm_at(seconds)) == Some(local)).min();
    let seconds = exact.or_else(|| candidates.iter().copied().max())?;
    let offset = UtcOffset::from_whole_seconds(i32::try_from(tm_at(seconds).tm_gmtoff).ok()?).ok()?;
    Some(OffsetDateTime::from_unix_timestamp(seconds).ok()?.to_offset(offset))
}
