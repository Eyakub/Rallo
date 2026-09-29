#!/usr/bin/env bash
# Builds the Rust static library, Swift bindings, and the rallo CLI.
# Invoked by the Xcode pre-build phase and by build-macos.sh.
set -euo pipefail
source "$(dirname "$0")/env.sh"

"$REPO_ROOT/scripts/generate-bindings.sh"
cargo build --quiet --release -p rallo-cli
