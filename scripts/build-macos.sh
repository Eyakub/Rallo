#!/usr/bin/env bash
# Builds Rallo.app (Release) with its embedded CLI.
#   scripts/build-macos.sh            build into build/DerivedData
#   scripts/build-macos.sh --install  also install to ~/Applications/Rallo.app
set -euo pipefail
source "$(dirname "$0")/env.sh"

"$REPO_ROOT/scripts/build-rust.sh"
command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
(cd "$REPO_ROOT/apps/macos" && xcodegen generate --quiet)

xcodebuild -project "$REPO_ROOT/apps/macos/Rallo.xcodeproj" -scheme Rallo -configuration Release \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" -quiet build

app="$REPO_ROOT/build/DerivedData/Build/Products/Release/Rallo.app"
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
