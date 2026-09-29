use uuid::Uuid;

/// Crockford Base32 alphabet: case-insensitive and free of I, L, O, U.
const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Length of the full Base32 key for a 128-bit UUID (130 bits, 2 zero pad bits).
pub const SHORT_KEY_LEN: usize = 26;

/// Minimum length of a displayed or accepted ID prefix.
pub const MIN_PREFIX_LEN: usize = 6;

pub fn new_id() -> Uuid {
    // v4, not v7: display prefixes must be random, not a shared timestamp.
    Uuid::new_v4()
}

/// Full Crockford Base32 encoding of a UUID, most significant bits first, so
/// display prefixes are prefixes of this key.
pub fn short_key(id: &Uuid) -> String {
    let value = id.as_u128();
    (0..SHORT_KEY_LEN)
        .map(|i| {
            let end = 5 * (i + 1);
            // The final group has 3 real bits followed by 2 zero pad bits.
            let group = if end <= 128 { value >> (128 - end) } else { value << (end - 128) };
            ALPHABET[(group & 0x1f) as usize] as char
        })
        .collect()
}

/// Canonicalises user-typed Base32 input (case-insensitive, Crockford aliases).
/// Returns `None` if the input contains characters outside the alphabet.
pub fn normalize_prefix(input: &str) -> Option<String> {
    input
        .chars()
        .map(|c| match c.to_ascii_uppercase() {
            'I' | 'L' => Some('1'),
            'O' => Some('0'),
            upper if ALPHABET.contains(&(upper as u8)) && upper.is_ascii() => Some(upper),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_key_orders_like_uuid_bits() {
        let zero = Uuid::from_u128(0);
        let max = Uuid::from_u128(u128::MAX);
        assert_eq!(short_key(&zero), "0".repeat(SHORT_KEY_LEN));
        assert_eq!(short_key(&max), format!("{}W", "Z".repeat(SHORT_KEY_LEN - 1)));
        let a = Uuid::from_u128(1 << 100);
        let b = Uuid::from_u128(1 << 101);
        assert!(short_key(&a) < short_key(&b));
    }

    #[test]
    fn prefix_normalisation_is_case_insensitive_with_aliases() {
        assert_eq!(normalize_prefix("r7k2m9").as_deref(), Some("R7K2M9"));
        assert_eq!(normalize_prefix("OIL").as_deref(), Some("011"));
        assert_eq!(normalize_prefix("R7K-2M"), None);
        assert_eq!(normalize_prefix("U"), None);
    }
}
