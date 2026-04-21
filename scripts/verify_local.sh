#!/usr/bin/env bash
# verify_local.sh
# ──────────────────────────────────────────────────────────────────────────────
# Creates a throwaway Flutter FFI plugin in test_projects/ to verify local
# changes to the nitro ecosystem before publishing.
#
# This script:
#   1. Runs `flutter create --template=plugin_ffi` to scaffold the base plugin
#   2. Patches pubspec.yaml to use local monorepo path dependencies
#   3. Runs `flutter pub get`
#   4. Runs `nitrogen generate` (build_runner)
#   5. Runs `nitrogen link`
#   6. Runs `nitrogen doctor`
#
# Usage:
#   ./scripts/verify_local.sh [plugin_name] [platforms]
#
# Examples:
#   ./scripts/verify_local.sh                           # default: nitro_test_plugin, ios,android
#   ./scripts/verify_local.sh my_verifier
#   ./scripts/verify_local.sh my_verifier ios,android,macos
#
# Test projects are gitignored (test_projects/ is in .gitignore).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLUGIN_NAME="${1:-nitro_test_plugin}"
PLATFORMS="${2:-ios,android}"

# ── Resolve flutter / dart ────────────────────────────────────────────────────
# Priority: puro stable (matches workspace SDK ^3.11.3) → fvm → PATH
FLUTTER=""
DART=""
for candidate in \
    "$HOME/.puro/envs/stable/flutter/bin/flutter" \
    "$HOME/.puro/envs/default/flutter/bin/flutter" \
    "$HOME/fvm/versions/stable/bin/flutter" \
    "$HOME/fvm/default/bin/flutter" \
    "$HOME/.fvm/default/bin/flutter" \
    "/usr/local/bin/flutter" \
    "/opt/homebrew/bin/flutter" \
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

DART_VERSION="$("$DART" --version 2>&1 | awk '{print $4}')"
echo "  Using flutter : $FLUTTER"
echo "  Using dart    : $DART  (Dart $DART_VERSION)"

# ── Paths ─────────────────────────────────────────────────────────────────────
TEST_DIR="$REPO_ROOT/test_projects"
PLUGIN_DIR="$TEST_DIR/$PLUGIN_NAME"
CLI_DIR="$REPO_ROOT/packages/nitrogen_cli"
NITRO_DIR="$REPO_ROOT/packages/nitro"
NITRO_GEN_DIR="$REPO_ROOT/packages/nitro_generator"
NITRO_ANN_DIR="$REPO_ROOT/packages/nitro_annotations"
NITRO_NATIVE="$NITRO_DIR/src/native"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       Nitrogen Local Verification Bootstrap              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Plugin name : $PLUGIN_NAME"
echo "  Platforms   : $PLATFORMS"
echo "  Output dir  : $PLUGIN_DIR"
echo ""

# ── 0. Clean previous run ────────────────────────────────────────────────────
if [ -d "$PLUGIN_DIR" ]; then
  echo "⚠  Removing existing $PLUGIN_DIR"
  rm -rf "$PLUGIN_DIR"
fi
mkdir -p "$TEST_DIR"

# ── 1. flutter create ────────────────────────────────────────────────────────
echo "▶ Step 1/6: flutter create --template=plugin_ffi ..."
cd "$TEST_DIR"
"$FLUTTER" create \
  --template=plugin_ffi \
  --platforms="$PLATFORMS" \
  --org=com.example \
  "$PLUGIN_NAME"

echo "  ✔ flutter create done"

# ── 2. Patch pubspec.yaml to use local path deps ─────────────────────────────
echo "▶ Step 2/6: Patching pubspec.yaml with local path deps ..."
PUBSPEC="$PLUGIN_DIR/pubspec.yaml"

python3 - "$PUBSPEC" "$NITRO_DIR" "$NITRO_GEN_DIR" "$NITRO_ANN_DIR" << 'PYEOF'
import sys, re

pubspec_path = sys.argv[1]
nitro_path   = sys.argv[2]
gen_path     = sys.argv[3]
ann_path     = sys.argv[4]

