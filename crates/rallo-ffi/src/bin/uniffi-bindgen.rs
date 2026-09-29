//! Swift binding generator pinned to the workspace's UniFFI version.
//! Invoked by scripts/generate-bindings.sh.

fn main() {
    uniffi::uniffi_bindgen_swift()
}
