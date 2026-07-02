#!/usr/bin/env bash
# recreate_testing_project.sh
# ──────────────────────────────────────────────────────────────────────────────
# Deletes and recreates test_projects/testing_project from scratch using the
# nitrogen CLI, then generates + links with THREE native specs that cover every
# NativeImpl combination:
#
#   testing_project.native.dart  — ios/macos: NativeImpl.swift, android: NativeImpl.kotlin
#   testing_cpp.native.dart      — all platforms: NativeImpl.cpp (pure C++ path)
#   testing_mixed.native.dart    — ios: NativeImpl.swift, android: NativeImpl.kotlin,
#                                   macos/windows/linux: NativeImpl.cpp
#
# Usage:
#   ./scripts/recreate_testing_project.sh [--verify-builds]
#
#   --verify-builds   Also run `flutter build macos --debug` and check it compiles.
#                     Requires Xcode and a Mac. Adds ~3 minutes.
#
# This script is the source of truth for the fixture used by integration_test.dart.
# Run it whenever the generator or link command changes structure.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERIFY_BUILDS=false
for arg in "$@"; do
  [[ "$arg" == "--verify-builds" ]] && VERIFY_BUILDS=true
done

PLUGIN_NAME="testing_project"
PLUGIN_DIR="$REPO_ROOT/test_projects/$PLUGIN_NAME"
CLI_DIR="$REPO_ROOT/packages/nitrogen_cli"
NITRO_DIR="$REPO_ROOT/packages/nitro"
NITRO_GEN_DIR="$REPO_ROOT/packages/nitro_generator"
NITRO_ANN_DIR="$REPO_ROOT/packages/nitro_annotations"

# ── Resolve flutter / dart ────────────────────────────────────────────────────
FLUTTER=""
DART=""
for candidate in \
    "$HOME/.puro/envs/stable/flutter/bin/flutter" \
    "$HOME/.puro/envs/default/flutter/bin/flutter" \
    "$HOME/fvm/versions/stable/bin/flutter" \
    "$HOME/.fvm/default/bin/flutter" \
    "/usr/local/bin/flutter" \
    "$(command -v flutter 2>/dev/null || true)"; do
  if [ -x "$candidate" ]; then
    FLUTTER="$candidate"
    DART="$(dirname "$candidate")/dart"
    break
  fi
done

if [ -z "$FLUTTER" ]; then
  echo "❌  Could not find flutter. Install puro (https://puro.dev) or FVM."
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Recreate test_projects/testing_project fixture       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Repo root : $REPO_ROOT"
echo "  Output    : $PLUGIN_DIR"
echo "  Flutter   : $FLUTTER"
echo ""

# ── 0. Delete existing fixture ────────────────────────────────────────────────
echo "▶ Step 1/7: Deleting existing fixture..."
rm -rf "$PLUGIN_DIR"
echo "  ✔ deleted"

# ── 1. nitrogen init ──────────────────────────────────────────────────────────
echo "▶ Step 2/7: nitrogen init --no-ui --name=$PLUGIN_NAME ..."
cd "$REPO_ROOT/test_projects"
"$DART" run "$CLI_DIR/bin/nitrogen.dart" init \
  --no-ui \
  --name="$PLUGIN_NAME" \
  --org=com.example \
  --platforms=android,ios,macos
echo "  ✔ scaffold created"

# ── 2. Patch pubspec.yaml to use local monorepo path deps ────────────────────
echo "▶ Step 3/7: Patching pubspec.yaml to use local path deps..."
python3 - "$PLUGIN_DIR/pubspec.yaml" "$NITRO_DIR" "$NITRO_GEN_DIR" "$NITRO_ANN_DIR" << 'PYEOF'
import sys
import re

pubspec_path, nitro_path, gen_path, ann_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(pubspec_path) as f:
    content = f.read()

# Replace published version refs with local path deps
content = re.sub(r'(\s+nitro:\s*)\^[\d.]+', f'\g<1>\n    path: {nitro_path}', content)
content = re.sub(r'(\s+nitro_generator:\s*)\^[\d.]+', f'\g<1>\n    path: {gen_path}', content)
content = re.sub(r'(\s+nitro_annotations:\s*)\^[\d.]+', f'\g<1>\n    path: {ann_path}', content)

# Add dependency_overrides if not already present
if 'dependency_overrides:' not in content:
    content += f'\ndependency_overrides:\n'
    content += f'  nitro:\n    path: {nitro_path}\n'
    content += f'  nitro_generator:\n    path: {gen_path}\n'
    content += f'  nitro_annotations:\n    path: {ann_path}\n'

# Ensure workspace resolution
if 'resolution: workspace' not in content:
    content = content.replace('publish_to:', 'resolution: workspace\npublish_to:', 1)

