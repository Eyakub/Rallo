#!/usr/bin/env bash
# End-to-end crash-window checks for the notification protocol (0005) against
# the installed app and the real UserNotifications center. Every scenario uses
# its own data directory under build/fault/; identifiers are scoped per data
# directory, so the user's own reminders are never observed or removed.
#
#   scripts/fault-notifications.sh [scenario...]   (default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${RALLO_APP:-$HOME/Applications/Rallo.app}"
BIN="$APP/Contents/MacOS/Rallo"
CLI="$APP/Contents/Helpers/rallo"
OUT="$ROOT/build/fault"
RESULTS="$OUT/results.txt"
mkdir -p "$OUT"
: > "$RESULTS"
created_ids=()
failures=0

log() { printf '%s\n' "$*" | tee -a "$RESULTS"; }
fail() { log "  FAIL: $*"; failures=$((failures + 1)); }
pass() { log "  ok: $*"; }

app_pid() { lsof -t "$1/app.lock" 2>/dev/null | head -1 || true; }

app_start() { # DIR [FAULT]
  local dir="$1" fault="${2:-}"
  local args=(--background --data-dir "$dir")
  [[ -n "$fault" ]] && args+=(--fault-injection "$fault")
  open -g -n -a "$APP" --args "${args[@]}"
  for _ in $(seq 1 50); do [[ -n "$(app_pid "$dir")" ]] && return 0; sleep 0.1; done
  fail "app did not start for $dir"
}

app_stop() { # DIR
  local pid; pid="$(app_pid "$1")"
  [[ -z "$pid" ]] && return 0
  kill -TERM "$pid"
  for _ in $(seq 1 50); do [[ -z "$(app_pid "$1")" ]] && return 0; sleep 0.1; done
  fail "app did not quit for $1"
}

wait_gone() { # DIR SECONDS — the app exits by itself at the fault point
  for _ in $(seq 1 $(($2 * 10))); do [[ -z "$(app_pid "$1")" ]] && return 0; sleep 0.1; done
  return 1
}

cli() { local dir="$1"; shift; "$CLI" --data-dir "$dir" --json "$@"; }

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

remind() { # DIR DURATION → sets $ITEM and $RID (no subshell, so they stick)
  local out; out="$(cli "$1" remind "Rallo fault test" --in "$2")"
  ITEM="$(json "d['item']['id']" <<<"$out")"
  RID="$(json "d['item']['reminder']['id']" <<<"$out")"
  created_ids+=("$RID")
}

scheduling() { cli "$1" get "$2" | json "(lambda s: s and s['state'] + '/' + s['reason'])(d['scheduling'])"; }
cancellation() { cli "$1" get "$2" | json "(lambda s: s and s['state'] + '/' + s['reason'])(d['cancellation'])"; }

wait_scheduling() { # DIR ITEM PATTERN SECONDS
  local got=""
  for _ in $(seq 1 $(($4 * 10))); do
    got="$(scheduling "$1" "$2")"
    [[ "$got" =~ $3 ]] && { echo "$got"; return 0; }
    sleep 0.1
  done
  echo "$got"
  return 1
}

# Counts of this reminder's native requests: "pending delivered".
native() {
  "$BIN" --probe inspect-reminders | python3 -c "
import json,sys
d=json.load(sys.stdin); rid=sys.argv[1]
mine=lambda xs: [x for x in xs if x['identifier'].endswith('.' + rid)]
print(len(mine(d['pending'])), len(mine(d['delivered'])))" "$1"
}

events_since() { # DIR MS EVENT → count
  python3 - "$1/diagnostics/events.jsonl" "$2" "$3" <<'PY'
import json,sys
path,since,event=sys.argv[1],int(sys.argv[2]),sys.argv[3]
try: lines=open(path).read().splitlines()
except FileNotFoundError: lines=[]
print(sum(1 for l in lines if (e:=json.loads(l)).get('event')==event and e['at_ms']>=since))
PY
}

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

fresh() { local dir="$OUT/$1"; rm -rf "$dir"; mkdir -p "$dir"; echo "$dir"; }

# What "macOS accepted it" reads as depends on authorization (0005 status
# table): with notifications denied, an accepted request is still reported
# honestly as unavailable/permission_denied.
SCHEDULED='^scheduled/'

