#!/usr/bin/env bash
# Release CLI latency benchmark (fresh process per run, warm filesystem).
#   scripts/benchmark-cli.sh [path-to-rallo] [runs]
# Uses an isolated temporary data directory; never touches real user data.
# Reports p50/p95/max per scenario plus machine details, and writes the raw
# hyperfine JSON next to the summary in build/benchmarks/.
set -euo pipefail
source "$(dirname "$0")/env.sh"

rallo="${1:-$CARGO_TARGET_DIR/release/rallo}"
runs="${2:-100}"
command -v hyperfine >/dev/null || { echo "error: hyperfine not found (brew install hyperfine)" >&2; exit 1; }

out="$REPO_ROOT/build/benchmarks/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
data="$(mktemp -d)"
trap 'rm -rf "$data"' EXIT
export RALLO_DATA_DIR="$data"
# Keep the app out of the measurement: hidden notes never launch it.
"$rallo" hide >/dev/null

bench() {
  local name="$1"; shift
  hyperfine --style none --warmup 5 --runs "$runs" -N --export-json "$out/$name.json" "$@" >/dev/null
  python3 - "$out/$name.json" "$name" <<'PY'
import json, sys
times = sorted(json.load(open(sys.argv[1]))["results"][0]["times"])
pick = lambda q: times[min(len(times) - 1, int(round(q * (len(times) - 1))))] * 1000
print(f"{sys.argv[2]:<22} n={len(times):<4} p50={pick(0.5):6.2f} ms  p95={pick(0.95):6.2f} ms  max={times[-1]*1000:6.2f} ms")
PY
}

{
  echo "# rallo CLI benchmark $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "binary: $rallo ($("$rallo" --version))"
  echo "machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.memsize | awk '{printf "%.0f GiB", $1/1073741824}'), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "power: $(pmset -g batt | head -1 | sed "s/Now drawing from //"), low power mode $(pmset -g | awk '/lowpowermode/ {print $2}')"
  bench "version" "$rallo --version"
  bench "note (durable commit)" "$rallo note benchmark-note"
  bench "list (first page)" "$rallo list --json"
} | tee "$out/summary.txt"
