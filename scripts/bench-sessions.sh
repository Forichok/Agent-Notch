#!/bin/sh
# No network or installed app. Compile identical harnesses against the two source trees.
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--incremental" ]; then
  shift
  exec python3 scripts/SessionBenchmark/incremental.py "$@"
fi
BASE=${BENCH_BASE:-origin/master}
ROOT=/tmp/an06-bench
rm -rf "$ROOT/baseline"
mkdir -p "$ROOT/baseline" "$ROOT/cache"
git archive "$BASE" Sources/NotchCore | tar -x -C "$ROOT/baseline"
xcrun swiftc -O -whole-module-optimization -module-cache-path "$ROOT/cache" -o "$ROOT/before" \
  "$ROOT"/baseline/Sources/NotchCore/*.swift scripts/SessionBenchmark/main.swift
xcrun swiftc -O -whole-module-optimization -D EVENT_SCANNER -module-cache-path "$ROOT/cache" -o "$ROOT/after" \
  Sources/NotchCore/*.swift scripts/SessionBenchmark/main.swift
python3 scripts/bench-sessions.py --root "$ROOT" --base "$(git rev-parse "$BASE")" "$@"
