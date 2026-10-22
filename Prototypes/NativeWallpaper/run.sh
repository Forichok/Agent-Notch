#!/bin/zsh
# Builds bench.swift and runs every mode in turn, two rounds interleaved, 30 s each.
# Each run covers the main screen with a click-through window for ~40 s. Results: RESULT lines on stdout.
#   Prototypes/NativeWallpaper/run.sh [out-dir]
set -e
here=${0:A:h}; root=${here:h:h}; out=${1:-${TMPDIR:-/tmp}/native-wallpaper}
mkdir -p $out
swiftc -O -o $out/bench $here/bench.swift
python3 -m http.server 8765 --bind 127.0.0.1 --directory $root/room >/dev/null 2>&1 &
server=$!; trap "kill $server" EXIT; sleep 1
run() { echo "== $*"; env "$@" | grep -A8 RESULT; sleep 3 }
run WARM=4 $out/bench idle
for round in 1 2; do
  run WARM=10 $out/bench webkit
  run WARM=4 $out/bench metal
  run WARM=4 $out/bench cg
  run WARM=4 $out/bench raw
done
# a lighter scene, closer to what a port that skips needless overdraw would draw
run RECTS=3000 BIG=20 SPRITES=40 WARM=4 $out/bench metal
run RECTS=3000 BIG=20 SPRITES=40 WARM=4 $out/bench cg
run RECTS=3000 BIG=20 SPRITES=40 WARM=4 $out/bench raw
