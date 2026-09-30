//! `--request-id` bookkeeping (0003 §7): syntax validation, canonical
//! fingerprints of a command's original inputs, and the `request_receipts`
//! table accessed inside the caller's write transaction.

use rusqlite::{OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use super::errors::{CoreError, CoreResult, ErrorCode};

/// Maximum length of a caller-supplied `--request-id`.
pub const MAX_REQUEST_ID_LEN: usize = 128;

/// Validates request-id syntax: 1-128 characters of `[A-Za-z0-9._:-]`.
pub fn validate_request_id(request_id: &str) -> CoreResult<()> {
    let valid = !request_id.is_empty()
        && request_id.len() <= MAX_REQUEST_ID_LEN
        && request_id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'));
    if valid {
        Ok(())
    } else {
        Err(CoreError::invalid(ErrorCode::InvalidInput, "request id must be 1-128 characters of [A-Za-z0-9._:-]"))
    }
}

/// Canonical JSON fingerprint of a command's original inputs. Deterministic
/// because a derived `Serialize` struct always emits its fields in
/// declaration order.
pub fn fingerprint(inputs: &impl Serialize) -> String {
    serde_json::to_string(inputs).expect("idempotency inputs serialize")
}

/// A previously committed mutation, keyed by request id.
pub(crate) struct Receipt {
    pub fingerprint: String,
    pub item_id: Option<Uuid>,
    pub result: Value,
}

pub(crate) fn lookup(tx: &Transaction<'_>, request_id: &str) -> CoreResult<Option<Receipt>> {
    let row: Option<(String, Option<String>, String)> = tx
        .query_row(
            "SELECT fingerprint, item_id, result FROM request_receipts WHERE request_id = ?1",
            [request_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let Some((fingerprint, item_id, result)) = row else { return Ok(None) };
    let item_id = item_id
        .map(|id| Uuid::parse_str(&id))
        .transpose()
        .map_err(|e| CoreError::storage(format!("stored receipt has an invalid item id: {e}")))?;
    let result: Value = serde_json::from_str(&result)
        .map_err(|e| CoreError::storage(format!("stored receipt has invalid result JSON: {e}")))?;
    Ok(Some(Receipt { fingerprint, item_id, result }))
}

/// Records a receipt in the same transaction as the mutation it guards,
/// including no-ops. Failures must not call this: they commit nothing.
pub(crate) fn insert(
    tx: &Transaction<'_>,
    request_id: &str,
    fingerprint: &str,
    command_kind: &str,
    item_id: Option<Uuid>,
    result: &Value,
    now_ms: i64,
) -> CoreResult<()> {
    tx.execute(
        "INSERT INTO request_receipts (request_id, fingerprint, command_kind, item_id, result, created_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![request_id, fingerprint, command_kind, item_id.map(|id| id.to_string()), result.to_string(), now_ms],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_id_syntax_bounds() {
        assert!(validate_request_id("a").is_ok());
        assert!(validate_request_id(&"a".repeat(MAX_REQUEST_ID_LEN)).is_ok());
        assert!(validate_request_id("a.b_c:d-9").is_ok());
        assert_eq!(validate_request_id("").unwrap_err().code(), ErrorCode::InvalidInput);
        assert!(validate_request_id(&"a".repeat(MAX_REQUEST_ID_LEN + 1)).is_err());
        assert!(validate_request_id("has space").is_err());
        assert!(validate_request_id("emoji🙂").is_err());
    }

    #[test]
    fn fingerprint_is_order_independent_of_call_site_but_field_stable() {
        #[derive(Serialize)]
        struct Inputs<'a> {
            command: &'static str,
            selector: &'a str,
        }
        let a = fingerprint(&Inputs { command: "delete", selector: "abc123" });
        let b = fingerprint(&Inputs { command: "delete", selector: "abc123" });
        let c = fingerprint(&Inputs { command: "delete", selector: "xyz789" });
        assert_eq!(a, b);
        assert_ne!(a, c);
    }
}
