//! Plain-language reminder times (0016): a fixed, deterministic grammar --
//! "fri 5pm", "tomorrow 9am", "oct 20", "in 2 hours" -- resolved against a
//! local wall-clock `now`. Pure: callers convert between wall-clock time and
//! instants (`rallo-platform-macos::local_time`), so tests pin `now`.

use std::str::FromStr;

use time::format_description::well_known::Rfc3339;
use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time, Weekday};

use super::time::TimeSpec;

use crate::shared::errors::{CoreError, CoreResult, ErrorCode};

/// What a phrase means: a local wall-clock moment, or (`in …`) a duration
/// from now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhraseTarget {
    Local(PrimitiveDateTime),
    After { seconds: u64 },
}

#[derive(Debug, Clone, Copy)]
enum Day {
    Today,
    Tomorrow,
    Weekday(Weekday),
    Date { month: Month, day: u8, year: Option<i32> },
}

/// A day named without a time means 09:00 (0016).
const NINE: Time = time::macros::time!(9:00);

fn unreadable(raw: &str) -> CoreError {
    CoreError::invalid(
        ErrorCode::InvalidTime,
        format!("couldn't read \"{}\" as a time; try \"in 2h\", \"5pm\" or \"fri 9am\"", raw.trim()),
    )
}

fn passed(raw: &str) -> CoreError {
    CoreError::invalid(ErrorCode::InvalidTime, format!("\"{}\" has passed", raw.trim()))
}

fn not_a_date(raw: &str) -> CoreError {
    CoreError::invalid(ErrorCode::InvalidTime, format!("\"{}\" isn't a date", raw.trim()))
}

/// Resolves `raw` against `now` per 0016's tables: a time alone is today if
/// still ahead, else tomorrow; a day alone is 09:00; a weekday is 1-7 days
/// ahead; `today`/`tomorrow` and dates with a year never roll; a result not
/// strictly after `now` is refused.
pub fn resolve(raw: &str, now: PrimitiveDateTime) -> CoreResult<PhraseTarget> {
    let lower = siri_tidy(&raw.to_lowercase());
    let words: Vec<&str> = lower.split_whitespace().collect();
    if let ["in", rest @ ..] = words.as_slice() {
        return relative(rest).map(|seconds| PhraseTarget::After { seconds }).ok_or_else(|| unreadable(raw));
    }
    let (day, time) = parse(&words).ok_or_else(|| unreadable(raw))?;
    let today = now.date();
    let next_day = |date: Date| date.next_day().ok_or_else(|| unreadable(raw));
    let at = |date: Date| PrimitiveDateTime::new(date, time.unwrap_or(NINE));
    let target = match day {
        None => {
            let time = time.expect("parse yields a day or a time");
            let candidate = PrimitiveDateTime::new(today, time);
            if candidate > now { candidate } else { PrimitiveDateTime::new(next_day(today)?, time) }
        }
        Some(Day::Today) if time.is_none() => {
            return Err(CoreError::invalid(ErrorCode::InvalidTime, "add a time, e.g. \"today 5pm\""));
        }
        Some(Day::Today) => at(today),
        Some(Day::Tomorrow) => at(next_day(today)?),
        Some(Day::Weekday(weekday)) => at(today.next_occurrence(weekday)),
        Some(Day::Date { month, day, year: Some(year) }) => {
            at(Date::from_calendar_date(year, month, day).map_err(|_| not_a_date(raw))?)
        }
        Some(Day::Date { month, day, year: None }) => {
            let this_year = Date::from_calendar_date(today.year(), month, day).ok().filter(|date| *date >= today);
            match this_year {
                Some(date) => at(date),
                None => at(Date::from_calendar_date(today.year() + 1, month, day).map_err(|_| not_a_date(raw))?),
            }
        }
    };
    if target <= now {
        return Err(passed(raw));
    }
    Ok(PhraseTarget::Local(target))
}

/// Siri writes "9 a.m." and ends dictation with a period (0017): read
/// `a.m.`/`p.m.` as am/pm, then drop one trailing `.`, `,` or `!`.
fn siri_tidy(lower: &str) -> String {
    let spelled = lower.replace("a.m.", "am").replace("p.m.", "pm");
    let trimmed = spelled.trim_end();
    trimmed.strip_suffix(['.', ',', '!']).unwrap_or(trimmed).to_owned()
}

