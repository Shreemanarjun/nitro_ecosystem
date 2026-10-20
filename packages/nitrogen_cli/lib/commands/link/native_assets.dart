part of '../link_command.dart';

// Native-assets build-hook linking (perf lever 1 / v0.8.0). When a plugin opts
// into the native-assets path (`nitrogen generate --native-assets`), the
// generated Dart resolves C symbols via top-level `@Native` externals against a
// code asset built by `hook/build.dart` — instead of DynamicLibrary at runtime.
// This step writes that hook, vendors nitro's C runtime next to it, and adds
// the build-time hook dependencies to the plugin's pubspec.

/// Writes `hook/build.dart`, vendors nitro's C sources/headers into
/// `src/nitro_native/`, and injects the hook deps into `pubspec.yaml` for the
/// single all-C++ module in [moduleInfos]. No-op when there's no C++ module.
void linkNativeAssetsHook(
  List<ModuleInfo> moduleInfos,
  String nitroNativePath, {
  String baseDir = '.',
}) {
  final cppModules = moduleInfos.where((m) => m.isCpp).toList();
  if (cppModules.isEmpty) return;

  // 1. Vendor nitro's C sources + headers next to the hook so CBuilder finds
  //    them package-relative (mirrors how linkCMake copies nitro.h into include
  //    dirs). Portable: no machine-specific absolute path baked into the hook.
  //    Shared by every module's asset.
  final vendorDir = Directory(p.join(baseDir, 'src', 'nitro_native'))..createSync(recursive: true);
  final nitroNative = Directory(nitroNativePath);
  for (final name in [...nativeAssetsVendoredCSources, ...nativeAssetsVendoredHeaders]) {
    final src = File(p.join(nitroNative.path, name));
    if (src.existsSync()) src.copySync(p.join(vendorDir.path, name));
  }
  final internalSrc = Directory(p.join(nitroNative.path, 'internal'));
  if (internalSrc.existsSync()) {
    final internalDst = Directory(p.join(vendorDir.path, 'internal'))..createSync(recursive: true);
    for (final f in internalSrc.listSync().whereType<File>()) {
      f.copySync(p.join(internalDst.path, p.basename(f.path)));
    }
  }

  // 2. One code asset per C++ module. The impl path is included UNCONDITIONALLY
  //    (the user's impl, same convention as CMake's target_sources) — it may not
  //    exist yet at link time (chicken-and-egg: hook is written during generate,
  //    impl written after). The generated <lib>.impl.g.cpp starter guides the
  //    user; the build errors clearly if src/HybridXxx.cpp is absent.
  final modules = [
    for (final mod in cppModules)
      (
        libStem: mod.lib.replaceAll('-', '_'),
        cppSources: <String>[
          'lib/src/generated/cpp/${mod.lib}.bridge.g.cpp',
          'src/Hybrid${mod.module}.cpp',
        ],
      ),
  ];

  // 3. hook/build.dart (one CBuilder.library per module)
  Directory(p.join(baseDir, 'hook')).createSync(recursive: true);
  File(p.join(baseDir, 'hook', 'build.dart')).writeAsStringSync(buildHookDart(modules: modules));

  // 4. pubspec hook deps (regular dependencies — consumers run the hook).
  injectNativeAssetsPubspecDeps(p.join(baseDir, 'pubspec.yaml'));

  stdout.writeln('  native-assets: wrote hook/build.dart + vendored nitro C runtime '
      '(asset${modules.length == 1 ? '' : 's'}: ${modules.map((m) => m.libStem).join(', ')})');
}

/// Adds any missing [nativeAssetsHookDeps] under the `dependencies:` block of
/// the pubspec at [pubspecPath]. Returns true if the file was changed.
bool injectNativeAssetsPubspecDeps(String pubspecPath) {
  final f = File(pubspecPath);
  if (!f.existsSync()) return false;
  var content = f.readAsStringSync();
  final missing = nativeAssetsHookDeps.entries
      .where((e) => !RegExp('^  ${e.key}:', multiLine: true).hasMatch(content))
      .toList();
  if (missing.isEmpty) return false;
  final depsMatch = RegExp(r'^dependencies:[ \t]*$', multiLine: true).firstMatch(content);
  if (depsMatch == null) return false;
  final insert = '\n${missing.map((e) => '  ${e.key}: ${e.value}').join('\n')}';
  content = content.replaceRange(depsMatch.end, depsMatch.end, insert);
  f.writeAsStringSync(content);
  return true;
}
