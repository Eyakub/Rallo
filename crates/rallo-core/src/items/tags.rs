//! `#tags` in a note's own text (0019 §7). Nothing is stored: tags are found
//! when notes are read, by this one parser, which the app reaches through the
//! FFI so Swift never re-implements the grammar.
//!
//! Grammar: `(?:^|\s)#(\p{L}[\p{L}\p{M}\p{N}_\u{200C}\u{200D}-]*)`, minus a trailing `-` or `_`.
//! There is no regex crate here: `is_letter`, `is_mark` and `is_number` below
//! are the three Unicode classes written out with `std` and
//! `unicode-normalization` (already a dependency for `match_key`).

use std::collections::HashSet;

use rusqlite::Connection;
use rusqlite::functions::FunctionFlags;
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

use crate::shared::errors::{CoreError, CoreResult, ErrorCode};

fn is_mark(c: char) -> bool {
    is_combining_mark(c)
}

fn is_number(c: char) -> bool {
    c.is_numeric()
}

// ponytail: `is_alphabetic` is \p{L} plus Nl and Other_Alphabetic; once marks
// and numbers are taken out, the only strays are circled letters (Ⓐ). Not
// worth a Unicode table; swap in `regex` if a real note ever needs them.
fn is_letter(c: char) -> bool {
    c.is_alphabetic() && !is_mark(c) && !is_number(c)
}

fn is_tag_char(c: char) -> bool {
    // U+200C/U+200D (Cf) spell Bangla conjuncts such as র‍্যালো, so they belong to a tag (0019 §7).
    is_letter(c) || is_mark(c) || is_number(c) || matches!(c, '-' | '_' | '\u{200C}' | '\u{200D}')
}

/// Every tag in `text`, in order of appearance, as `(utf16_start, utf16_len,
/// key)`. The range covers the `#` and the tag, for highlighting in an
/// `NSTextView` (UTF-16 offsets); `key` is the tag without the `#`, NFC-normalized then lowercased.
/// A trailing `-` or `_` is outside the range (`#bug-` is `#bug`).
pub fn tag_ranges(text: &str) -> Vec<(u32, u32, String)> {
    if !text.contains('#') {
        return Vec::new();
    }
    let chars: Vec<char> = text.chars().collect();
    let mut offsets = Vec::with_capacity(chars.len() + 1);
    let mut at = 0u32;
    for c in &chars {
        offsets.push(at);
        at += c.len_utf16() as u32;
    }
    offsets.push(at);

    let mut found = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let starts_tag = chars[i] == '#'
            && (i == 0 || chars[i - 1].is_whitespace())
            && chars.get(i + 1).is_some_and(|&c| is_letter(c));
        if !starts_tag {
            i += 1;
            continue;
        }
        let mut end = i + 2;
        while end < chars.len() && is_tag_char(chars[end]) {
            end += 1;
        }
        // chars[i + 1] is a letter, so this stops at i + 2 at the latest.
        while matches!(chars[end - 1], '-' | '_') {
            end -= 1;
        }
        let key: String = chars[i + 1..end].iter().collect::<String>().nfc().collect::<String>().to_lowercase();
        found.push((offsets[i], offsets[end] - offsets[i], key));
        i = end;
    }
    found
}

/// The tag keys in `text`: first-appearance order, no duplicates.
pub fn tags(text: &str) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for (_, _, key) in tag_ranges(text) {
        if seen.insert(key.clone()) {
            keys.push(key);
        }
    }
    keys
}

/// Whether `text` carries the tag `key` (already NFC and lowercased).
pub fn has_tag(text: &str, key: &str) -> bool {
    tag_ranges(text).iter().any(|(_, _, found)| found == key)
}

/// A `--tag` / `tag:` argument: one valid tag, with or without the leading
/// `#`, as its key. Anything else (`#123`, `a b`, `bug-`, ``) is `INVALID_INPUT`.
pub fn parse_tag_argument(input: &str) -> CoreResult<String> {
    let trimmed = input.trim();
    let probe = format!("#{}", trimmed.strip_prefix('#').unwrap_or(trimmed));
    match tag_ranges(&probe).as_slice() {
        [(0, len, key)] if *len as usize == probe.encode_utf16().count() => Ok(key.clone()),
        _ => Err(CoreError::invalid(
            ErrorCode::InvalidInput,
            format!("\"{trimmed}\" is not a tag: a tag is a letter followed by letters, digits, - or _"),
        )),
    }
}

