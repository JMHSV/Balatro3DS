#!/usr/bin/env bash
# Load Lab: measure what boot and the first hand cost an Old 3DS. See README.md.
#
#   LOVE=<lovec.exe or love> LUA51=<PUC lua 5.1> bash dev/load_lab/run.sh [out_dir]
#
# Run from the repository root. Writes <out_dir>/report.txt (default dev/load_lab/out/latest).
set -euo pipefail

: "${LOVE:?set LOVE to a LÖVE 11.5 binary (lovec.exe on Windows)}"
: "${LUA51:?set LUA51 to a PUC Lua 5.1 interpreter}"
OUT="${1:-dev/load_lab/out/latest}"
RUNS="${LOAD_LAB_RUNS:-5}"

[[ -f main.lua && -d dev/load_lab ]] || { echo "run from the repository root" >&2; exit 1; }
PYTHON="${PYTHON:-python}"
command -v "$PYTHON" >/dev/null || PYTHON=python3

root="$(pwd)"
if command -v cygpath >/dev/null; then root="$(cygpath -m "$root")"; fi
export BALATRO_ROOT="$root"

mkdir -p "$OUT"
rm -f "$OUT"/trace.txt "$OUT"/puc_*.txt "$OUT"/report.txt

"$PYTHON" dev/load_lab/score.py stage "$OUT"
"$LOVE" . --load-lab --stage "$OUT/stage" --out "$OUT" >"$OUT/love.log" 2>&1 \
    || { tail -30 "$OUT/love.log" >&2; exit 1; }
[[ -f "$OUT/trace.txt" ]] || { tail -30 "$OUT/love.log" >&2; echo "no trace written" >&2; exit 1; }

for i in $(seq 1 "$RUNS"); do
    "$LUA51" dev/load_lab/puc_boot.lua "$OUT/stage" "$OUT/puc_time_$i.txt" time >/dev/null
done
"$LUA51" dev/load_lab/puc_boot.lua "$OUT/stage" "$OUT/puc_alloc.txt" alloc >/dev/null

"$PYTHON" dev/load_lab/score.py report "$OUT"
