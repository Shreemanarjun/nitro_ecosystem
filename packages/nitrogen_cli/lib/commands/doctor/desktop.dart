part of '../doctor_command.dart';

extension _DoctorDesktopChecks on DoctorCommand {
  void _checkWindows(_DoctorCtx ctx, String srcCmakeContent) {
    final winSec = DoctorSection('Windows');
    ctx.sections.add(winSec);
    final winDir = Directory(p.join(ctx.root.path, 'windows'));
    if (!winDir.existsSync()) {
      ctx.info(winSec, 'windows/ directory not present — skipped');
    } else {
      final cmakeFile = File(p.join(winDir.path, 'CMakeLists.txt'));
      if (!cmakeFile.existsSync()) {
        ctx.err(winSec, 'windows/CMakeLists.txt not found', hint: 'Run: nitrogen link');
      } else {
        ctx.checkFilePermissions(winSec, cmakeFile, 'windows/CMakeLists.txt');
        final cmake = cmakeFile.readAsStringSync();
        final sharedSrc = _usesSharedSrc(cmake);
        // For NITRO_NATIVE, check both the platform file and src/CMakeLists.
        if (cmake.contains('NITRO_NATIVE') || (sharedSrc && srcCmakeContent.contains('NITRO_NATIVE'))) {
          ctx.ok(winSec, 'NITRO_NATIVE variable defined in windows/CMakeLists.txt');
        } else {
          ctx.err(winSec, 'NITRO_NATIVE missing in windows/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        // dart_api_dl.c: accept if present in platform file OR in src/ (via add_subdirectory).
        if (cmake.contains('dart_api_dl.c') || (sharedSrc && srcCmakeContent.contains('dart_api_dl.c'))) {
          ctx.ok(winSec, sharedSrc ? 'dart_api_dl.c compiled via src/CMakeLists.txt (add_subdirectory)' : 'dart_api_dl.c included in windows/CMakeLists.txt');
        } else {
          ctx.err(winSec, 'dart_api_dl.c not included in windows/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        for (final spec in ctx.specs) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          final bridgeRel = '../lib/src/generated/cpp/$lib.bridge.g.cpp';
          // Accept if the bridge is in the platform file, or in src/CMakeLists (shared build).
          final inSrc = sharedSrc && (srcCmakeContent.contains('$lib.bridge.g.cpp') || srcCmakeContent.contains(bridgeRel));
          if (cmake.contains(bridgeRel) || inSrc) {
            ctx.ok(winSec, sharedSrc ? '$lib.bridge.g.cpp compiled via src/CMakeLists.txt' : '$lib.bridge.g.cpp linked in windows/CMakeLists.txt');
          } else {
            ctx.warn(winSec, '$lib.bridge.g.cpp not linked in windows/CMakeLists.txt', hint: 'Run: nitrogen link');
          }
        }
        // Multi-spec plugins with their own registrant target must expose
        // include/ via INTERFACE, or generated_plugin_registrant.cc in the
        // example app fails with "Cannot open include file: '<pkg>/<pkg>_plugin...h'".
        if (sharedSrc && _hasOwnPluginTarget(cmake) && Directory(p.join(winDir.path, 'include')).existsSync()) {
          final exposed = RegExp(r'target_include_directories\(\s*\$\{PLUGIN_NAME\}\s+INTERFACE[^)]*\/include').hasMatch(cmake);
          if (exposed) {
            ctx.ok(winSec, 'Registrant include/ dir exposed via target_include_directories(\${PLUGIN_NAME} INTERFACE ...)');
          } else {
            ctx.err(
              winSec,
              'Registrant include/ dir not exposed on \${PLUGIN_NAME} — generated_plugin_registrant.cc will fail to find the plugin header',
              hint: 'Run: nitrogen link',
            );
          }
        }
      }
    }
  }

  void _checkLinux(_DoctorCtx ctx, String srcCmakeContent) {
    final linuxSec = DoctorSection('Linux');
    ctx.sections.add(linuxSec);
    final linuxDir = Directory(p.join(ctx.root.path, 'linux'));
    if (!linuxDir.existsSync()) {
      ctx.info(linuxSec, 'linux/ directory not present — skipped');
    } else {
      final cmakeFile = File(p.join(linuxDir.path, 'CMakeLists.txt'));
      if (!cmakeFile.existsSync()) {
        ctx.err(linuxSec, 'linux/CMakeLists.txt not found', hint: 'Run: nitrogen link');
      } else {
        ctx.checkFilePermissions(linuxSec, cmakeFile, 'linux/CMakeLists.txt');
        final cmake = cmakeFile.readAsStringSync();
        final sharedSrc = _usesSharedSrc(cmake);
        if (cmake.contains('NITRO_NATIVE') || (sharedSrc && srcCmakeContent.contains('NITRO_NATIVE'))) {
          ctx.ok(linuxSec, 'NITRO_NATIVE variable defined in linux/CMakeLists.txt');
        } else {
          ctx.err(linuxSec, 'NITRO_NATIVE missing in linux/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        if (cmake.contains('dart_api_dl.c') || (sharedSrc && srcCmakeContent.contains('dart_api_dl.c'))) {
          ctx.ok(linuxSec, sharedSrc ? 'dart_api_dl.c compiled via src/CMakeLists.txt (add_subdirectory)' : 'dart_api_dl.c included in linux/CMakeLists.txt');
        } else {
          ctx.err(linuxSec, 'dart_api_dl.c not included in linux/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        for (final spec in ctx.specs) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          final bridgeRel = '../lib/src/generated/cpp/$lib.bridge.g.cpp';
          final inSrc = sharedSrc && (srcCmakeContent.contains('$lib.bridge.g.cpp') || srcCmakeContent.contains(bridgeRel));
          if (cmake.contains(bridgeRel) || inSrc) {
            ctx.ok(linuxSec, sharedSrc ? '$lib.bridge.g.cpp compiled via src/CMakeLists.txt' : '$lib.bridge.g.cpp linked in linux/CMakeLists.txt');
          } else {
            ctx.warn(linuxSec, '$lib.bridge.g.cpp not linked in linux/CMakeLists.txt', hint: 'Run: nitrogen link');
          }
        }
        // Multi-spec plugins with their own registrant target must expose
        // include/ via INTERFACE, or generated_plugin_registrant.cc in the
        // example app fails with "fatal error: '<pkg>/<pkg>_plugin.h' file not found".
        if (sharedSrc && _hasOwnPluginTarget(cmake) && Directory(p.join(linuxDir.path, 'include')).existsSync()) {
          final exposed = RegExp(r'target_include_directories\(\s*\$\{PLUGIN_NAME\}\s+INTERFACE[^)]*\/include').hasMatch(cmake);
          if (exposed) {
            ctx.ok(linuxSec, 'Registrant include/ dir exposed via target_include_directories(\${PLUGIN_NAME} INTERFACE ...)');
          } else {
            ctx.err(
              linuxSec,
              'Registrant include/ dir not exposed on \${PLUGIN_NAME} — generated_plugin_registrant.cc will fail to find the plugin header',
              hint: 'Run: nitrogen link',
            );
          }
        }
      }
    }
  }

  /// Desktop plugins keep hand-maintained copies of the C++ impl under
  /// `linux/src/` and `windows/src/` (the desktop CMake compiles those, not
  /// `src/`). A method added to the spec lands in `src/` and silently misses
  /// the copies, so the desktop build fails to instantiate the abstract impl —
  /// far from the edit that caused it. The generated header is the contract.
  void _checkDesktopImplParity(_DoctorCtx ctx) {
    final sec = DoctorSection('Desktop C++ impl parity');
    final copies = [
      for (final d in ['linux', 'windows'])
        if (Directory(p.join(ctx.root.path, d, 'src')).existsSync()) d,
    ];
    if (copies.isEmpty) return; // no desktop copies to drift
    ctx.sections.add(sec);

    final pureVirtual = RegExp(r'^\s*virtual\s+.*?\b(\w+)\s*\([^;]*\)\s*=\s*0\s*;', multiLine: true);
    final override = RegExp(r'^\s*[\w:<>&,\s\*]+?\b(\w+)\s*\([^;{]*\)\s*(?:const\s+)?override\b', multiLine: true);
    Set<String> names(RegExp re, File f) => re.allMatches(f.readAsStringSync()).map((m) => m.group(1)!).toSet();

    for (final header in Directory(p.join(ctx.root.path, 'lib', 'src', 'generated', 'cpp'))
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.native.g.h'))) {
      final required = names(pureVirtual, header);
      if (required.isEmpty) continue;
      final stem = p.basename(header.path).replaceAll('.native.g.h', '');
      for (final copy in copies) {
        final impls = Directory(p.join(ctx.root.path, copy, 'src')).listSync().whereType<File>().where((f) => f.path.endsWith('.cpp'));
        if (impls.isEmpty) continue;
        final implemented = <String>{for (final f in impls) ...names(override, f)};
        final missing = required.difference(implemented).toList()..sort();
        if (missing.isEmpty) {
          ctx.ok(sec, '$copy/src implements every $stem spec method');
        } else {
          ctx.err(
            sec,
            '$copy/src is missing ${missing.length} $stem method(s): ${missing.take(5).join(', ')}${missing.length > 5 ? ' …' : ''}',
            hint: 'Copy the new override(s) from src/ — the desktop build cannot instantiate an abstract impl',
          );
        }
      }
    }
  }

  void _checkCppDirect(_DoctorCtx ctx) {
    final cppSec = DoctorSection('NativeImpl.cpp Direct Implementation');
    ctx.sections.add(cppSec);

    for (final spec in ctx.specs.where(isCppModule)) {
      final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
      final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
      final parsedSegments = stem.split('_').where((w) => w.isNotEmpty).toList();
      final fallbackName = parsedSegments.isNotEmpty ? parsedSegments.map((w) => w[0].toUpperCase() + w.substring(1)).join('') : lib;
      final moduleName = moduleMatch?.group(1) ?? fallbackName;

      // Check if user has a C++ impl file in src/ (anything that isn't generated or dart_api_dl)
      final srcDir = Directory(p.join(ctx.root.path, 'src'));
      final cppImplFiles = srcDir.existsSync()
          ? srcDir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.cpp') && !f.path.contains('.bridge.g.') && !f.path.contains('.test.g.') && !f.path.contains('dart_api_dl'))
                .toList()
          : <File>[];

      if (cppImplFiles.isNotEmpty) {
        // Check if any impl file registers the implementation
        final anyRegisters = cppImplFiles.any((f) => f.readAsStringSync().contains('${lib}_register_impl'));
        if (anyRegisters) {
          ctx.ok(cppSec, '$lib: ${lib}_register_impl() wired up in user impl');
        } else {
          ctx.warn(cppSec, '$lib: ${lib}_register_impl(&impl) not found in src/', hint: 'Call ${lib}_register_impl(&impl) at startup before first Dart use');
        }
      } else {
        ctx.info(cppSec, '$lib: Create src/Hybrid$moduleName.cpp, subclass Hybrid$moduleName, then call ${lib}_register_impl(&impl)');
      }

      // Check .clangd includes the test/ directory (for GoogleMock IDE support)
      final clangdFile = File(p.join(ctx.root.path, '.clangd'));
      if (clangdFile.existsSync() && clangdFile.readAsStringSync().contains('generated/cpp/test')) {
        ctx.ok(cppSec, '.clangd includes generated/cpp/test/ (GoogleMock IDE support)');
      } else {
        ctx.info(cppSec, 'Run: nitrogen link (adds generated/cpp/test/ to .clangd for IDE mock support)');
      }
    }
  }

  void _checkCocoaPodsPermissions(_DoctorCtx ctx) {
    final podfiles = [
      File(p.join(ctx.root.path, 'ios', 'Podfile')),
      File(p.join(ctx.root.path, 'macos', 'Podfile')),
    ].where((f) => f.existsSync()).toList();
    if (podfiles.isNotEmpty) {
      final podsSec = DoctorSection('CocoaPods Permissions');
      ctx.sections.add(podsSec);
      for (final podfile in podfiles) {
        final rel = p.relative(podfile.path, from: ctx.root.path);
        ctx.checkFilePermissions(podsSec, podfile, rel);
        ctx.ok(podsSec, '$rel present');
      }
    }
  }

  void _checkExampleApp(_DoctorCtx ctx) {
    // ── Example App CocoaPods/SPM conflict ─────────────────────────────────────
    // Detects the broken state where example/ios (or example/macos) has
    // project.pbxproj references to Pods_Runner.framework but no Podfile —
    // causing "Framework 'Pods_Runner' not found" at build time.
    if (Platform.isMacOS) {
      final exampleDir = Directory(p.join(ctx.root.path, 'example'));
      if (exampleDir.existsSync()) {
        final exSec = DoctorSection('Example App (CocoaPods/SPM)');
        ctx.sections.add(exSec);

        for (final platform in ['ios', 'macos']) {
          final platformDir = Directory(p.join(exampleDir.path, platform));
          if (!platformDir.existsSync()) {
            ctx.info(exSec, 'example/$platform/ not present — skipped');
            continue;
          }

          // Find project.pbxproj
          final xcodeprojDirs = platformDir.listSync().whereType<Directory>().where((d) => d.path.endsWith('.xcodeproj')).toList();
          if (xcodeprojDirs.isEmpty) {
            ctx.info(exSec, 'example/$platform/: no .xcodeproj found — skipped');
            continue;
          }
          final pbxproj = File(p.join(xcodeprojDirs.first.path, 'project.pbxproj'));
          if (!pbxproj.existsSync()) {
            ctx.info(exSec, 'example/$platform/: project.pbxproj not found — skipped');
            continue;
          }

          final pbxContent = pbxproj.readAsStringSync();
          final hasPodsRunner = pbxContent.contains('Pods_Runner.framework');
          final podfile = File(p.join(platformDir.path, 'Podfile'));
          final hasPodfile = podfile.existsSync();
          final podfileLock = File(p.join(platformDir.path, 'Podfile.lock'));
          final hasPodfileLock = podfileLock.existsSync();

          if (!hasPodsRunner) {
            ctx.ok(exSec, 'example/$platform/: no Pods_Runner.framework reference (clean SPM-only setup)');
          } else if (!hasPodfile) {
            ctx.err(
              exSec,
              'example/$platform/: project.pbxproj references Pods_Runner.framework but Podfile is missing',
              hint: hasPodfileLock
                  ? 'Podfile.lock exists but Podfile was deleted. Recreate it then run: cd example/$platform && pod install'
                  : 'Run: flutter pub get  (regenerates Podfile), then: cd example/$platform && pod install',
            );
          } else {
            // Podfile exists — check if Pods have been installed (framework built)
            final podsDir = Directory(p.join(platformDir.path, 'Pods'));
            final podsBuilt = podsDir.existsSync() && podsDir.listSync().whereType<Directory>().any((d) => d.path.contains('Pods.xcodeproj'));
            if (podsBuilt) {
              ctx.ok(exSec, 'example/$platform/: Podfile present and pods installed');
            } else {
              ctx.warn(
                exSec,
                'example/$platform/: Podfile present but pods not installed',
                hint: 'Run: cd example/$platform && pod install',
              );
            }
          }
        }
      }
    }
  }
}
