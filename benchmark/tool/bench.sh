#!/usr/bin/env bash
# Automated cross-bridge benchmark runner (FFI vs Nitro vs MethodChannel).
#
# Usage:
#   tool/bench.sh [-d DEVICE] [--mode quick|full] [--gate relative|all|none]
#                 [--debug|--profile] [--update-baseline]
#
#   -d DEVICE          flutter device id (default: macos)
#   --mode             iteration scale (default: quick; use full on dedicated hw)
#   --gate             regression gate (default: relative — CI-safe ratios;
#                      all = also gate absolute µs vs the checked-in baseline)
#   --profile          build mode (default; use --debug only for smoke tests)
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

FORMAT_ARGS=("$RESPONSE" --out-dir "$RESULTS_DIR")
if [[ "$UPDATE_BASELINE" == "1" ]]; then
  FORMAT_ARGS+=(--update-baseline "$BASELINES_DIR")
fi
dart run "$SCRIPT_DIR/format_report.dart" "${FORMAT_ARGS[@]}"