with open(pubspec_path) as f:
    lines = f.readlines()

result = []
for line in lines:
    result.append(line)

content = ''.join(result)

# Add nitro, nitro_generator, nitro_annotations under dependencies
# (flutter create plugin_ffi doesn't add them, so we append)
overrides = (
    '\ndependency_overrides:\n'
    f'  nitro:\n    path: {nitro_path}\n'
    f'  nitro_generator:\n    path: {gen_path}\n'
    f'  nitro_annotations:\n    path: {ann_path}\n'
)

deps_block = (
    '\ndependencies:\n'
    '  flutter:\n'
    '    sdk: flutter\n'
    f'  nitro:\n    path: {nitro_path}\n'
    f'  nitro_annotations:\n    path: {ann_path}\n'
)

dev_deps_block = (
    '\ndev_dependencies:\n'
    '  flutter_test:\n'
    '    sdk: flutter\n'
    '  flutter_lints: ^5.0.0\n'
    f'  nitro_generator:\n    path: {gen_path}\n'
    '  build_runner: ^2.4.0\n'
)

# Remove flutter create's default dependencies/dev_dependencies sections
# and replace with our nitro-aware ones
content = re.sub(
    r'\n?dependencies:.*?(?=\ndev_dependencies:|\Z)',
    deps_block,
    content,
    flags=re.DOTALL,
)
content = re.sub(
    r'\n?dev_dependencies:.*?(?=\n[^\s]|\Z)',
    dev_deps_block,
    content,
    flags=re.DOTALL,
)

if 'dependency_overrides:' not in content:
    content += overrides

with open(pubspec_path, 'w') as f:
    f.write(content)

print(f'  ✔ {pubspec_path} patched')
PYEOF

# ── 3. Write a minimal .native.dart spec ─────────────────────────────────────
echo "▶ Step 2b: Writing bridge spec ..."
mkdir -p "$PLUGIN_DIR/lib/src"
CLASS_NAME="$(python3 -c "print(''.join(w.capitalize() for w in '$PLUGIN_NAME'.split('_')))")"
python3 - "$PLUGIN_DIR/lib/src/$PLUGIN_NAME.native.dart" "$CLASS_NAME" << 'PYEOF'
import sys
path, cls = sys.argv[1], sys.argv[2]
content = f"""import 'package:nitro_annotations/nitro_annotations.dart';

@HybridInterface()
abstract class Hybrid{cls}Spec {{
  double add(double a, double b);

  Future<String> getGreeting(String name);
}}
"""
with open(path, 'w') as f:
    f.write(content)
print(f'  ✔ {path} written')
PYEOF
echo "  ✔ bridge spec written"

# ── 4. flutter pub get ───────────────────────────────────────────────────────
echo "▶ Step 3/6: flutter pub get ..."
cd "$PLUGIN_DIR"
"$FLUTTER" pub get
echo "  ✔ pub get done"

# ── 5. nitrogen generate (build_runner) ─────────────────────────────────────
echo "▶ Step 4/6: nitrogen generate (build_runner) ..."
"$FLUTTER" pub run build_runner build --delete-conflicting-outputs
echo "  ✔ generate done"

# ── 6. nitrogen link ─────────────────────────────────────────────────────────
echo "▶ Step 5/6: nitrogen link ..."
"$DART" run "$CLI_DIR/bin/nitrogen.dart" link "$PLUGIN_NAME"
echo "  ✔ link done"

# ── 7. nitrogen doctor ───────────────────────────────────────────────────────
echo "▶ Step 6/6: nitrogen doctor ..."
"$DART" run "$CLI_DIR/bin/nitrogen.dart" doctor

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Verification complete!                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Plugin is at : $PLUGIN_DIR"
echo "  It is gitignored (test_projects/) — safe to delete when done."
echo ""
echo "  Suggested next steps:"
echo "    • Implement stubs in ios/Classes/ and android/src/"
echo "    • cd $PLUGIN_DIR/example && flutter run"
echo "    • Delete when done: rm -rf $PLUGIN_DIR"
echo ""
