use std::path::Path;

/// Darwin notification name used as a best-effort "something changed" hint for
/// one data directory. Carries no note text; receivers re-read the revision.
pub fn change_signal_name(data_dir: &Path) -> String {
    format!("com.razlio.rallo.changed.{:016x}", fnv1a64(data_dir.as_os_str().as_encoded_bytes()))
}

/// Hint that the user explicitly asked to see the pet (e.g. `rallo show`).
pub fn show_signal_name(data_dir: &Path) -> String {
    format!("com.razlio.rallo.show.{:016x}", fnv1a64(data_dir.as_os_str().as_encoded_bytes()))
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3))
}

/// Developer diagnostic: asks the running app to write a window report.
pub fn diagnostics_signal_name(data_dir: &Path) -> String {
    format!("com.razlio.rallo.diagnose.{:016x}", fnv1a64(data_dir.as_os_str().as_encoded_bytes()))
}