/// Registers `rallo_has_tag(text, key)` on a connection, so `--tag` is a
/// `WHERE` clause (and so counts and cursors stay SQL's).
pub(crate) fn register(conn: &Connection) -> rusqlite::Result<()> {
    conn.create_scalar_function(
        "rallo_has_tag",
        2,
        FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| {
            let key: String = ctx.get(1)?;
            Ok(ctx.get_raw(0).as_str().is_ok_and(|text| has_tag(text, &key)))
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn many_distinct_tags_keep_first_appearance_order() {
        let text: String = (0..5000).map(|i| format!("#t{i} #t{} ", i / 2)).collect();
        let found = tags(&text);
        assert_eq!(found.len(), 5000);
        assert!(found.iter().enumerate().all(|(i, key)| *key == format!("t{i}")));
    }

    #[test]
    fn spec_examples_that_are_tags() {
        assert_eq!(tags("#bug"), ["bug"]);
        assert_eq!(tags("ship it #meeting-notes now"), ["meeting-notes"]);
        assert_eq!(tags("#Q4_plan"), ["q4_plan"]);
        assert_eq!(tags("কাজ আছে #কাজ"), ["কাজ"], "a Bangla tag keeps its vowel signs");
        assert_eq!(tags("line one\n#second\t#third"), ["second", "third"], "any whitespace may precede a tag");
    }

    #[test]
    fn spec_examples_that_are_not_tags() {
        for text in ["fix #123", "C#", "# Heading", "a#b", "https://x.y/#frag", "#", "##bug", "#-x", "#_x", "#1st"] {
            assert!(tags(text).is_empty(), "{text:?} must not contain a tag, found {:?}", tags(text));
        }
    }

    #[test]
    fn trailing_dash_or_underscore_is_dropped_but_inner_ones_stay() {
        assert_eq!(tags("#bug-"), ["bug"]);
        assert_eq!(tags("#bug_"), ["bug"]);
        assert_eq!(tags("#bug-_-"), ["bug"]);
        assert_eq!(tags("#bug-fix_2-"), ["bug-fix_2"]);
        assert_eq!(tag_ranges("#bug- x"), [(0, 4, "bug".to_owned())], "the range stops before the dash");
    }

    #[test]
    fn keys_are_lowercased_deduplicated_and_in_first_appearance_order() {
        assert_eq!(tags("#Bug and #work and #bug and #BUG #Work"), ["bug", "work"]);
        assert_eq!(tags("#ÉCOLE"), ["école"]);
    }

    #[test]
    fn a_tag_ends_at_punctuation_or_the_next_hash() {
        assert_eq!(tags("(#bug) #a,b #c#d"), ["a", "c"], "not after a bracket, not after a letter");
        assert_eq!(tags("#bug."), ["bug"]);
    }

    #[test]
    fn ranges_are_utf16_offsets_that_cover_the_hash() {
        // "😀" is two UTF-16 units, so the tag starts at offset 3 (😀, space).
        assert_eq!(tag_ranges("😀 #bug x"), [(3, 4, "bug".to_owned())]);
        // Bangla letters are one UTF-16 unit each: "#কাজ" is 4 units.
        assert_eq!(tag_ranges("কাজ #কাজ"), [(4, 4, "কাজ".to_owned())]);
        assert_eq!(tag_ranges("#a #b"), [(0, 2, "a".to_owned()), (3, 2, "b".to_owned())]);
    }

    #[test]
    fn tag_arguments_take_an_optional_hash_and_exactly_one_tag() {
        assert_eq!(parse_tag_argument("bug").unwrap(), "bug");
        assert_eq!(parse_tag_argument("#Bug").unwrap(), "bug");
        assert_eq!(parse_tag_argument(" #কাজ ").unwrap(), "কাজ");
        for bad in ["", "#", "123", "#123", "two words", "a#b", "bug-", "#bug #x", "##bug"] {
            assert_eq!(parse_tag_argument(bad).unwrap_err().code(), ErrorCode::InvalidInput, "{bad:?}");
        }
    }

    #[test]
    fn a_zero_width_joiner_stays_inside_a_bangla_tag() {
        assert_eq!(tags("#র\u{200D}্যালো"), ["র\u{200d}্যালো"], "র‍্যালো is one tag, not 'র'");
        assert_eq!(tags("#a\u{200C}b"), ["a\u{200c}b"]);
        // The joiner is one UTF-16 unit: "#" + 7 units.
        assert_eq!(tag_ranges("#র\u{200D}্যালো"), [(0, 8, "র\u{200d}্যালো".to_owned())]);
        assert!(tags("#\u{200D}x").is_empty(), "a tag still starts with a letter");
    }

    #[test]
    fn decomposed_and_precomposed_spellings_are_one_tag() {
        assert_eq!(tags("#e\u{301}cole #\u{e9}cole #\u{c9}COLE"), ["\u{e9}cole"]);
        assert_eq!(parse_tag_argument("e\u{301}cole").unwrap(), "\u{e9}cole");
        // The range keeps the text as written: "#e" + U+0301 + "cole" is 7 units.
        assert_eq!(tag_ranges("#e\u{301}cole"), [(0, 7, "\u{e9}cole".to_owned())]);
    }

    #[test]
    fn a_note_at_the_size_limit_parses_in_one_pass() {
        let limit = crate::shared::text::MAX_TEXT_BYTES;
        let many = "#a ".repeat(limit / 3);
        assert_eq!(tags(&many), ["a"]);
        assert_eq!(tag_ranges(&many).len(), limit / 3);
        let dashes = format!("#a{}", "-".repeat(limit - 2));
        assert_eq!(tags(&dashes), ["a"], "one letter and 64 KiB of trailing dashes");
    }

    #[test]
    fn the_sql_function_filters_rows_and_is_null_safe() {
        let conn = Connection::open_in_memory().unwrap();
        register(&conn).unwrap();
        conn.execute_batch(
            "CREATE TABLE t (text TEXT);
             INSERT INTO t VALUES ('fix #bug today'), ('fix bug'), ('#Bug'), ('#bugfix'), (NULL);",
        )
        .unwrap();
        let count: i64 =
            conn.query_row("SELECT COUNT(*) FROM t WHERE rallo_has_tag(text, 'bug')", [], |row| row.get(0)).unwrap();
        assert_eq!(count, 2, "#bug and #Bug, not #bugfix, not a bare word, not NULL");
    }
}
