#!/bin/bash
# Installs, updates, or uninstalls Rallo from GitHub Releases, using only
# tools that ship with macOS (plus `gh`, if present, for a private repo).
#
#   install.sh                       install or update to the latest release
#   install.sh --version 0.2.0       a specific release
#   install.sh --system              /Applications instead of ~/Applications
#   install.sh --from DIR            use a release zip + SHA256SUMS already in DIR
#   install.sh --uninstall [--purge] remove the app and its terminal command;
#                                    --purge also deletes your notes (after
#                                    saving a JSON export to ~/Downloads)
#
# Downloads made by curl or gh are not quarantined, so the ad-hoc-signed app
# opens without a Gatekeeper prompt. Every download is checked against the
# release's SHA256SUMS and the bundle's signature before anything changes.
set -euo pipefail

REPO="${RALLO_REPO:-Eyakub/Rallo}"
BUNDLE_ID="com.razlio.rallo"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

version=""
dest_dir="$HOME/Applications"
mode=install
purge=false
from=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:?--version needs X.Y.Z}"; version="${version#v}"; shift ;;
    --system) dest_dir=/Applications ;;
    --from) from="${2:?--from needs a directory}"; shift ;;
    --uninstall) mode=uninstall ;;
    --purge) purge=true ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
app="$dest_dir/Rallo.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Quits every running copy of the Rallo at "$1" (SIGTERM is a normal quit).
quit_app() {
  local exe="$1/Contents/MacOS/Rallo" pids="" pid
  for pid in $(/bin/ps -axo pid=,comm= | awk -v exe="$exe" '$2 == exe { print $1 }'); do pids="$pids $pid"; done
  [ -z "$pids" ] && return 0
  say "Quitting Rallo…"
  kill -TERM $pids 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 $pids 2>/dev/null || return 0
    sleep 0.5
  done
  fail "Rallo didn't quit; quit it from its menu and run this again"
}

# --- Uninstall ----------------------------------------------------------------
if [ "$mode" = uninstall ]; then
  [ -d "$app" ] || fail "no Rallo at $app (use --system for /Applications)"
  cli="$app/Contents/Helpers/rallo"
  if $purge; then
    export_path="$HOME/Downloads/rallo-export-$(date +%Y%m%d-%H%M%S).json"
    "$cli" export --output "$export_path" >/dev/null && say "Saved a final export: $export_path"
  fi
  quit_app "$app"
  link="$HOME/.local/bin/rallo"
  for candidate in "$HOME/.local/bin/rallo" "$HOME/bin/rallo"; do
    target="$(readlink "$candidate" 2>/dev/null || true)"
    case "$target" in */Rallo.app/Contents/Helpers/rallo) rm -f "$candidate"; say "Removed $candidate" ;; esac
  done
  "$LSREGISTER" -u "$app" 2>/dev/null || true
  rm -rf "$app"
  say "Removed $app"
  if $purge; then
    rm -rf "$HOME/Library/Application Support/Razlio/Rallo"
    say "Deleted your Rallo notes and settings."
  else
    say "Your notes are kept in ~/Library/Application Support/Razlio/Rallo (use --purge to delete them)."
  fi
  say "If you had turned on Open at Login, remove Rallo under System Settings → General → Login Items."
  exit 0
fi

# --- Install / update ---------------------------------------------------------
[ "$(uname -m)" = arm64 ] || fail "Rallo releases are for Apple Silicon Macs"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Rallo needs macOS 14 or later"
mkdir -p "$dest_dir"
[ -w "$dest_dir" ] || fail "$dest_dir isn't writable (drop --system to install for just you)"

# A staging directory on the same volume, so the final move is a rename.
stage="$(mktemp -d "$dest_dir/.rallo-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [ -n "$from" ]; then
  cp "$from"/Rallo-*-macos-arm64.zip "$from/SHA256SUMS" "$stage/" 2>/dev/null ||
    fail "$from needs Rallo-<version>-macos-arm64.zip and SHA256SUMS"
elif command -v gh >/dev/null 2>&1 && gh auth token --hostname github.com >/dev/null 2>&1; then
  say "Downloading ${version:+v$version }from $REPO (gh)…"
  gh release download ${version:+"v$version"} --repo "$REPO" \
    --pattern 'Rallo-*-macos-arm64.zip' --pattern SHA256SUMS --dir "$stage" ||
    fail "download failed (is there a release, and can your gh account see $REPO?)"
else
  if [ -z "$version" ]; then
    curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest" \
      -o "$stage/latest.json" || fail "couldn't read the latest release of $REPO (a private repo needs \`gh auth login\`)"
    tag="$(plutil -extract tag_name raw "$stage/latest.json")"
    version="${tag#v}"
  fi
  say "Downloading v$version from $REPO…"
  base="https://github.com/$REPO/releases/download/v$version"
  curl -fsSL "$base/Rallo-$version-macos-arm64.zip" -o "$stage/Rallo-$version-macos-arm64.zip" || fail "download failed"
  curl -fsSL "$base/SHA256SUMS" -o "$stage/SHA256SUMS" || fail "download failed"
fi

zip="$(ls "$stage"/Rallo-*-macos-arm64.zip | head -1)"
(cd "$stage" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "checksum mismatch; nothing was changed"
ditto -x -k "$zip" "$stage/unpacked"
new="$stage/unpacked/Rallo.app"
[ -d "$new" ] || fail "the release doesn't contain Rallo.app"
[ "$(plutil -extract CFBundleIdentifier raw "$new/Contents/Info.plist")" = "$BUNDLE_ID" ] || fail "unexpected bundle identifier"
codesign --verify --deep --strict "$new" 2>/dev/null || fail "the app's signature doesn't verify; nothing was changed"
new_version="$(plutil -extract CFBundleShortVersionString raw "$new/Contents/Info.plist")"
xattr -dr com.apple.quarantine "$new" 2>/dev/null || true

updating=false
if [ -d "$app" ]; then
  updating=true
  old_version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || echo unknown)"
  # A newer schema is recoverable from this snapshot.
  "$app/Contents/Helpers/rallo" backup >/dev/null 2>&1 && say "Backed up your notes first."
  quit_app "$app"
  mv "$app" "$stage/Rallo.app.previous"
fi
if ! mv "$new" "$app"; then
  $updating && mv "$stage/Rallo.app.previous" "$app"
  fail "couldn't install into $dest_dir; the previous version is back in place"
fi
"$LSREGISTER" -f "$app" 2>/dev/null || true

"$app/Contents/Helpers/rallo" setup terminal || say "(The terminal command wasn't changed; run \`$app/Contents/Helpers/rallo setup terminal\` for details.)"

if [ -n "${RALLO_INSTALL_NO_LAUNCH:-}" ]; then
  say "Installed Rallo $new_version in $dest_dir (not launched)."
elif $updating; then
  # Background launch keeps the pet's shown/hidden choice.
  open -g -n -a "$app" --args --background
  say "Updated Rallo $old_version → $new_version."
else
  open "$app"
  say "Installed Rallo $new_version in $dest_dir. Look for the paw in the menu bar."
fi
