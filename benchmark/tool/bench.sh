#!/usr/bin/env bash
# Automated cross-bridge benchmark runner (FFI vs Nitro vs MethodChannel).
#
# Usage:
#   tool/bench.sh [-d DEVICE] [--mode quick|full] [--gate relative|all|none]
#                 [--debug|--profile|--release] [--update-baseline]
#
#   -d DEVICE          flutter device id (default: macos)
#   --mode             iteration scale (default: quick; use full on dedicated hw)
#   --gate             regression gate (default: relative — CI-safe ratios;
#                      all = also gate absolute µs vs the checked-in baseline)
#   --profile          build mode (default; use --debug only for smoke tests)
#   --release          MEASUREMENT mode of record — runs the headless in-app
#                      autorun (flutter test cannot build release); no gate
#   --update-baseline  record this run as the new baseline for the platform
#
# Examples:
#   tool/bench.sh                                     # quick relative-gated run on macOS
#   tool/bench.sh -d 3022faca --mode full             # full run on an Android device
#   tool/bench.sh --mode full --update-baseline       # refresh the macOS baseline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$SCRIPT_DIR/../example"
RESULTS_DIR="$SCRIPT_DIR/../results"
BASELINES_DIR="$EXAMPLE_DIR/assets/baselines"

DEVICE="macos"
MODE="quick"
GATE="relative"
BUILD_FLAG="--profile"
UPDATE_BASELINE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)                DEVICE="$2"; shift 2 ;;
    --mode)            MODE="$2"; shift 2 ;;
    --gate)            GATE="$2"; shift 2 ;;
    --debug)           BUILD_FLAG=""; shift ;;
    --profile)         BUILD_FLAG="--profile"; shift ;;
    --release)         BUILD_FLAG="--release"; shift ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

echo "── nitro bench: device=$DEVICE mode=$MODE gate=$GATE ${BUILD_FLAG:-(debug)} ──"

# Regenerate + relink the benchmark plugin from the workspace CLI before
# building. This makes the run independent of the committed generated/synced
# files — a stale global `nitrogen` binary or an outdated commit can otherwise
# leave broken bridge copies in SPM Sources/ (seen: an old fixed-window Swift
# preamble strip deleting spec struct declarations → CI compile failure).
NITROGEN="$SCRIPT_DIR/../../packages/nitrogen_cli/bin/nitrogen.dart"
if [[ -f "$NITROGEN" ]]; then
  echo "── regenerating bridges with workspace nitrogen ──"
  (
    cd "$SCRIPT_DIR/.."
    rm -f .dart_tool/nitro/cache.json
    dart run "$NITROGEN" generate --no-ui
    dart run "$NITROGEN" link --no-ui
  )
fi

cd "$EXAMPLE_DIR"

if [[ "$BUILD_FLAG" == "--release" ]]; then
  # flutter test/drive cannot build --release. The app itself runs the same
  # BenchHarness headlessly (lib/harness/bench_autorun.dart) when launched
  # with BENCH_AUTORUN, prints `BENCH|` lines + the report JSON to the device
  # log, and exits. The regression gate lives in the integration test and is
  # not applied here — release runs are for MEASUREMENT (the mode users
  # actually ship); drift analysis still runs via format_report below.
  RUN_LOG="$(mktemp)"
  # In release mode there is no VM service, so `flutter run` cannot detect
  # the app's exit(0) and stays attached to the device log forever — run it
  # in the background and terminate it ourselves once BENCH|DONE appears.
  flutter run --release -d "$DEVICE" --dart-define=BENCH_AUTORUN="$MODE" > "$RUN_LOG" 2>&1 &
  RUN_PID=$!
  for _ in $(seq 1 600); do
    if grep -q "BENCH|DONE" "$RUN_LOG" 2>/dev/null; then break; fi
    if ! kill -0 "$RUN_PID" 2>/dev/null; then break; fi
    sleep 1
  done
  kill "$RUN_PID" 2>/dev/null || true
  wait "$RUN_PID" 2>/dev/null || true
  grep -E "BENCH\|" "$RUN_LOG" | sed -E 's/^[^B]*BENCH\|//' | grep -vE "^J#|^JEND"
  RESPONSE="build/integration_response_data.json"
  # Reassemble the chunked JSON (logcat truncates long lines, so the autorun
  # emits BENCH|J#NNNN|<chunk> lines in order plus a BENCH|JEND|<count>).
  grep -E "BENCH\|J#" "$RUN_LOG" | sed -E 's/^[^B]*BENCH\|J#[0-9]+\|//' | tr -d '\n' > "$RESPONSE"
  rm -f "$RUN_LOG"
  if [[ ! -s "$RESPONSE" ]]; then
    echo "error: autorun did not emit BENCH|J# report chunks" >&2
    exit 1
  fi
  FORMAT_ARGS=("$RESPONSE" --out-dir "$RESULTS_DIR" --compare-dir "$RESULTS_DIR" \
    --baselines-dir "$BASELINES_DIR")
  if [[ "$UPDATE_BASELINE" == "1" ]]; then
    FORMAT_ARGS+=(--update-baseline "$BASELINES_DIR")
  fi
  dart run "$SCRIPT_DIR/format_report.dart" "${FORMAT_ARGS[@]}"
  exit 0
fi

flutter drive $BUILD_FLAG \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/benchmark_regression_test.dart \
  -d "$DEVICE" \
  --dart-define=NITRO_BENCH_MODE="$MODE" \
  --dart-define=NITRO_BENCH_GATE="$GATE"

RESPONSE="build/integration_response_data.json"
if [[ ! -f "$RESPONSE" ]]; then
  echo "error: $RESPONSE was not written — driver did not receive report data" >&2
  exit 1
fi

# --baselines-dir: format_report resolves <dir>/<platform>.json itself from
# the report's platform field, enabling the Δ-vs-baseline analysis columns.
FORMAT_ARGS=("$RESPONSE" --out-dir "$RESULTS_DIR" --compare-dir "$RESULTS_DIR" \
  --baselines-dir "$BASELINES_DIR")
if [[ "$UPDATE_BASELINE" == "1" ]]; then
  FORMAT_ARGS+=(--update-baseline "$BASELINES_DIR")
fi
dart run "$SCRIPT_DIR/format_report.dart" "${FORMAT_ARGS[@]}"
