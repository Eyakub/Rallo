#!/usr/bin/env bash
# Builds Rallo.app (Release) with its embedded CLI.
#   scripts/build-macos.sh            build into build/DerivedData.noindex
#   scripts/build-macos.sh --install  also install to ~/Applications/Rallo.app
set -euo pipefail
source "$(dirname "$0")/env.sh"

"$REPO_ROOT/scripts/build-rust.sh"
command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
(cd "$REPO_ROOT/apps/macos" && xcodegen generate --quiet)

# Spotlight skips *.noindex folders, so it never offers this build as "Rallo"
# in place of the installed copy (a build outside Applications greys out
# Open at Login and Uninstall).
xcodebuild -project "$REPO_ROOT/apps/macos/Rallo.xcodeproj" -scheme Rallo -configuration Release \
  -derivedDataPath "$REPO_ROOT/build/DerivedData.noindex" -quiet build

app="$REPO_ROOT/build/DerivedData.noindex/Build/Products/Release/Rallo.app"

# Strip local symbols (about 3 MB, mostly whisper.cpp), then sign: with Rallo's
# own certificate when it's in the Keychain, so macOS keeps permissions and
# Keychain access across updates (docs/distribution.md, "Signing"), else
# ad-hoc, which is fine for development; scripts/release.sh refuses it.
# Helper first, then the app.
strip -x "$app/Contents/MacOS/Rallo"
identity="${RALLO_SIGN_IDENTITY:-Rallo Self-Signed}"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
  echo "note: no \"$identity\" certificate in the Keychain; signing ad-hoc" >&2
  identity="-"
fi
for code in "$app/Contents/Helpers/rallo" "$app"; do
  codesign --force --preserve-metadata=identifier,entitlements,flags,runtime --timestamp=none \
    --sign "$identity" "$code" 2>/dev/null
done
echo "signed: $identity"
echo "built: $app"

if [ "${1:-}" = "--install" ]; then
  dest="$HOME/Applications/Rallo.app"
  # The app treats SIGTERM as a normal quit; wait so the bundle is not
  # replaced underneath a running instance.
  pkill -TERM -f "$dest/Contents/MacOS/Rallo" || true
  for _ in $(seq 1 50); do pgrep -qf "$dest/Contents/MacOS/Rallo" || break; sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$dest"
  ditto "$app" "$dest"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
  echo "installed: $dest"
fi
