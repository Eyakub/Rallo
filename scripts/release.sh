#!/usr/bin/env bash
# Builds a release of Rallo on this Mac and, only with --publish, tags it and
# uploads it to GitHub Releases (docs/distribution.md).
#
#   scripts/release.sh 0.2.0             # build + package + verify (dry run)
#   scripts/release.sh 0.2.0 --publish   # also tag, push the tag, gh release create
#
# Assets (the contract `rallo update` and scripts/install.sh rely on):
#   Rallo-<version>-macos-arm64.zip   (ditto --keepParent: zip root is Rallo.app)
#   SHA256SUMS                        (shasum -a 256 format)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

version="${1:?usage: scripts/release.sh X.Y.Z [--publish]}"
publish=false
[[ "${2:-}" == "--publish" ]] && publish=true
tag="v$version"
repo="${RALLO_REPO:-Eyakub/Rallo}"
dist="build/dist/$version"
asset="Rallo-$version-macos-arm64.zip"
app="build/DerivedData/Build/Products/Release/Rallo.app"

fail() { echo "error: $*" >&2; exit 1; }
# A stalled SSH connection to GitHub otherwise hangs the tag check forever.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3}"

# --- Preconditions ---------------------------------------------------------
[[ "$(uname -m)" == arm64 ]] || fail "release builds are Apple Silicon only (this Mac is $(uname -m))"
[[ "$(git branch --show-current)" == master ]] || fail "release from master"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "commit or stash tracked changes first"
cargo_version="$(sed -nE '/^\[workspace.package\]/,/^\[/ s/^version = "([^"]+)"/\1/p' Cargo.toml)"
app_version="$(sed -nE 's/^ *MARKETING_VERSION: *//p' apps/macos/project.yml)"
[[ "$cargo_version" == "$version" && "$app_version" == "$version" ]] ||
  fail "versions are Cargo $cargo_version / app $app_version; run scripts/set-version.sh $version and commit"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  fail "tag $tag already exists"
fi

# --- Gates -----------------------------------------------------------------
echo "==> checks"
# macOS's bash 3.2 in a UTF-8 locale reads a $VAR directly followed by "…" as one
# longer name (install.sh died with "REPO…: unbound variable"): brace those.
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' scripts/*.sh; then
  fail "a \$VAR is followed by a non-ASCII character; write \${VAR}"
fi
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --quiet -- -D warnings
cargo test --workspace --quiet 2>&1 | grep -E "test result|FAILED|panicked" | grep -v " 0 passed" || true
cargo test --workspace --quiet >/dev/null 2>&1 || fail "cargo test failed"
(cd apps/macos && xcodegen generate --quiet)
xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release \
  -derivedDataPath build/DerivedData test -quiet >/dev/null || fail "Swift tests failed"

# --- Build and verify --------------------------------------------------------
echo "==> build"
scripts/build-macos.sh >/dev/null
# A build product LaunchServices remembers could receive notification clicks
# instead of the installed copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app" 2>/dev/null || true
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]] || fail "app version mismatch"
[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == com.razlio.rallo ]] || fail "bundle id mismatch"
"$app/Contents/Helpers/rallo" --version --json | grep -q "\"cli_version\":\"$version\"" || fail "CLI version mismatch"
codesign --verify --deep --strict "$app" || fail "codesign verification failed"
# Signed with Rallo's certificate, and the pins that updates check match it.
requirement="$(sed -nE "s/^SIGNING_REQUIREMENT='(.*)'$/\1/p" scripts/install.sh)"
[[ -n "$requirement" ]] || fail "no SIGNING_REQUIREMENT in scripts/install.sh"
grep -qF "$requirement" crates/rallo-platform-macos/src/update.rs ||
  fail "scripts/install.sh and update.rs pin different certificates"
codesign --verify -R="$requirement" "$app" ||
  fail "not signed with Rallo's certificate (is \"Rallo Self-Signed\" in the Keychain?)"
# get-task-allow would let any same-user process attach and use Rallo's grants.
for bin in "$app" "$app/Contents/Helpers/rallo"; do
  entitlements=$(codesign -d --entitlements - --xml "$bin" 2>/dev/null) || fail "can't read $bin's entitlements"
  case $entitlements in *get-task-allow*) fail "$bin carries get-task-allow" ;; esac
done
if otool -L "$app/Contents/MacOS/Rallo" "$app/Contents/Helpers/rallo" | tail -n +2 | awk '{print $1}' |
  grep -vE '^(/usr/lib/|/System/Library/|.*:$)' | grep -q .; then
  fail "a binary links something outside the OS"
fi

# --- Package ---------------------------------------------------------------
echo "==> package"
rm -rf "$dist"; mkdir -p "$dist"
ditto -c -k --keepParent "$app" "$dist/$asset"
(cd "$dist" && shasum -a 256 "$asset" > SHA256SUMS)
previous="$(git describe --tags --abbrev=0 2>/dev/null || true)"
{
  echo "Rallo $version for Apple Silicon Macs (macOS 14 or later)."
  echo
  echo "Install or update: see docs/distribution.md. Already installed? Run \`rallo update\`."
  echo
  echo "Signed with Rallo's own certificate, not notarized. Installed with \`rallo update\` or"
  echo "scripts/install.sh it opens normally; a zip downloaded in a browser needs"
  echo "System Settings → Privacy & Security → Open Anyway once."
  echo
  # Hand-written highlights, if this version has them.
  if [ -f "docs/releases/$version.md" ]; then cat "docs/releases/$version.md"; echo; fi
  echo "## Changes"
  git log --no-merges --format='- %s' ${previous:+"$previous..HEAD"}
} > "$dist/NOTES.md"
cat "$dist/SHA256SUMS"
echo "packaged $dist/$asset ($(du -h "$dist/$asset" | cut -f1))"

if ! $publish; then
  echo "dry run: nothing tagged or uploaded. Re-run with --publish to release $tag to $repo."
  exit 0
fi

# --- Publish (explicit only) ------------------------------------------------
echo "==> publish $tag to $repo"
git tag -a "$tag" -m "Rallo $version"
git push origin "$tag"
gh release create "$tag" "$dist/$asset" "$dist/SHA256SUMS" --repo "$repo" \
  --title "Rallo $version" --notes-file "$dist/NOTES.md"
echo "released: $(gh release view "$tag" --repo "$repo" --json url -q .url)"
