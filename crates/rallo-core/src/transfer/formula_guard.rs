//! CSV formula-injection guard (0004). A text cell that a spreadsheet would
//! read as a formula or command (it starts with `=`, `+`, `-`, `@`, tab, or
//! CR) gets a leading `'` on export, and import removes exactly that `'`.
//!
//! To stay lossless for every text, a note that already starts with
//! apostrophes followed by a trigger is guarded too (`'=x` exports as
//! `''=x`), so import can always tell the guard from the note's own `'`.

const TRIGGERS: [char; 6] = ['=', '+', '-', '@', '\t', '\r'];

fn needs_guard(text: &str) -> bool {
    text.trim_start_matches('\'').starts_with(TRIGGERS)
}

/// Export side: prefixes `'` when a spreadsheet would otherwise interpret
/// the cell.
pub(crate) fn apply_formula_guard(text: &str) -> String {
    if needs_guard(text) { format!("'{text}") } else { text.to_owned() }
}

/// Import side: the exact inverse of `apply_formula_guard`.
pub(crate) fn strip_formula_guard(text: &str) -> String {
    match text.strip_prefix('\'') {
        Some(rest) if needs_guard(rest) => rest.to_owned(),
        _ => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guards_every_trigger_and_round_trips_losslessly() {
        for text in ["=SUM(A1)", "+1", "-1", "@cmd", "\tindented", "\rcr"] {
            assert_eq!(apply_formula_guard(text), format!("'{text}"));
        }
        for text in [
            "=SUM(A1)",
            "+1",
            "-1",
            "@cmd",
            "\tindented",
            "\rcr",
            "'=already quoted",
            "''+two",
            "'hello",
            "hello",
            "'",
            "''",
            "don't",
        ] {
            assert_eq!(strip_formula_guard(&apply_formula_guard(text)), text, "{text:?}");
        }
        assert_eq!(apply_formula_guard("'hello"), "'hello", "an ordinary apostrophe is left alone");
    }
}