with open(pubspec_path, 'w') as f:
    f.write(content)
print(f'  ✔ {pubspec_path} patched')
PYEOF
echo "  ✔ pubspec patched"

# ── 3. Write the 3 native specs ───────────────────────────────────────────────
echo "▶ Step 4/7: Writing multi-spec native files..."

# Spec 1 — Swift/Kotlin (replaces the init-generated single spec)
cat > "$PLUGIN_DIR/lib/src/$PLUGIN_NAME.native.dart" << 'DARTEOF'
import 'package:nitro/nitro.dart';

part 'testing_project.g.dart';

@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.swift,
)
abstract class TestingProject extends HybridObject {
  static final TestingProject instance = _TestingProjectImpl();

  double add(double a, double b);

  @nitroNativeAsync
  Future<String> getGreeting(String name);
}
DARTEOF

# Spec 2 — Pure C++ cross-platform
cat > "$PLUGIN_DIR/lib/src/testing_cpp.native.dart" << 'DARTEOF'
import 'package:nitro/nitro.dart';

part 'testing_cpp.g.dart';

/// Pure C++ module — NativeImpl.cpp on every platform.
/// This exercises the generator's C++ bridge path independent of Swift/Kotlin.
@NitroModule(
  ios: NativeImpl.cpp,
  android: NativeImpl.cpp,
  macos: NativeImpl.cpp,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class TestingCpp extends HybridObject {
  static final TestingCpp instance = _TestingCppImpl();

  int multiply(int a, int b);

  double pi();

  bool isEven(int n);

  int? tryDivide(int numerator, int denominator);
}
DARTEOF

# Spec 3 — Mixed per-platform languages
cat > "$PLUGIN_DIR/lib/src/testing_mixed.native.dart" << 'DARTEOF'
import 'package:nitro/nitro.dart';

part 'testing_mixed.g.dart';

/// Mixed-language module — Swift on iOS, Kotlin on Android, C++ on macOS/Windows/Linux.
/// This exercises that one spec can fan out to different native languages per platform.
@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.cpp,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class TestingMixed extends HybridObject {
  static final TestingMixed instance = _TestingMixedImpl();

  String platform();

  bool? optionalFlag();

  double? optionalValue(String key);
}
DARTEOF

echo "  ✔ 3 native specs written"

# ── 4. Add testing_project to workspace root ──────────────────────────────────
echo "▶ Step 4b: Ensuring workspace includes testing_project..."
WORKSPACE_PUBSPEC="$REPO_ROOT/pubspec.yaml"
if ! grep -q "test_projects/testing_project$" "$WORKSPACE_PUBSPEC"; then
  # Add both plugin and example to workspace
  sed -i '' '/- benchmark\/example/a\
  - test_projects/testing_project\
  - test_projects/testing_project/example' "$WORKSPACE_PUBSPEC"
  echo "  ✔ added to workspace"
else
  echo "  ✔ already in workspace"
fi

# ── 5. dart pub get ───────────────────────────────────────────────────────────
echo "▶ Step 5/7: dart pub get (workspace)..."
cd "$REPO_ROOT"
"$DART" pub get
echo "  ✔ pub get done"

# ── 6. nitrogen generate ──────────────────────────────────────────────────────
echo "▶ Step 6/7: build_runner (nitrogen generate)..."
cd "$PLUGIN_DIR"
"$DART" run build_runner build --delete-conflicting-outputs 2>/dev/null || \
"$FLUTTER" pub run build_runner build --delete-conflicting-outputs
echo "  ✔ generate done"

# ── 7. nitrogen link ──────────────────────────────────────────────────────────
echo "▶ Step 7/7: nitrogen link..."
"$DART" run "$CLI_DIR/bin/nitrogen.dart" link --no-ui
echo "  ✔ link done"

# ── 8. nitrogen doctor ────────────────────────────────────────────────────────
echo ""
echo "▶ nitrogen doctor..."
"$DART" run "$CLI_DIR/bin/nitrogen.dart" doctor || true

# ── 9. Optional: verify builds ───────────────────────────────────────────────
if [[ "$VERIFY_BUILDS" == "true" ]]; then
  echo ""
  echo "▶ Verifying macOS build (flutter build macos --debug)..."
  cd "$PLUGIN_DIR/example"
  "$FLUTTER" pub get
  "$FLUTTER" build macos --debug
  echo "  ✔ macOS build OK"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  testing_project fixture recreated!                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  3 native specs: testing_project (Swift/Kotlin)"
echo "                  testing_cpp     (C++ all platforms)"
echo "                  testing_mixed   (Swift/Kotlin/C++ mixed)"
echo ""
echo "  Run integration tests:"
echo "    cd packages/nitrogen_cli && dart test test/integration_test.dart"
echo ""
