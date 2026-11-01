#!/usr/bin/env bash
# Build and run the bridge memory-safety harness under ASan+UBSan and TSan.
# Portable: Apple clang (macOS, no leak detection) and GCC/Clang on Linux CI
# (LeakSanitizer active). Exits non-zero on the first sanitizer or CHECK failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build"

cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Debug >/dev/null
cmake --build "$build" --parallel >/dev/null

# LeakSanitizer only exists on Linux ASan; macOS ASan aborts on detect_leaks=1.
leaks="detect_leaks=0"
if [ "$(uname -s)" = "Linux" ]; then leaks="detect_leaks=1"; fi

echo "== ASan + UBSan =="
ASAN_OPTIONS="${leaks}:abort_on_error=1:strict_string_checks=1" \
  UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
  "$build/bridge_safety_asan"

echo "== TSan =="
TSAN_OPTIONS="halt_on_error=1" "$build/bridge_safety_tsan"

echo "ALL SANITIZER BUILDS PASSED"