/// At most one day-or-date and one time, in either order; `at` must be
/// followed by a time and `on` by a day or date; nothing left over.
fn parse(words: &[&str]) -> Option<(Option<Day>, Option<Time>)> {
    let (mut day, mut time) = (None, None);
    let mut rest = words;
    while let Some((&first, tail)) = rest.split_first() {
        let (want_time, want_day, words) = match first {
            "at" => (true, false, tail),
            "on" => (false, true, tail),
            _ => (true, true, rest),
        };
        if want_time && let Some((parsed, used)) = parse_time(words) {
            if time.replace(parsed).is_some() {
                return None;
            }
            rest = &words[used..];
        } else if want_day && let Some((parsed, used)) = parse_day(words) {
            if day.replace(parsed).is_some() {
                return None;
            }
            rest = &words[used..];
        } else {
            return None;
        }
    }
    (day.is_some() || time.is_some()).then_some((day, time))
}

/// ASCII digits only (`u8::from_str` alone would take "+9"), at most four.
fn digits<T: FromStr>(text: &str) -> Option<T> {
    (!text.is_empty() && text.len() <= 4 && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

/// `noon`, `9am`/`9:30pm`, `9 am`, or 24-hour `17:00`/`09:45` (two-digit hour); returns the
/// time and how many words it used. A bare hour is never a time.
fn parse_time(words: &[&str]) -> Option<(Time, usize)> {
    let first = *words.first()?;
    if first == "noon" {
        return Some((time::macros::time!(12:00), 1));
    }
    for (suffix, pm) in [("am", false), ("pm", true)] {
        if let Some(clock) = first.strip_suffix(suffix) {
            return twelve_hour(clock, pm).map(|time| (time, 1));
        }
    }
    let pm = match words.get(1) {
        Some(&"am") => Some(false),
        Some(&"pm") => Some(true),
        _ => None,
    };
    if let Some(pm) = pm {
        return twelve_hour(first, pm).map(|time| (time, 2));
    }
    let (hour, minute) = first.split_once(':')?;
    if hour.len() != 2 || minute.len() != 2 {
        return None;
    }
    Time::from_hms(digits(hour)?, digits(minute)?, 0).ok().map(|time| (time, 1))
}

/// `9`, `9:30` with am/pm: hour 1-12, `12am` is 00:00, `12pm` is 12:00.
fn twelve_hour(clock: &str, pm: bool) -> Option<Time> {
    let (hour, minute) = match clock.split_once(':') {
        Some((hour, minute)) if minute.len() == 2 => (hour, minute),
        Some(_) => return None,
        None => (clock, "00"),
    };
    let (hour, minute): (u8, u8) = (digits(hour)?, digits(minute)?);
    if !(1..=12).contains(&hour) {
        return None;
    }
    Time::from_hms(hour % 12 + if pm { 12 } else { 0 }, minute, 0).ok()
}

/// `today`, `tomorrow`/`tmrw`, a weekday, an ISO date, or a month and day in
/// either order with an optional 4-digit year; returns how many words it used.
fn parse_day(words: &[&str]) -> Option<(Day, usize)> {
    let first = *words.first()?;
    match first {
        "today" => return Some((Day::Today, 1)),
        "tomorrow" | "tmrw" => return Some((Day::Tomorrow, 1)),
        _ => {}
    }
    if let Some(weekday) = weekday(first) {
        return Some((Day::Weekday(weekday), 1));
    }
    if let Some(date) = iso_date(first) {
        return Some((date, 1));
    }
    let second = *words.get(1)?;
    let (month, day) = match (month(first), month(second)) {
        (Some(month), None) => (month, digits(second)?),
        (None, Some(month)) => (month, digits(first)?),
        _ => return None,
    };
    match words.get(2).filter(|word| word.len() == 4).and_then(|word| digits(word)) {
        Some(year) => Some((Day::Date { month, day, year: Some(year) }, 3)),
        None => Some((Day::Date { month, day, year: None }, 2)),
    }
}

/// `YYYY-MM-DD`; validity (Feb 30) is checked when resolving.
fn iso_date(word: &str) -> Option<Day> {
    let mut parts = word.split('-');
    let (year, month, day) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || year.len() != 4 || month.len() != 2 || day.len() != 2 {
        return None;
    }
    let month = Month::try_from(digits::<u8>(month)?).ok()?;
    Some(Day::Date { month, day: digits(day)?, year: Some(digits(year)?) })
}

fn weekday(word: &str) -> Option<Weekday> {
    Some(match word {
        "mon" | "monday" => Weekday::Monday,
        "tue" | "tues" | "tuesday" => Weekday::Tuesday,
        "wed" | "wednesday" => Weekday::Wednesday,
        "thu" | "thur" | "thurs" | "thursday" => Weekday::Thursday,
        "fri" | "friday" => Weekday::Friday,
        "sat" | "saturday" => Weekday::Saturday,
        "sun" | "sunday" => Weekday::Sunday,
        _ => return None,
    })
}

fn month(word: &str) -> Option<Month> {
    Some(match word {
        "jan" | "january" => Month::January,
        "feb" | "february" => Month::February,
        "mar" | "march" => Month::March,
        "apr" | "april" => Month::April,
        "may" => Month::May,
        "jun" | "june" => Month::June,
        "jul" | "july" => Month::July,
        "aug" | "august" => Month::August,
        "sep" | "sept" | "september" => Month::September,
        "oct" | "october" => Month::October,
        "nov" | "november" => Month::November,
        "dec" | "december" => Month::December,
        _ => return None,
    })
}

/// After `in`: the `--in` grammar ("2h30m"), or a number and one spelled
/// unit ("2 hours", "45 min").
fn relative(words: &[&str]) -> Option<u64> {
    match words {
        [compact] => super::time::parse_relative(compact).ok(),
        [count, unit] => {
            let per_unit: u64 = match *unit {
                "min" | "mins" | "minute" | "minutes" => 60,
                "h" | "hr" | "hrs" | "hour" | "hours" => 3_600,
                "day" | "days" => 86_400,
                _ => return None,
            };
            digits::<u64>(count)?.checked_mul(per_unit).filter(|seconds| *seconds > 0)
        }
        _ => None,
    }
}

/// `--at` input (0016): RFC 3339 is passed through verbatim, so its stored
/// input and idempotency fingerprint are unchanged; otherwise a phrase,
/// resolved against the local clock, becomes RFC 3339 carrying the target
/// date's offset, or (`in ...`) an `--in` duration in seconds. `wall_clock` and
/// `instant` are `rallo_platform_macos::local_time`'s conversions.
pub fn time_spec(
    raw: &str,
    now_ms: i64,
    wall_clock: impl Fn(i64) -> PrimitiveDateTime,
    instant: impl Fn(PrimitiveDateTime) -> Option<OffsetDateTime>,
) -> CoreResult<TimeSpec> {
    let raw = raw.trim();
    if OffsetDateTime::parse(raw, &Rfc3339).is_ok() {
        return Ok(TimeSpec::At(raw.to_owned()));
    }
    match resolve(raw, wall_clock(now_ms))? {
        PhraseTarget::After { seconds } => Ok(TimeSpec::In(format!("{seconds}s"))),
        PhraseTarget::Local(local) => {
            let at = instant(local).ok_or_else(|| unreadable(raw))?;
            Ok(TimeSpec::At(at.format(&Rfc3339).map_err(|_| unreadable(raw))?))
        }
    }
}

#[cfg(test)]
mod tests {
    use time::macros::datetime;

    use super::*;
    use crate::shared::errors::ErrorCode;

    /// Tue 6 Oct 2026, 10:30 local -- the examples in 0016.
    const NOW: PrimitiveDateTime = datetime!(2026-10-06 10:30);

    #[test]
    fn siri_transcriptions() {
        assert_eq!(local("Tomorrow at 9 a.m."), datetime!(2026-10-07 09:00));
        assert_eq!(local("fri 5 P.M."), datetime!(2026-10-09 17:00));
        assert_eq!(local("fri 5p.m."), datetime!(2026-10-09 17:00));
        assert_eq!(local("fri 5pm."), datetime!(2026-10-09 17:00));
        assert_eq!(local("tomorrow 9am,"), datetime!(2026-10-07 09:00));
        assert_eq!(local("fri 5pm!"), datetime!(2026-10-09 17:00));
        assert_eq!(after("in 2 hours."), 7_200);
        // Only one trailing mark, and only these three.
        refused("fri 5pm..");
        refused("fri 5pm?");
    }

    fn local(raw: &str) -> PrimitiveDateTime {
        match resolve(raw, NOW) {
            Ok(PhraseTarget::Local(at)) => at,
            other => panic!("{raw:?} -> {other:?}"),
        }
    }

    fn after(raw: &str) -> u64 {
        match resolve(raw, NOW) {
            Ok(PhraseTarget::After { seconds }) => seconds,
            other => panic!("{raw:?} -> {other:?}"),
        }
    }

    fn refused(raw: &str) -> String {
        let error = resolve(raw, NOW).expect_err(raw);
        assert_eq!(error.code(), ErrorCode::InvalidTime, "{raw:?}");
        error.to_string()
    }

    #[test]
    fn a_time_alone_is_today_if_still_ahead_else_tomorrow() {
        assert_eq!(local("3pm"), datetime!(2026-10-06 15:00));
        assert_eq!(local("9am"), datetime!(2026-10-07 09:00));
        assert_eq!(local("9 am"), datetime!(2026-10-07 09:00));
        assert_eq!(local("9:30PM"), datetime!(2026-10-06 21:30));
        assert_eq!(local("17:00"), datetime!(2026-10-06 17:00));
        assert_eq!(local("09:45"), datetime!(2026-10-07 09:45));
        assert_eq!(local("noon"), datetime!(2026-10-06 12:00));
        assert_eq!(local("12am"), datetime!(2026-10-07 00:00));
        assert_eq!(local("12pm"), datetime!(2026-10-06 12:00));
        // Strictly after now: the current minute rolls to tomorrow.
        assert_eq!(local("10:30"), datetime!(2026-10-07 10:30));
        assert_eq!(
            resolve("noon", datetime!(2026-10-06 12:00)).unwrap(),
            PhraseTarget::Local(datetime!(2026-10-07 12:00))
        );
    }

    #[test]
    fn a_day_alone_is_nine_oclock() {
        assert_eq!(local("tomorrow"), datetime!(2026-10-07 09:00));
        assert_eq!(local("tmrw"), datetime!(2026-10-07 09:00));
        assert_eq!(local("fri"), datetime!(2026-10-09 09:00));
        assert_eq!(local("Friday"), datetime!(2026-10-09 09:00));
        assert_eq!(local("thurs"), datetime!(2026-10-08 09:00));
        assert_eq!(local("oct 20"), datetime!(2026-10-20 09:00));
    }

    #[test]
    fn a_weekday_is_one_to_seven_days_ahead_never_today() {
        assert_eq!(local("tue"), datetime!(2026-10-13 09:00));
        assert_eq!(local("tue 3pm"), datetime!(2026-10-13 15:00));
        assert_eq!(local("wed"), datetime!(2026-10-07 09:00));
        assert_eq!(local("mon"), datetime!(2026-10-12 09:00));
    }

    #[test]
    fn day_and_time_in_either_order_with_optional_at_and_on() {
        for raw in ["fri 5pm", "5pm fri", "on fri at 5pm", "at 5pm on fri", "fri at 5pm", "  FRI   5PM  "] {
            assert_eq!(local(raw), datetime!(2026-10-09 17:00), "{raw:?}");
        }
        assert_eq!(local("tomorrow 9am"), datetime!(2026-10-07 09:00));
        assert_eq!(local("9am tomorrow"), datetime!(2026-10-07 09:00));
        assert_eq!(local("today 3pm"), datetime!(2026-10-06 15:00));
    }

    #[test]
    fn today_never_rolls() {
        assert!(refused("today 9am").contains("has passed"));
        assert!(refused("today").contains("add a time"));
    }

    #[test]
    fn dates() {
        assert_eq!(local("20 oct 2pm"), datetime!(2026-10-20 14:00));
        assert_eq!(local("october 20 2027"), datetime!(2027-10-20 09:00));
        assert_eq!(local("2026-10-20"), datetime!(2026-10-20 09:00));
        assert_eq!(local("2026-10-20 8:15pm"), datetime!(2026-10-20 20:15));
        // No year: next time it comes round, judged by the date alone.
        assert_eq!(local("jan 5"), datetime!(2027-01-05 09:00));
        assert_eq!(local("oct 5"), datetime!(2027-10-05 09:00));
        assert_eq!(local("oct 6 3pm"), datetime!(2026-10-06 15:00));
        assert!(refused("oct 6").contains("has passed"));
        assert!(refused("feb 30").contains("isn't a date"));
        assert!(refused("2026-02-30").contains("isn't a date"));
        assert!(refused("2025-01-01").contains("has passed"));
        assert!(refused("oct 20 2025").contains("has passed"));
    }

    #[test]
    fn in_a_duration() {
        assert_eq!(after("in 2h30m"), 9_000);
        assert_eq!(after("in 2 hours"), 7_200);
        assert_eq!(after("in 1 hr"), 3_600);
        assert_eq!(after("in 45 min"), 2_700);
        assert_eq!(after("in 1 day"), 86_400);
        assert_eq!(after("IN 2 HOURS"), 7_200);
        assert_eq!(after("in 9999 days"), 863_913_600);
        for raw in ["in 0 min", "in 2", "in 2 weeks", "in", "in 2 hours 5 min", "in 99999999999999999999h"] {
            refused(raw);
        }
    }

    #[test]
    fn vague_or_unknown_input_is_refused_with_the_hint() {
        for raw in [
            "later",
            "soon",
            "tonight",
            "next week",
            "this weekend",
            "next fri",
            "9",
            "fri 9",
            "midnight",
            "",
            "   ",
            "fri sat",
            "5pm 6pm",
            "at",
            "on",
            "on 5pm",
            "at fri",
            "13pm",
            "0am",
            "24:00",
            "5:30",
            "9:45",
            "9:7pm",
            "+9am",
            "1730",
            "fri 5pm?",
            "fri 5pm 🦊",
            "okt 20",
            "2027",
        ] {
            let message = refused(raw);
            if !message.contains("has passed") && !message.contains("isn't a date") {
                let shown = raw.trim();
                assert_eq!(
                    message,
                    format!("couldn't read \"{shown}\" as a time; try \"in 2h\", \"5pm\" or \"fri 9am\"")
                );
            }
        }
    }

    use time::OffsetDateTime;
    use time::macros::offset;

    use crate::reminders::TimeSpec;
    use crate::reminders::time::deadline_ms;

    /// A fixed +06:00 zone standing in for the platform conversions.
    fn dhaka_wall(unix_ms: i64) -> PrimitiveDateTime {
        let at = OffsetDateTime::from_unix_timestamp(unix_ms.div_euclid(1000)).unwrap().to_offset(offset!(+6));
        PrimitiveDateTime::new(at.date(), at.time())
    }

    fn dhaka_instant(local: PrimitiveDateTime) -> Option<OffsetDateTime> {
        Some(local.assume_offset(offset!(+6)))
    }

    const NOW_MS: i64 = datetime!(2026-10-06 10:30 +6).unix_timestamp() * 1000;

    fn spec(raw: &str) -> CoreResult<TimeSpec> {
        time_spec(raw, NOW_MS, dhaka_wall, dhaka_instant)
    }

    #[test]
    fn rfc3339_passes_through_verbatim() {
        let raw = "2026-10-09T17:00:00+06:00";
        assert_eq!(spec(raw).unwrap(), TimeSpec::At(raw.to_owned()));
        assert_eq!(spec("2026-10-09T11:00:00Z").unwrap(), TimeSpec::At("2026-10-09T11:00:00Z".to_owned()));
        assert_eq!(spec(" 2026-10-09T17:00:00+06:00 \n").unwrap(), TimeSpec::At(raw.to_owned()));
    }

    #[test]
    fn a_phrase_becomes_rfc3339_with_the_target_offset() {
        assert_eq!(spec("fri 5pm").unwrap(), TimeSpec::At("2026-10-09T17:00:00+06:00".to_owned()));
        assert_eq!(spec("in 2 hours").unwrap(), TimeSpec::In("7200s".to_owned()));
    }

    #[test]
    fn unzoned_rfc3339_is_still_invalid() {
        let error = spec("2026-10-09T17:00:00").unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidTime);
    }

    #[test]
    fn preview_deadline_matches_what_a_write_would_store() {
        let fri = datetime!(2026-10-09 17:00 +6).unix_timestamp() * 1000;
        assert_eq!(deadline_ms(&spec("fri 5pm").unwrap(), NOW_MS).unwrap(), fri);
        assert_eq!(deadline_ms(&spec("in 2 hours").unwrap(), NOW_MS).unwrap(), NOW_MS + 7_200_000);
        assert_eq!(
            deadline_ms(&TimeSpec::At("2020-01-01T00:00:00Z".to_owned()), NOW_MS).unwrap_err().code(),
            ErrorCode::InvalidTime
        );
    }
}
