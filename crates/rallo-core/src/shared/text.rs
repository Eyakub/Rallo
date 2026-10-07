use caseless::default_case_fold_str;
use unicode_normalization::UnicodeNormalization;

use super::errors::{CoreError, CoreResult, ErrorCode};

/// Maximum stored note size, measured in UTF-8 bytes.
pub const MAX_TEXT_BYTES: usize = 64 * 1024;

/// Validates note text at an external boundary. Stored text is kept verbatim.
pub fn validate_note_text(text: &str) -> CoreResult<&str> {
    if text.trim().is_empty() {
        return Err(CoreError::invalid(ErrorCode::TextEmpty, "a note needs text or an image"));
    }
    if text.len() > MAX_TEXT_BYTES {
        return Err(CoreError::invalid(
            ErrorCode::TextTooLong,
            format!("note text is {} bytes; the limit is {MAX_TEXT_BYTES} bytes of UTF-8", text.len()),
        ));
    }
    Ok(text)
}

/// 0018: a note needs text or at least one image. With images, blank text is
/// stored as "".
pub fn validate_note_content(text: &str, has_images: bool) -> CoreResult<&str> {
    if has_images && text.trim().is_empty() {
        return Ok("");
    }
    validate_note_text(text)
}

/// Size only: for edits, where whether blank text is allowed depends on the
/// note's images.
pub fn validate_note_length(text: &str) -> CoreResult<&str> {
    if text.trim().is_empty() {
        return Ok("");
    }
    validate_note_text(text)
}

/// Normalised form used for exact-text selection and literal search:
/// outer whitespace trimmed, NFC, Unicode default case folding, NFC again
/// (folding can denormalise). Internal whitespace, punctuation, accents, and
/// word order are preserved.
pub fn match_key(text: &str) -> String {
    let composed: String = text.trim().nfc().collect();
    default_case_fold_str(&composed).nfc().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn match_key_folds_case_and_composes() {
        assert_eq!(match_key("  Review Deployment \n"), "review deployment");
        // "é" precomposed vs "e" + combining acute.
        assert_eq!(match_key("Caf\u{e9}"), match_key("Cafe\u{301}"));
        assert_eq!(match_key("STRASSE"), match_key("straße"));
    }

    #[test]
    fn match_key_preserves_inner_structure() {
        assert_ne!(match_key("review  deployment"), match_key("review deployment"));
        assert_ne!(match_key("deployment review"), match_key("review deployment"));
        assert_ne!(match_key("resume"), match_key("résumé"));
        assert_ne!(match_key("review, deployment"), match_key("review deployment"));
    }

    #[test]
    fn validation_bounds() {
        assert_eq!(validate_note_text(" \n\t ").unwrap_err().code(), ErrorCode::TextEmpty);
        assert!(validate_note_text(&"a".repeat(MAX_TEXT_BYTES)).is_ok());
        assert_eq!(validate_note_text(&"a".repeat(MAX_TEXT_BYTES + 1)).unwrap_err().code(), ErrorCode::TextTooLong);
        assert_eq!(validate_note_text("line one\n\n  line two").unwrap(), "line one\n\n  line two");
    }
}
