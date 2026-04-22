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
PLATFORMS="${2:-android,ios,macos,windows,linux}"

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
import sys, os

def patch_pubspec(pubspec_path, nitro_path, gen_path, ann_path):
    with open(pubspec_path, 'r') as f:
        lines = f.readlines()

    new_lines = []
    in_deps = False
    in_dev_deps = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith('dependencies:'):
            in_deps = True
            in_dev_deps = False
            new_lines.append(line)
            new_lines.append(f'  nitro:\n    path: {nitro_path}\n')
            new_lines.append(f'  nitro_annotations:\n    path: {ann_path}\n')
            continue
        if stripped.startswith('dev_dependencies:'):
            in_deps = False
            in_dev_deps = True
            new_lines.append(line)
            new_lines.append(f'  nitro_generator:\n    path: {gen_path}\n')
            new_lines.append('  build_runner: ^2.4.0\n')
            continue
        
        if in_deps or in_dev_deps:
            # Skip lines that are already nitro-related to avoid duplicates
            if any(x in stripped for x in ['nitro:', 'nitro_annotations:', 'nitro_generator:', 'build_runner:', 'ffigen:']):
                continue
            # Also skip nested path/version lines for those deps
            if (line.startswith('    path:') or line.startswith('    sdk:') or line.startswith('    version:')) and len(new_lines) > 0 and any(x in new_lines[-1] for x in ['nitro:', 'nitro_annotations:', 'nitro_generator:', 'ffigen:']):
                 continue
            
            if stripped == '' or line.startswith('  '):
                new_lines.append(line)
                continue
            else:
                in_deps = False
                in_dev_deps = False
        
        new_lines.append(line)

    # Add overrides at the end
    new_lines.append('\ndependency_overrides:\n')
    new_lines.append(f'  nitro:\n    path: {nitro_path}\n')
    new_lines.append(f'  nitro_generator:\n    path: {gen_path}\n')
    new_lines.append(f'  nitro_annotations:\n    path: {ann_path}\n')

    with open(pubspec_path, 'w') as f:
        f.writelines(new_lines)

    print(f'  ✔ {pubspec_path} patched')

patch_pubspec(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
# Also patch example if it exists
example_path = os.path.join(os.path.dirname(sys.argv[1]), 'example', 'pubspec.yaml')
if os.path.exists(example_path):
    patch_pubspec(example_path, sys.argv[2], sys.argv[3], sys.argv[4])
PYEOF

# ── 3. Write a minimal .native.dart spec ─────────────────────────────────────
echo "▶ Step 2b: Writing bridge spec ..."
mkdir -p "$PLUGIN_DIR/lib/src"
CLASS_NAME="$(python3 -c "print(''.join(w.capitalize() for w in '$PLUGIN_NAME'.split('_')))")"
python3 - "$PLUGIN_DIR/lib/src/$PLUGIN_NAME.native.dart" "$CLASS_NAME" "$PLUGIN_NAME" << 'PYEOF'
import sys
import os
path, className, pluginName = sys.argv[1], sys.argv[2], sys.argv[3]
content = f"""import 'package:nitro/nitro.dart';

part '{pluginName}.g.dart';

@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.cpp,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class {className}Spec extends HybridObject {{
  static final {className}Spec instance = _{className}SpecImpl();

  double add(double a, double b);

  @NitroAsync()
  Future<String> getGreeting(String name);
}}
"""
with open(path, 'w') as f:
    f.write(content)
print(f'  ✔ {path} written')
PYEOF
echo "  ✔ bridge spec written"

# ── 3b. Overwrite plugin entry point ─────────────────────────────────────────
echo "▶ Step 2c: Overwriting $PLUGIN_NAME.dart entry point ..."
cat > "$PLUGIN_DIR/lib/$PLUGIN_NAME.dart" << DARTEOF
export 'src/$PLUGIN_NAME.native.dart';
DARTEOF

# ── 3c. Overwrite example main ───────────────────────────────────────────────
echo "▶ Step 2d: Overwriting example/lib/main.dart ..."
cat > "$PLUGIN_DIR/example/lib/main.dart" << DARTEOF
import 'package:flutter/material.dart';
import 'package:$PLUGIN_NAME/$PLUGIN_NAME.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Nitro Test')),
        body: Center(
          child: FutureBuilder<String>(
            future: ${CLASS_NAME}Spec.instance.getGreeting('Nitro'),
            builder: (context, snapshot) {
              if (snapshot.hasData) return Text(snapshot.data!);
              return const CircularProgressIndicator();
            },
          ),
        ),
      ),
    );
  }
}
DARTEOF

# ── 3d. Purge legacy FFI boilerplate ────────────────────────────────────────
echo "▶ Step 2e: Purging legacy FFI boilerplate ..."
rm -f "$PLUGIN_DIR/lib/${PLUGIN_NAME}_bindings_generated.dart"
rm -rf "$PLUGIN_DIR/src"
rm -f "$PLUGIN_DIR/ffigen.yaml"

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
