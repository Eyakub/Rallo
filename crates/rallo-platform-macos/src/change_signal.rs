use std::ffi::{CString, c_char};

unsafe extern "C" {
    // libSystem <notify.h>; returns NOTIFY_STATUS_OK (0) on success.
    fn notify_post(name: *const c_char) -> u32;
}

/// Posts a Darwin notification. Best effort: signals are hints, never
/// authority, so a failure only delays the app until its next reconciliation.
pub fn post(name: &str) -> bool {
    let Ok(name) = CString::new(name) else { return false };
    unsafe { notify_post(name.as_ptr()) == 0 }
}
