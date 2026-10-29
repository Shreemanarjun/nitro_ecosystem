#!/usr/bin/env bash
# Runs tool/isolate_pool_bench.dart under JIT (dart run) and AOT (compiled exe)
# and prints a side-by-side table. AOT is prod (asserts off, fully compiled);
# JIT is dev (asserts on, starts interpreted) — they can disagree on both
# magnitude AND direction, so never trust a single-mode number.
#
#   bash packages/nitro/tool/bench_pool_compare.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bench="$here/isolate_pool_bench.dart"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "JIT run (dart run)…"      >&2
dart run "$bench" > "$tmp/jit.out" 2>&1

echo "AOT compile + run…"       >&2
dart compile exe "$bench" -o "$tmp/pb" >/dev/null
"$tmp/pb" > "$tmp/aot.out" 2>&1

awk -F'\t' '
  FNR==NR { if($1=="RESULT"){ j[$2]=$3; u[$2]=$4; if(!($2 in seen)){ord[++n]=$2; seen[$2]=1} } next }
  { if($1=="RESULT"){ a[$2]=$3 } }
  END {
    printf "%-32s %11s %11s %8s   %s\n","scenario","JIT","AOT","unit","AOT vs JIT";
    for(i=1;i<=n;i++){ s=ord[i]; r=(a[s]>0? j[s]/a[s] : 0);
      tag=(r>=1.0 ? sprintf("%.2fx faster",r) : sprintf("%.2fx slower",1/r));
      printf "%-32s %11.3f %11.3f %8s   %s\n", s, j[s], a[s], u[s], tag }
  }' "$tmp/jit.out" "$tmp/aot.out"
