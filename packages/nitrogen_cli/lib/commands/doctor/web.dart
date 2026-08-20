part of '../doctor_command.dart';

extension _DoctorWebChecks on DoctorCommand {
  /// Web (WASM) target health: emsdk availability, build wiring, artifact
  /// presence/staleness, and the pubspec web + assets declarations.
  void _checkWeb(_DoctorCtx ctx) {
    // Only meaningful when some spec targets web.
    final webSpecs = ctx.specs.where((spec) => PlatformTargetAnalyzer.fromSpec(spec).supportsWeb).toList();
    if (webSpecs.isEmpty) return;

    final webSec = DoctorSection('Web (WASM)');
    ctx.sections.add(webSec);

    // Toolchain: em++ on PATH.
    final emxx = Process.runSync('sh', ['-c', 'command -v em++'], runInShell: Platform.isWindows);
    if (emxx.exitCode == 0) {
      ctx.ok(webSec, 'em++ found (${(emxx.stdout as String).trim()})');
    } else {
      ctx.warn(
        webSec,
        'em++ not on PATH — the WASM module cannot be built',
        hint: 'Install the Emscripten SDK and `source emsdk_env.sh` (https://emscripten.org)',
      );
    }

    // Build script.
    final script = File(p.join(ctx.root.path, 'web', 'build_web.sh'));
    if (script.existsSync()) {
      ctx.ok(webSec, 'web/build_web.sh present');
    } else {
      ctx.err(webSec, 'web/build_web.sh missing', hint: 'Run: nitrogen link');
    }

    // Pubspec: web platforms entry + bundled assets.
    final pubspecFile = File(p.join(ctx.root.path, 'pubspec.yaml'));
    final pubspec = pubspecFile.existsSync() ? pubspecFile.readAsStringSync() : '';
    if (RegExp(r'\n      web:\n').hasMatch(pubspec)) {
      ctx.ok(webSec, 'pubspec platforms: declares web');
    } else {
      ctx.warn(webSec, 'pubspec plugin platforms: has no web entry', hint: 'Add `web: {pluginClass: <Class>WebPlugin, fileName: <plugin>_web.dart}` (nitrogen init --platforms=...,web scaffolds this)');
    }
    if (pubspec.contains('assets/web/')) {
      ctx.ok(webSec, 'assets/web/ declared under flutter: assets:');
    } else {
      ctx.warn(webSec, 'assets/web/ not declared as a Flutter asset — the WASM module will 404 at runtime', hint: 'Add `flutter:\n  assets:\n    - assets/web/` to pubspec.yaml');
    }

    // Artifacts: present + not older than the generated bridge.
    for (final spec in webSpecs) {
      final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
      final js = File(p.join(ctx.root.path, 'assets', 'web', '$lib.js'));
      final wasm = File(p.join(ctx.root.path, 'assets', 'web', '$lib.wasm'));
      if (!js.existsSync() || !wasm.existsSync()) {
        ctx.warn(webSec, '$lib.js / $lib.wasm not built in assets/web/', hint: 'Run: web/build_web.sh (needs emsdk)');
        continue;
      }
      final bridge = File(p.join(ctx.root.path, 'lib', 'src', 'generated', 'cpp', '$lib.bridge.g.cpp'));
      if (bridge.existsSync() && wasm.lastModifiedSync().isBefore(bridge.lastModifiedSync())) {
        ctx.warn(webSec, '$lib.wasm is older than $lib.bridge.g.cpp — stale build', hint: 'Re-run web/build_web.sh after `nitrogen generate`');
      } else {
        ctx.ok(webSec, '$lib.js + $lib.wasm built and current');
      }
    }
  }
}
