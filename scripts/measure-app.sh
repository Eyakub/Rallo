#!/usr/bin/env bash
# Measures the running Rallo app's average CPU and physical footprint.
#   scripts/measure-app.sh <hidden|visible> [seconds]
# Uses RALLO_DATA_DIR (or the default data dir) to drive visibility through
# the CLI, waits for startup to settle, then samples cumulative CPU time.
# Physical footprint comes from footprint(1), not RSS.
set -euo pipefail
state="$1"; seconds="${2:-600}"
rallo="${RALLO_CLI:-$HOME/Applications/Rallo.app/Contents/Helpers/rallo}"

case "$state" in
  hidden) "$rallo" hide >/dev/null ;;
  visible) "$rallo" show >/dev/null ;;
  *) echo "usage: $0 <hidden|visible> [seconds]" >&2; exit 2 ;;
esac
sleep 10
pid="$(pgrep -f 'Rallo.app/Contents/MacOS/Rallo' | head -1)"
[ -n "$pid" ] || { echo "error: Rallo is not running" >&2; exit 1; }

cpu_seconds() {
  ps -o cputime= -p "$pid" | awk -F'[:.]' '{ if (NF == 4) print $1*3600 + $2*60 + $3 + $4/100; else print $1*60 + $2 + $3/100 }'
}
footprint_mib() {
  footprint -p "$pid" 2>/dev/null | sed -nE 's/^ *phys_footprint: ([0-9.]+) (KB|MB|GB).*/\1 \2/p' |
    awk '{ v=$1; if ($2=="KB") v/=1024; if ($2=="GB") v*=1024; print v; exit }'
}

start_cpu="$(cpu_seconds)"; start_fp="$(footprint_mib)"
sleep "$seconds"
end_cpu="$(cpu_seconds)"; end_fp="$(footprint_mib)"
python3 - "$state" "$seconds" "$start_cpu" "$end_cpu" "$start_fp" "$end_fp" <<'PY'
import sys
state, secs, c0, c1, f0, f1 = sys.argv[1], float(sys.argv[2]), *map(float, sys.argv[3:])
print(f"{state}: window {secs:.0f}s, avg CPU {(c1 - c0) / secs * 100:.3f}% of one core, "
      f"footprint {f0:.1f} MiB -> {f1:.1f} MiB")
PY