scenario_baseline() {
  log "baseline: CLI remind while the app runs"
  local dir; dir="$(fresh baseline)"
  app_start "$dir"
  remind "$dir" 10m; local rid="$RID"
  local s; if s="$(wait_scheduling "$dir" "$ITEM" "$SCHEDULED" 5)"; then pass "scheduling $s"; else fail "scheduling $s"; fi
  [[ "$(native "$rid")" == "1 0" ]] && pass "one pending request" || fail "native $(native "$rid")"
  app_stop "$dir"
}

scenario_after_begin() {
  log "after_begin: crash after the durable attempt mark, before add()"
  local dir; dir="$(fresh after-begin)"
  app_start "$dir" after_begin
  remind "$dir" 10m; local rid="$RID"
  wait_gone "$dir" 5 && pass "app exited at the fault" || fail "app still running"
  [[ "$(native "$rid")" == "0 0" ]] && pass "nothing submitted" || fail "native $(native "$rid")"
  local s; s="$(scheduling "$dir" "$ITEM")"; [[ "$s" == pending/* ]] && pass "status $s" || fail "status $s"
  app_start "$dir"
  if s="$(wait_scheduling "$dir" "$ITEM" "$SCHEDULED" 5)"; then pass "recovered: $s"; else fail "after relaunch $s"; fi
  [[ "$(native "$rid")" == "1 0" ]] && pass "exactly one pending request" || fail "native $(native "$rid")"
  app_stop "$dir"
}

scenario_after_add() {
  log "after_add: crash after macOS accepted, before bookkeeping"
  local dir; dir="$(fresh after-add)"
  app_start "$dir" after_add
  remind "$dir" 10m; local rid="$RID"
  wait_gone "$dir" 5 && pass "app exited at the fault" || fail "app still running"
  [[ "$(native "$rid")" == "1 0" ]] && pass "request accepted by macOS" || fail "native $(native "$rid")"
  local s; s="$(scheduling "$dir" "$ITEM")"; [[ "$s" == pending/* ]] && pass "status $s" || fail "status $s"
  local since; since="$(now_ms)"
  app_start "$dir"
  if s="$(wait_scheduling "$dir" "$ITEM" "$SCHEDULED" 5)"; then pass "resolved from evidence: $s"; else fail "after relaunch $s"; fi
  local adds; adds="$(events_since "$dir" "$since" notification_schedule)"
  [[ "$adds" == 0 ]] && pass "no second add()" || fail "$adds schedule attempts after relaunch"
  [[ "$(native "$rid")" == "1 0" ]] && pass "still one pending request" || fail "native $(native "$rid")"
  app_stop "$dir"
}

scenario_after_remove() {
  log "after_remove: crash during cancellation"
  local dir; dir="$(fresh after-remove)"
  app_start "$dir"
  remind "$dir" 10m; local rid="$RID"
  wait_scheduling "$dir" "$ITEM" "$SCHEDULED" 5 >/dev/null || fail "not scheduled before the test"
  app_stop "$dir"
  app_start "$dir" after_remove
  cli "$dir" done "$ITEM" >/dev/null
  wait_gone "$dir" 5 && pass "app exited at the fault" || fail "app still running"
  [[ "$(native "$rid")" == "0 0" ]] && pass "request removed" || fail "native $(native "$rid")"
  local c; c="$(cancellation "$dir" "$ITEM")"; [[ "$c" == pending/* ]] && pass "cancellation $c" || fail "cancellation $c"
  app_start "$dir"
  for _ in $(seq 1 50); do c="$(cancellation "$dir" "$ITEM")"; [[ "$c" == None ]] && break; sleep 0.1; done
  [[ "$c" == None ]] && pass "cancellation applied on relaunch" || fail "cancellation $c"
  app_stop "$dir"
}

scenario_elapsed_uncertain() {
  log "elapsed_uncertain: attempt interrupted, deadline passes while the app is down"
  local dir; dir="$(fresh elapsed-uncertain)"
  app_start "$dir" after_begin
  remind "$dir" 4s; local rid="$RID"
  wait_gone "$dir" 3 || fail "app still running"
  sleep 5
  app_start "$dir"
  local s; if s="$(wait_scheduling "$dir" "$ITEM" '^unavailable/delivery_unconfirmed$' 5)"; then pass "$s"; else fail "status $s"; fi
  sleep 1
  [[ "$(native "$rid")" == "0 0" ]] && pass "never replayed" || fail "native $(native "$rid")"
  app_stop "$dir"
}

scenario_never_attempted() {
  log "never_attempted: app could not be launched before the deadline"
  local dir; dir="$(fresh never-attempted)"
  local out; out="$(RALLO_APP_PATH=/nonexistent/Rallo.app cli "$dir" remind "Rallo fault test" --in 2s)"
  ITEM="$(json "d['item']['id']" <<<"$out")"
  local rid; rid="$(json "d['item']['reminder']['id']" <<<"$out")"; created_ids+=("$rid")
  [[ "$(json "len(d['warnings'])" <<<"$out")" -ge 1 ]] && pass "launch failure reported as a warning" || fail "no warning"
  sleep 3
  app_start "$dir"
  local s; if s="$(wait_scheduling "$dir" "$ITEM" '^unavailable/deadline_elapsed_unattempted$' 5)"; then pass "$s"; else fail "status $s"; fi
  sleep 1
  [[ "$(native "$rid")" == "0 0" ]] && pass "no late alert" || fail "native $(native "$rid")"
  app_stop "$dir"
}

scenario_delivered_while_closed() {
  log "delivered_while_closed: fires with no Rallo process, observed on relaunch"
  local dir; dir="$(fresh delivered-closed)"
  app_start "$dir"
  remind "$dir" 5s; local rid="$RID"
  wait_scheduling "$dir" "$ITEM" "$SCHEDULED" 3 >/dev/null || fail "not scheduled"
  app_stop "$dir"
  sleep 7
  log "  native after deadline (pending delivered): $(native "$rid")"
  app_start "$dir"
  local s; s="$(wait_scheduling "$dir" "$ITEM" '^delivered/' 5 || true)"
  log "  status after relaunch: $s (delivered is only reported when macOS lists it)"
  app_stop "$dir"
}

scenario_scope_isolation() {
  log "scope_isolation: two data directories never clean up each other"
  local a b; a="$(fresh scope-a)"; b="$(fresh scope-b)"
  app_start "$a"; app_start "$b"
  remind "$a" 10m; local ra="$RID" ia="$ITEM"
  remind "$b" 10m; local rb="$RID" ib="$ITEM"
  wait_scheduling "$a" "$ia" "$SCHEDULED" 5 >/dev/null || fail "a not scheduled"
  wait_scheduling "$b" "$ib" "$SCHEDULED" 5 >/dev/null || fail "b not scheduled"
  cli "$a" note "nudge a drain" >/dev/null; cli "$b" note "nudge b drain" >/dev/null
  sleep 2
  [[ "$(native "$ra")" == "1 0" && "$(native "$rb")" == "1 0" ]] && pass "both requests intact" \
    || fail "a: $(native "$ra"), b: $(native "$rb")"
  app_stop "$a"; app_stop "$b"
}

cleanup() {
  local ids=()
  for rid in "${created_ids[@]:-}"; do
    [[ -n "$rid" ]] || continue
    while read -r ident; do ids+=("$ident"); done < <("$BIN" --probe inspect-reminders | python3 -c "
import json,sys; d=json.load(sys.stdin); rid=sys.argv[1]
for x in d['pending'] + d['delivered']:
    if x['identifier'].endswith('.' + rid): print(x['identifier'])" "$rid")
  done
  if [[ ${#ids[@]} -gt 0 ]]; then "$BIN" --probe remove-reminders "${ids[@]}" >/dev/null; fi
}
trap cleanup EXIT

scenarios=("$@")
[[ ${#scenarios[@]} -eq 0 ]] && scenarios=(baseline after_begin after_add after_remove elapsed_uncertain never_attempted delivered_while_closed scope_isolation)
log "Rallo notification fault injection — $(date -u +%Y-%m-%dT%H:%M:%SZ), $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
AUTH="$("$BIN" --probe status | json "d.get('authorization_status')" 2>/dev/null || echo unknown)"
log "authorization: $AUTH"
if [[ "$AUTH" == denied ]]; then SCHEDULED='^unavailable/permission_denied$'; fi
for s in "${scenarios[@]}"; do "scenario_$s"; done
log "failures: $failures"
exit $((failures > 0))
