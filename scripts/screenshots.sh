#!/usr/bin/env bash
# Regenerates the README screenshots in docs/images from a throwaway demo
# instance of the installed app: sample notes, one waiting agent and one
# ClickUp message (both fake), captured in Light and Dark Mode. Each window
# is captured on its own, so nothing else on screen ends up in an image.
#
#   scripts/screenshots.sh
#
# Needs Screen Recording permission for the terminal running it. Never
# touches your notes, your ClickUp token (a --data-dir instance doesn't use
# it), your pet, or your system appearance (the demo sets its own).
set -euo pipefail
cd "$(dirname "$0")/.."

app="${RALLO_APP:-$HOME/Applications/Rallo.app}"
cli="$app/Contents/Helpers/rallo"
out=docs/images
# The real path: the app sees /private/var/…, and stop_demo matches on it.
work="$(cd "$(mktemp -d)" && pwd -P)"
data="$work/data"
stand_in=""

fail() { echo "error: $*" >&2; exit 1; }
# An open menu keeps the app from handling SIGTERM; force it after a second.
stop_demo() {
  pkill -f -- "--data-dir $data" 2>/dev/null || return 0
  sleep 1
  pkill -9 -f -- "--data-dir $data" 2>/dev/null || true
}
cleanup() {
  stop_demo
  [ -n "$stand_in" ] && kill "$stand_in" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

[ -x "$cli" ] || fail "no Rallo at $app (set RALLO_APP)"

# --- Sample data -------------------------------------------------------------
export RALLO_DATA_DIR="$data"
"$cli" note "Call the dentist about Thursday" >/dev/null
"$cli" note "Review Sam's PR on the billing service" >/dev/null
"$cli" note "Book flights for the team offsite" >/dev/null
"$cli" note "Try the new espresso place on 5th" >/dev/null
# Fixed daytime deadlines tomorrow, so the shots read the same whenever run.
tomorrow_at() { date -v+1d "+%Y-%m-%dT$1:00%z" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'; }
"$cli" remind "Send the weekly update" --at "$(tomorrow_at 09:30)" >/dev/null
"$cli" remind "Stretch and refill water" --at "$(tomorrow_at 15:00)" >/dev/null

# A stand-in for an agent process: its waiting row lives while this sleeps.
python3 - "$cli" <<'PY' &
import subprocess, sys, time
payload = b'{"session_id":"demo-claude","cwd":"/Users/demo/code/shop","hook_event_name":"PermissionRequest","tool_name":"Bash"}'
subprocess.run([sys.argv[1], "agent-event", "--agent", "claude"], input=payload)
time.sleep(600)
PY
stand_in=$!
disown "$stand_in"
sleep 2

# A ClickUp message, written straight into the demo's runtime file.
now_ms=$(($(date +%s) * 1000))
sqlite3 "$data/runtime/agents.sqlite3" "INSERT INTO agent_sessions
  (agent, session_id, state, place, detail, app_path, app_pid, focus, agent_pid, agent_started_us, state_seq, updated_at_ms)
  VALUES ('clickup', 'demo-dm', 'waiting', 'Maya Chen', NULL, NULL, NULL, 'clickup:1:demo-dm', NULL, NULL, 1, $((now_ms - 180000)));"

# The CLI writes above may have started a background instance; the demo
# launches below need the data directory to themselves.
stop_demo
sleep 1

# --- Capture ---------------------------------------------------------------
cat > "$work/windows.swift" <<'SWIFT'
import CoreGraphics
// One line per on-screen window of a pid: id, layer, name.
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    print(window[kCGWindowNumber as String] ?? 0, window[kCGWindowLayer as String] ?? 0, window[kCGWindowName as String] as? String ?? "")
}
SWIFT
swiftc -O -o "$work/windows" "$work/windows.swift"

# shoot <light|dark> <what to open> <window to capture: a name or :layer> <file>
shoot() {
  open -n -g "$app" --args --data-dir "$data" --demo-appearance "$1" --demo-open "$2"
  local pid=""
  for _ in $(seq 1 20); do
    pid="$(pgrep -f -- "--demo-open $2" | head -1 || true)"
    [ -n "$pid" ] && break
    sleep 0.5
  done
  [ -n "$pid" ] || fail "the demo instance didn't start"
  sleep 4
  local id=""
  while read -r window layer name; do
    if [ "$3" = "$name" ] || [ "$3" = ":$layer" ]; then id="$window"; fi
  done < <("$work/windows" "$pid")
  [ -n "$id" ] || fail "no window '$3' for --demo-open $2"
  screencapture -x -l "$id" "$out/$4"
  echo "captured $out/$4"
  stop_demo
  sleep 1
}

mkdir -p "$out"
for appearance in light dark; do
  shoot "$appearance" notes "Rallo Notes" "panel-$appearance.png"
  shoot "$appearance" settings:agents ":0" "settings-$appearance.png"
done
# Menus are translucent; captured alone, only the dark one reads well.
shoot dark menu ":101" menu.png
