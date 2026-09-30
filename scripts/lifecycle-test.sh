#!/usr/bin/env bash
# Install/upgrade/uninstall lifecycle test of release assets (spec M5), run in
# a scratch HOME whose path contains spaces. It never touches the real HOME,
# data directory, or /Applications, and never launches the app.
#
#   scripts/lifecycle-test.sh                       the latest GitHub release (gh)
#   scripts/lifecycle-test.sh DIR                   Rallo-<v>-macos-arm64.zip + SHA256SUMS
#                                                   in DIR (e.g. release.sh's build/dist/X.Y.Z)
#   scripts/lifecycle-test.sh DIR --upgrade-from OLD_DIR
#                                                   install OLD_DIR first, then upgrade to DIR
#
# Covers: fresh install, moved app and stale terminal link, reinstall/upgrade
# over an older schema (pre-migration snapshot), CLI older than the database,
# an interrupted migration recovered from the pre-update backup, and
# `install.sh --uninstall [--purge]`. Older/newer stores are made with
# /usr/bin/sqlite3, so no Rust toolchain is needed.
set -euo pipefail

new="" old=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade-from) old="$(cd "${2:?--upgrade-from needs a directory}" && pwd)"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) new="$(cd "$1" && pwd)" ;;
  esac
  shift
done
cd "$(dirname "$0")/.."
repo_root="$PWD"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Canonical, like a real HOME: the CLI links and compares resolved paths.
root="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rallo lifecycle.XXXXXX")" && pwd -P)"
if [ -z "$new" ]; then
  gh release download --repo "${RALLO_REPO:-Eyakub/Rallo}" \
    --pattern 'Rallo-*-macos-arm64.zip' --pattern SHA256SUMS --dir "$root/release"
  new="$root/release"
fi
version_in() { basename "$(ls "$1"/Rallo-*-macos-arm64.zip | head -1)" | sed -E 's/^Rallo-(.*)-macos-arm64\.zip$/\1/'; }
new_v="$(version_in "$new")"

export HOME="$root/home with spaces"
export RALLO_DATA_DIR="$HOME/Library/Application Support/Razlio/Rallo"
# install.sh's `open` would start the app with the real HOME's data directory.
export RALLO_INSTALL_NO_LAUNCH=1
export PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset RALLO_APP_PATH
mkdir -p "$HOME/Desktop" "$HOME/Downloads"
app="$HOME/Applications/Rallo.app"
cli="$app/Contents/Helpers/rallo"
db="$RALLO_DATA_DIR/rallo.sqlite3"
install=(bash "$repo_root/scripts/install.sh")

passed=0 failed=0
out="$root/last-output"
cleanup() {
  local status=$?
  # A registered scratch copy could receive the installed app's notification clicks.
  "$lsregister" -u "$app" 2>/dev/null || true
  pkill -TERM -f "$root/" 2>/dev/null || true
  if [ "$status" -eq 0 ]; then rm -rf "$root"; else echo "kept $root"; fi
}
trap cleanup EXIT

