#!/usr/bin/env bash
# Generates Swift bindings for rallo-ffi from the compiled static library.
# Output: apps/macos/Rallo/Generated/ (gitignored; never edit by hand).
# Files are replaced only when their content changes, so Xcode does not
# recompile Swift on every build.
set -euo pipefail
source "$(dirname "$0")/env.sh"

cargo build --quiet --release -p rallo-ffi
cargo build --quiet --release -p rallo-ffi --features bindgen --bin uniffi-bindgen

out="$REPO_ROOT/apps/macos/Rallo/Generated"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
"$CARGO_TARGET_DIR/release/uniffi-bindgen" --swift-sources --headers --modulemap \
  --module-name rallo_ffiFFI --modulemap-filename module.modulemap \
  "$CARGO_TARGET_DIR/release/librallo_ffi.a" "$staging" >/dev/null

# Xcode's ld64 misses symbols through the archive index written by Rust's
# LLVM archiver (see docs/decisions/0001-macos-feasibility.md). Stage a copy
# with an index rebuilt by Xcode's ranlib; Xcode links only this copy.
lib_out="$REPO_ROOT/build/rust/lib"
mkdir -p "$lib_out"
if ! cmp -s "$CARGO_TARGET_DIR/release/librallo_ffi.a" "$lib_out/.librallo_ffi.source.a"; then
  cp "$CARGO_TARGET_DIR/release/librallo_ffi.a" "$lib_out/.librallo_ffi.source.a"
  cp "$CARGO_TARGET_DIR/release/librallo_ffi.a" "$lib_out/librallo_ffi.a"
  xcrun ranlib "$lib_out/librallo_ffi.a"
fi

mkdir -p "$out"
for file in "$staging"/*; do
  name="$(basename "$file")"
  cmp -s "$file" "$out/$name" || cp "$file" "$out/$name"
done
