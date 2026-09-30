#!/usr/bin/env bash
# Sets the one product version everywhere it lives: the Cargo workspace
# (CLI/core, reported by `rallo --version`) and the app's MARKETING_VERSION,
# and bumps the app's build number.
#   scripts/set-version.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

version="${1:?usage: scripts/set-version.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be X.Y.Z" >&2; exit 2; }

sed -i '' -E "/^\[workspace.package\]/,/^\[/ s/^version = \"[^\"]+\"/version = \"$version\"/" Cargo.toml
sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1$version/" apps/macos/project.yml
build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' apps/macos/project.yml)"
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$((build + 1))\"/" apps/macos/project.yml
cargo update --workspace --offline --quiet

echo "version $version (build $((build + 1))):"
grep -nE '^version = ' Cargo.toml | head -1
grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' apps/macos/project.yml