ok() { printf 'ok    %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
# Runs a command, saving its output in $out, and checks its exit status.
expect_exit() {
  local want="$1" name="$2" got=0; shift 2
  "$@" >"$out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name (exit $got, want $want)"; sed 's/^/      /' "$out"; fi
}
said() { grep -q -- "$1" "$out"; }
fails() { ! "$@"; }
schema() { sqlite3 "$1" "PRAGMA user_version"; }
count_items() { sqlite3 "$1" "SELECT count(*) FROM items"; }
notes_ok() { local list; list="$("$1" list --json)" && grep -q '"first note"' <<<"$list" && grep -q '"second note"' <<<"$list"; }
# Undoes 0002_reminders.sql and 0003_agent_sessions.sql: the store as a
# schema v1 build left it.
downgrade_to_v1() {
  sqlite3 "$db" "DROP TABLE IF EXISTS agent_sessions; DELETE FROM metadata WHERE key = 'agents.state_seq';
    DROP TABLE notification_observations; DROP TABLE notification_intents; DROP TABLE reminders;
    DROP TABLE request_receipts; DROP INDEX items_match_key; PRAGMA user_version = 1;"
}

echo "== scratch HOME: $HOME"
echo "== release under test: $new_v${old:+ (upgrading from $(version_in "$old"))}"

echo "-- fresh install"
expect_exit 0 "install into a path with spaces" "${install[@]}" --from "${old:-$new}"
check "app installed in ~/Applications" test -x "$cli"
check "terminal command links the embedded CLI" test "$(readlink "$HOME/.local/bin/rallo")" = "$cli"
check "no staging directory left behind" fails compgen -G "$HOME/Applications/.rallo-install.*"
# Hidden, so later writes never background-launch the app.
expect_exit 0 "rallo hide" rallo hide
expect_exit 0 "save a note through the terminal link" rallo note "first note"
expect_exit 0 "save a second note" rallo note "second note"
expect_exit 0 "doctor after a fresh install" rallo doctor

echo "-- moved app"
mv "$app" "$HOME/Desktop/Rallo.app"
moved_cli="$HOME/Desktop/Rallo.app/Contents/Helpers/rallo"
check "terminal link breaks while the app is moved" fails rallo --version
expect_exit 0 "doctor still runs from the moved app" "$moved_cli" doctor
check "doctor says the moved app isn't an installed copy" said "not an installed copy"
expect_exit 2 "setup terminal refuses a moved app" "$moved_cli" setup terminal
check "notes readable from the moved app" notes_ok "$moved_cli"
mv "$HOME/Desktop/Rallo.app" "$app"
check "terminal link works again once moved back" rallo --version
# The state after moving the app between /Applications and ~/Applications.
ln -sfn /Applications/Rallo.app/Contents/Helpers/rallo "$HOME/.local/bin/rallo"
expect_exit 1 "doctor flags a link to a moved or deleted app" "$cli" doctor
check "doctor names the stale link" said "points at a moved or deleted app"
expect_exit 0 "setup terminal repairs the link" "$cli" setup terminal --json
check "setup reports it as repaired" said '"status":"repaired"'
expect_exit 0 "doctor clean after the repair" rallo doctor

echo "-- reinstall/upgrade over a schema v1 store"
downgrade_to_v1
expect_exit 0 "install.sh over the installed app" "${install[@]}" --from "$new"
check "install.sh backed up the notes first" said "Backed up your notes first."
check "app is now $new_v" test "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$new_v"
expect_exit 0 "rallo --version" rallo --version --json
check "embedded CLI reports $new_v" said "\"cli_version\":\"$new_v\""
# The schema of the release under test, not of the --upgrade-from one
# installed first. The old CLI's pre-update backup may already have migrated
# part of the way; the new CLI's first open finishes it.
supported="$(rallo --version --json | sed -E 's/.*"database_schema_version":([0-9]+).*/\1/')"
expect_exit 0 "the new CLI opens the store" rallo list
check "store migrated to schema $supported" test "$(schema "$db")" = "$supported"
pre_migration="$(ls -t "$RALLO_DATA_DIR"/backups/pre-migration-v1-*.sqlite3 2>/dev/null | head -1)"
check "pre-migration snapshot is the v1 store" test "$(schema "$pre_migration")" = 1
check "pre-migration snapshot has both notes" test "$(count_items "$pre_migration")" = 2
pre_update="$(ls -t "$RALLO_DATA_DIR"/backups/manual-*.sqlite3 2>/dev/null | head -1)"
check "pre-update backup exists" test -f "$pre_update"
check "notes survive the reinstall" notes_ok rallo
check "no staging directory left behind" fails compgen -G "$HOME/Applications/.rallo-install.*"

echo "-- database newer than the CLI"
sqlite3 "$db" "PRAGMA user_version = $((supported + 1))"
before="$(shasum "$db")"
expect_exit 7 "a write refuses the newer schema" rallo note "must not be saved" --json
check "error is INCOMPATIBLE_SCHEMA" said '"code":"INCOMPATIBLE_SCHEMA"'
expect_exit 7 "a read refuses it too" rallo list
expect_exit 1 "doctor reports it as a problem" rallo doctor
check "doctor says the schema is newer" said "is newer than this build supports"
check "the newer store is byte-identical" test "$(shasum "$db")" = "$before"
sqlite3 "$db" "PRAGMA user_version = $supported"
check "store usable again at its own version" notes_ok rallo

echo "-- interrupted migration, recovered from the pre-update backup"
downgrade_to_v1
# A table 0002 creates third: its first statements run, then it fails before
# commit, as a crash mid-migration would.
sqlite3 "$db" "CREATE TABLE notification_observations (x)"
expect_exit 5 "the failing migration reports a storage error" rallo list
check "store is still schema v1" test "$(schema "$db")" = 1
check "partial migration rolled back (no reminders table)" \
  test "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'reminders'")" = 0
check "notes still in the store" test "$(count_items "$db")" = 2
# docs/backup-and-restore.md, "Restoring from a rallo backup snapshot".
(
  cd "$RALLO_DATA_DIR"
  mkdir -p quarantine
  mv rallo.sqlite3 rallo.sqlite3-wal rallo.sqlite3-shm quarantine/ 2>/dev/null || true
  cp "$pre_update" rallo.sqlite3
  chmod 600 rallo.sqlite3
)
expect_exit 0 "doctor clean after restoring the pre-update backup" rallo doctor
check "restored notes" notes_ok rallo

echo "-- uninstall"
mkdir -p "$HOME/bin"
ln -s /usr/bin/true "$HOME/bin/rallo"
expect_exit 0 "install.sh --uninstall" "${install[@]}" --uninstall
check "app removed" test ! -e "$app"
check "Rallo's terminal link removed" test ! -L "$HOME/.local/bin/rallo"
check "another tool's rallo left alone" test "$(readlink "$HOME/bin/rallo")" = /usr/bin/true
check "notes kept" test -f "$db"
expect_exit 0 "reinstall after uninstall" "${install[@]}" --from "$new"
check "notes back after reinstalling" notes_ok rallo
# No final export (here: a store this CLI can't read) means nothing is deleted.
sqlite3 "$db" "PRAGMA user_version = $((supported + 1))"
expect_exit 1 "--purge refuses when it can't save a final export" "${install[@]}" --uninstall --purge
check "notes and app kept" test -f "$db" -a -x "$cli"
sqlite3 "$db" "PRAGMA user_version = $supported"
expect_exit 0 "install.sh --uninstall --purge" "${install[@]}" --uninstall --purge
export_file="$(ls "$HOME"/Downloads/rallo-export-*.json 2>/dev/null | head -1)"
check "purge saved a final export with the notes" grep -q '"first note"' "$export_file"
check "purge deleted the data directory" test ! -e "$RALLO_DATA_DIR"
check "app removed" test ! -e "$app"
check "terminal link removed" test ! -L "$HOME/.local/bin/rallo"

echo "== $passed passed, $failed failed"
[ "$failed" -eq 0 ]
