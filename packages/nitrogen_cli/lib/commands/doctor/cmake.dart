part of '../doctor_command.dart';

extension _DoctorCmakeChecks on DoctorCommand {
  void _checkCmake(_DoctorCtx ctx) {
    final cmakeSec = DoctorSection('CMakeLists.txt');
    ctx.sections.add(cmakeSec);
    final cmakeFile = File(p.join(ctx.root.path, 'src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      ctx.err(cmakeSec, 'src/CMakeLists.txt not found', hint: 'Run: nitrogen link');
    } else {
      ctx.checkFilePermissions(cmakeSec, cmakeFile, 'src/CMakeLists.txt');
      // `add_library(${NITRO_MODULE_NAME} …)` names the same target as
      // `add_library(nitro_view …)`: expand plain `set(VAR value)` variables.
      final cmake = _expandCmakeVars(cmakeFile.readAsStringSync());
      // Check for redundant includes in nearby C++ files
      final srcDir = Directory(p.join(ctx.root.path, 'src'));
      final cppFiles = srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c')).toList();
      for (final f in cppFiles) {
        final c = f.readAsStringSync();
        if (c.contains('.bridge.g.cpp') || c.contains('.bridge.g.c')) {
          ctx.err(cmakeSec, 'Redundant bridge include in ${p.basename(f.path)}', hint: 'Remove #include "...bridge.g.cpp" from your source file');
        }
      }

      if (cmake.contains('NITRO_NATIVE')) {
        ctx.ok(cmakeSec, 'NITRO_NATIVE variable defined');
      } else {
        ctx.warn(cmakeSec, 'NITRO_NATIVE variable missing (incorrect dart_api_dl.c path)', hint: 'Run: nitrogen link');
      }
      if (cmake.contains('dart_api_dl.c')) {
        ctx.ok(cmakeSec, 'dart_api_dl.c included');
      } else {
        ctx.err(cmakeSec, 'dart_api_dl.c not included', hint: 'Run: nitrogen link');
      }

      // Build a lookup: impl file name → whether it's a native-cpp (android/linux)
      // module so we can skip “unlinked source” warnings for files that are
      // intentionally absent from the Android CMakeLists.txt (windows-only cpp).
      final nativeCppImplFiles = <String>{};
      for (final spec in ctx.specs) {
        if (!isNativeCppModule(spec)) continue;
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
        final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
        nativeCppImplFiles.add('Hybrid$moduleName.cpp');
      }

      // Check for unlinked source files in src/.
      // Skip HybridXxx.cpp files for modules that are NOT native-cpp (android/linux) —
      // e.g. a module that is only C++ on Windows has its impl in windows/CMakeLists.txt.
      final allSrcFiles = srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c')).toList();
      for (final f in allSrcFiles) {
        final name = p.basename(f.path);
        if (name == 'dart_api_dl.c') continue;
        if (name == '${ctx.pluginName}.cpp' || name == '${ctx.pluginName}.c') continue;
        // Hybrid impl files for windows-only cpp modules don’t belong in the
        // Android/Linux CMakeLists — skip them to avoid a false-positive warning.
        if (name.startsWith('Hybrid') && name.endsWith('.cpp') && !nativeCppImplFiles.contains(name)) continue;

        if (!cmake.contains('"$name"') && !cmake.contains(' $name ') && !cmake.contains('\n  $name')) {
          ctx.warn(cmakeSec, 'Unlinked source: $name', hint: 'File found in src/ but not mentioned in CMakeLists.txt');
        }
      }

      for (final spec in ctx.specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (cmake.contains('add_library($lib ')) {
          ctx.ok(cmakeSec, 'add_library($lib) target present');

          // Verify HybridXxx.cpp is linked for native-cpp (android/linux) modules.
          // Windows-only cpp modules do NOT need this in src/CMakeLists.txt.
          if (isNativeCppModule(spec)) {
            final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
            final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
            // The impl is whichever compiled source subclasses Hybrid<Module>;
            // its file name is the user's choice (HybridNitroHttp.cpp can
            // implement HybridNitroHttpNative).
            if (!_cmakeCompilesSubclassOf(cmake, ctx.root.path, 'Hybrid$moduleName')) {
              ctx.err(
                cmakeSec,
                '$lib: no source in src/CMakeLists.txt implements Hybrid$moduleName',
                hint: 'Add the file with `class … : public Hybrid$moduleName` to the $lib target',
              );
            }
          }
        } else {
          ctx.err(cmakeSec, 'add_library($lib) missing', hint: 'Run: nitrogen link');
        }
      }
    }
  }
}

/// Replaces `${VAR}` with its value for every plain `set(VAR value)` in [cmake].
String _expandCmakeVars(String cmake) {
  for (final m in RegExp(r'^\s*set\(\s*(\w+)\s+([\w.-]+)\s*\)', multiLine: true).allMatches(cmake).toList()) {
    cmake = cmake.replaceAll('\${${m.group(1)}}', m.group(2)!);
  }
  return cmake;
}

/// True when a compiled `.cpp` declares a class deriving from [base]: a file
/// src/CMakeLists [cmake] names, or a desktop impl a platform CMakeLists
/// selects with `set(NITRO_IMPL_SRC_<lib> "${CMAKE_CURRENT_SOURCE_DIR}/…")`.
bool _cmakeCompilesSubclassOf(String cmake, String root, String base) {
  final derives = RegExp('public\\s+${RegExp.escape(base)}\\b');
  final candidates = [
    for (final m in RegExp(r'([\w./-]+\.cpp)\b').allMatches(cmake)) p.join(root, 'src', p.basename(m.group(1)!)),
    for (final platform in ['linux', 'windows'])
      if (File(p.join(root, platform, 'CMakeLists.txt')) case final f when f.existsSync())
        for (final m in RegExp(r'NITRO_IMPL_SRC_\w+\s+"\$\{CMAKE_CURRENT_SOURCE_DIR\}/([^"]+)"').allMatches(f.readAsStringSync()))
          p.join(root, platform, m.group(1)!),
  ];
  return candidates.any((path) => File(path).existsSync() && derives.hasMatch(File(path).readAsStringSync()));
}

