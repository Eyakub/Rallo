//! Time input parsing (0003 §5): `--in` relative durations and `--at`
//! RFC 3339 absolute deadlines.

use serde::Serialize;
use serde::ser::SerializeMap;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use super::model::InputKind;
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};

/// Raw `--in`/`--at` input, held verbatim (0003 §5, §7): stored as
/// `reminders.time_input` and used as-is in idempotency fingerprints, so a
/// retried relative request (e.g. `"20m"`) never gets fingerprinted against
/// a recomputed deadline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TimeSpec {
    In(String),
    At(String),
}

impl TimeSpec {
    /// The verbatim input, stored as `reminders.time_input`.
    pub fn raw(&self) -> &str {
        match self {
            Self::In(raw) | Self::At(raw) => raw,
        }
    }
}

/// Serialized as `{"in": "<raw>"}` or `{"at": "<raw>"}` for idempotency
/// fingerprints (0003 §7): the original input, never a computed deadline.
impl Serialize for TimeSpec {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(1))?;
        match self {
            Self::In(raw) => map.serialize_entry("in", raw)?,
            Self::At(raw) => map.serialize_entry("at", raw)?,
        }
        map.end()
    }
}

/// Result of syntax-only parsing (0003 §5): everything that does not depend
/// on the current time. An absolute deadline is fully computed here since an
/// RFC 3339 instant is self-contained; a relative duration is only resolved
/// to a deadline by `resolve`, against the clock snapshot the caller took at
/// the start of its write transaction.
pub(crate) enum ParsedTime {
    Relative { total_seconds: u64 },
    Absolute { deadline_ms: i64, offset_seconds: i32 },
}

/// A fully resolved deadline, ready to store.
pub(crate) struct ResolvedTime {
    pub deadline_ms: i64,
    pub input_kind: InputKind,
    pub input_offset_seconds: Option<i32>,
}

fn invalid_time() -> CoreError {
    CoreError::invalid(ErrorCode::InvalidTime, "time input is invalid")
}

/// `--in` grammar (0003 §5): `^(\d+d)?(\d+h)?(\d+m)?(\d+s)?$`, at least one
/// group, units in that order, each at most once, lowercase. Implemented by
/// hand rather than with a regex dependency: each unit is tried in order at
/// the current position; a match consumes its digits and unit letter, a
/// non-match leaves the position untouched so a later unit can still claim
/// the same digits (this is exactly how an optional non-consuming regex
/// group behaves). Anything left unconsumed after all four units means the
/// order, case, or extra characters were wrong.
pub(super) fn parse_relative(raw: &str) -> CoreResult<u64> {
    const UNITS: [(u8, u64); 4] = [(b'd', 86_400), (b'h', 3_600), (b'm', 60), (b's', 1)];
    let bytes = raw.as_bytes();
    let mut pos = 0usize;
    let mut total: u64 = 0;
    let mut matched_any = false;
    for (unit_byte, seconds_per_unit) in UNITS {
        let digits_start = pos;
        let mut digits_end = pos;
        while digits_end < bytes.len() && bytes[digits_end].is_ascii_digit() {
            digits_end += 1;
        }
        if digits_end > digits_start && bytes.get(digits_end) == Some(&unit_byte) {
            let value: u64 = raw[digits_start..digits_end].parse().map_err(|_| invalid_time())?;
            let contribution = value.checked_mul(seconds_per_unit).ok_or_else(invalid_time)?;
            total = total.checked_add(contribution).ok_or_else(invalid_time)?;
            pos = digits_end + 1;
            matched_any = true;
        }
    }
    if !matched_any || pos != bytes.len() || total == 0 {
        return Err(invalid_time());
    }
    Ok(total)
}

/// `--at` grammar (0003 §5): RFC 3339 with an explicit offset. `time`'s
/// well-known `Rfc3339` format description rejects input without one (an
/// unzoned local time is not valid RFC 3339 to begin with).
fn parse_absolute(raw: &str) -> CoreResult<(i64, i32)> {
    let parsed = OffsetDateTime::parse(raw, &Rfc3339).map_err(|_| invalid_time())?;
    let offset_seconds = parsed.offset().whole_seconds();
    let deadline_ms = i64::try_from(parsed.unix_timestamp_nanos().div_euclid(1_000_000)).map_err(|_| invalid_time())?;
    Ok((deadline_ms, offset_seconds))
}

/// Syntax-only parse, independent of the clock. Call before opening a write
/// transaction, the same way note text is validated up front.
pub(crate) fn parse(spec: &TimeSpec) -> CoreResult<ParsedTime> {
    match spec {
        TimeSpec::In(raw) => Ok(ParsedTime::Relative { total_seconds: parse_relative(raw)? }),
        TimeSpec::At(raw) => {
            let (deadline_ms, offset_seconds) = parse_absolute(raw)?;
            Ok(ParsedTime::Absolute { deadline_ms, offset_seconds })
        }
    }
}

/// Latest representable deadline (0003 §5): 9999-12-31T23:59:59Z.
fn max_deadline_ms() -> i64 {
    time::macros::datetime!(9999-12-31 23:59:59 UTC).unix_timestamp() * 1_000
}

impl ParsedTime {
    /// Resolves against the clock. Callers must invoke this exactly once,
    /// inside the write transaction, using the clock snapshot taken before
    /// checking the idempotency receipt: the deadline is computed once "at
    /// first commit" and never recomputed on a later replay (0003 §5, §7).
    pub(crate) fn resolve(&self, now_ms: i64) -> CoreResult<ResolvedTime> {
        match *self {
            Self::Relative { total_seconds } => {
                let delta_ms =
                    total_seconds.checked_mul(1_000).and_then(|ms| i64::try_from(ms).ok()).ok_or_else(invalid_time)?;
                let deadline_ms = now_ms.checked_add(delta_ms).ok_or_else(invalid_time)?;
                if deadline_ms > max_deadline_ms() {
                    return Err(invalid_time());
                }
                Ok(ResolvedTime { deadline_ms, input_kind: InputKind::Relative, input_offset_seconds: None })
            }
            Self::Absolute { deadline_ms, offset_seconds } => {
                if deadline_ms <= now_ms || deadline_ms > max_deadline_ms() {
                    return Err(invalid_time());
                }
                Ok(ResolvedTime {
                    deadline_ms,
                    input_kind: InputKind::Absolute,
                    input_offset_seconds: Some(offset_seconds),
                })
            }
        }
    }
}
