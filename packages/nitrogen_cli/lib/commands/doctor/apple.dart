part of '../doctor_command.dart';

extension _DoctorAppleChecks on DoctorCommand {
  void _checkAppleSpm(_DoctorCtx ctx, SpmStatus spmStatus) {
    if (Platform.isMacOS) {
      final spmSec = DoctorSection('Apple SPM (Swift Package Manager)');
      ctx.sections.add(spmSec);

      if (spmStatus.hasSpm) {
        if (spmStatus.isModern) {
          ctx.ok(spmSec, 'SPM-only setup (modern)');
        } else if (spmStatus.isMixed) {
          ctx.warn(spmSec, 'Mixed SPM + CocoaPods setup', hint: 'Run: nitrogen migrate  to complete SPM migration');
        }

        if (spmStatus.iosHasSpm) {
          final path = spmStatus.iosPackageSwiftPath!;
          final rel = p.relative(path, from: ctx.root.path);
          ctx.ok(spmSec, 'iOS: $rel');

          // Detect flat vs nested layout
          final segments = p.split(p.relative(p.dirname(path), from: ctx.root.path));
          if (segments.length >= 2 && segments[0] == 'ios') {
            ctx.ok(spmSec, 'iOS using Flutter 3.41+ nested SPM layout');
          } else {
            ctx.warn(spmSec, 'iOS using flat SPM layout (ios/Package.swift)', hint: 'Run: nitrogen migrate  to upgrade to nested Flutter 3.41+ layout');
          }

          // Check the FlutterFramework path resolves from this Package.swift.
          // The path is only valid after `flutter pub get` runs in the example app.
          if (!flutterFrameworkPathExists(path)) {
            ctx.warn(
              spmSec,
              'iOS Package.swift: FlutterFramework path does not resolve — Xcode will report "Unable to resolve module dependency: Flutter"',
              hint: 'Run: nitrogen link  (creates a symlink), or run flutter pub get in example/ first',
            );
          } else {
            ctx.ok(spmSec, 'iOS Package.swift: FlutterFramework path resolves');
          }

          for (final issue in spmStatus.issues.where((i) => i.startsWith('ios'))) {
            ctx.err(spmSec, issue, hint: 'Run: nitrogen migrate');
          }
          for (final w in spmStatus.warnings.where((w) => w.startsWith('ios'))) {
            ctx.warn(spmSec, w);
          }
        } else {
          ctx.info(spmSec, 'iOS SPM not configured');
        }

        if (spmStatus.macosHasSpm) {
          final path = spmStatus.macosPackageSwiftPath!;
          final rel = p.relative(path, from: ctx.root.path);
          ctx.ok(spmSec, 'macOS: $rel');

          final segments = p.split(p.relative(p.dirname(path), from: ctx.root.path));
          if (segments.length >= 2 && segments[0] == 'macos') {
            ctx.ok(spmSec, 'macOS using Flutter 3.41+ nested SPM layout');
          } else {
            ctx.warn(spmSec, 'macOS using flat SPM layout (macos/Package.swift)', hint: 'Run: nitrogen migrate  to upgrade to nested Flutter 3.41+ layout');
          }

          if (!flutterFrameworkPathExists(path)) {
            ctx.warn(
              spmSec,
              'macOS Package.swift: FlutterFramework path does not resolve — Xcode will report "Unable to resolve module dependency: Flutter"',
              hint: 'Run: nitrogen link  (creates a symlink), or run flutter pub get in example/ first',
            );
          } else {
            ctx.ok(spmSec, 'macOS Package.swift: FlutterFramework path resolves');
          }

          for (final issue in spmStatus.issues.where((i) => i.startsWith('macos'))) {
            ctx.err(spmSec, issue, hint: 'Run: nitrogen migrate');
          }
          for (final w in spmStatus.warnings.where((w) => w.startsWith('macos'))) {
            ctx.warn(spmSec, w);
          }
        } else {
          ctx.info(spmSec, 'macOS SPM not configured');
        }
      } else if (spmStatus.hasCocoaPods) {
        ctx.err(spmSec, 'CocoaPods detected — no SPM configuration found', hint: 'Run: nitrogen migrate  to migrate to Swift Package Manager');
      } else {
        ctx.info(spmSec, 'No Apple platform directories found');
      }
    }
  }

  void _checkIos(_DoctorCtx ctx, SpmStatus spmStatus, bool allSpecsCpp, bool hasAnyNonCppSpec) {
    final iosSec = DoctorSection('iOS');
    ctx.sections.add(iosSec);
    final iosDir = Directory(p.join(ctx.root.path, 'ios'));
    if (!iosDir.existsSync()) {
      ctx.info(iosSec, 'ios/ directory not present — skipped');
      return;
    }
    _checkIosPodspec(ctx, iosSec, iosDir, allSpecsCpp);
    final classesDir = Directory(p.join(iosDir.path, 'Classes'));
    _checkIosSwiftBridge(ctx, iosSec, iosDir, classesDir, allSpecsCpp, hasAnyNonCppSpec);
    _checkIosDartApi(ctx, iosSec, iosDir, spmStatus);
    _checkIosMmBridges(ctx, iosSec, classesDir, allSpecsCpp, spmStatus);
    _checkIosSpm(ctx, iosSec, spmStatus);
  }

  void _checkIosPodspec(_DoctorCtx ctx, DoctorSection iosSec, Directory iosDir, bool allSpecsCpp) {
    final podFiles = iosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
    if (podFiles.isEmpty) {
      ctx.err(iosSec, 'No .podspec found in ios/', hint: 'Run: nitrogen init');
    } else {
      ctx.checkFilePermissions(
        iosSec,
        podFiles.first,
        p.relative(podFiles.first.path, from: ctx.root.path),
      );
      final pod = podFiles.first.readAsStringSync();
      final podName = p.basename(podFiles.first.path);
      if (pod.contains("s.dependency 'nitro'")) {
        ctx.ok(iosSec, "s.dependency 'nitro' in $podName");
      } else {
        ctx.err(iosSec, "s.dependency 'nitro' missing in $podName", hint: 'Run: nitrogen link');
      }
      if (pod.contains('HEADER_SEARCH_PATHS')) {
        ctx.ok(iosSec, 'HEADER_SEARCH_PATHS in $podName');
      } else {
        ctx.err(iosSec, 'HEADER_SEARCH_PATHS missing in $podName', hint: 'Run: nitrogen link');
      }
      if (pod.contains(BuildVersions.podCxxStandard)) {
        ctx.ok(iosSec, 'CLANG_CXX_LANGUAGE_STANDARD = ${BuildVersions.podCxxStandard}');
      } else {
        ctx.warn(
          iosSec,
          'CLANG_CXX_LANGUAGE_STANDARD not set to ${BuildVersions.podCxxStandard}',
          hint: "Set: 'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}' in pod_target_xcconfig",
        );
      }
      if (!allSpecsCpp) {
        // swift_version only relevant when Swift bridges are used
        if (pod.contains("swift_version = '${BuildVersions.podSwiftVersion}'") || pod.contains("swift_version = '6")) {
          ctx.ok(iosSec, 'swift_version >= ${BuildVersions.podSwiftVersion}');
        } else {
          ctx.warn(iosSec, 'swift_version may be too old', hint: "Set: s.swift_version = '${BuildVersions.podSwiftVersion}'");
        }
      }

      // Check for complete HEADER_SEARCH_PATHS
      if (pod.contains('lib/src/generated/cpp') && pod.contains('src/native')) {
        ctx.ok(iosSec, 'Comprehensive HEADER_SEARCH_PATHS in podspec');
      } else {
        ctx.warn(iosSec, 'Incomplete HEADER_SEARCH_PATHS in podspec', hint: 'Run: nitrogen link');
      }

      // Check source_files points to an existing path.
      // The SPM-first Flutter template generates paths like '<plugin>/Sources/<plugin>/**/*'
      // which are non-existent when CocoaPods is used, causing "No files found" warnings.
      final sourceFilesMatch = RegExp(r"s\.source_files\s*=\s*'([^']+)'").firstMatch(pod);
      if (sourceFilesMatch != null) {
        final sfPath = sourceFilesMatch.group(1)!;
        final firstSegment = sfPath.split('/').first;
        final firstDir = Directory(p.join(iosDir.path, firstSegment));
        if (firstSegment == 'Classes' || firstDir.existsSync()) {
          ctx.ok(iosSec, 'source_files path valid: $sfPath');
        } else {
          ctx.err(iosSec, 'source_files points to non-existent path: $sfPath', hint: "Run: nitrogen link  (fixes to 'Classes/**/*')");
        }
      }
    }
  }

  void _checkIosSwiftBridge(_DoctorCtx ctx, DoctorSection iosSec, Directory iosDir, Directory classesDir, bool allSpecsCpp, bool hasAnyNonCppSpec) {
    if (allSpecsCpp) {
      // All C++ modules — no Swift Registry.register() needed.
      ctx.info(iosSec, 'All modules use NativeImpl.cpp — Swift bridge (Registry.register) not required');
      // .native.g.h uses C++ types (std::string, classes) and must NOT be placed in
      // ios/Classes/ — CocoaPods includes every header there into the umbrella header
      // which breaks Swift/ObjC compilation. It is reachable via HEADER_SEARCH_PATHS.
      // Verify that HEADER_SEARCH_PATHS includes lib/src/generated/cpp/ instead.
      final podFiles = iosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
      if (podFiles.isNotEmpty) {
        final pod = podFiles.first.readAsStringSync();
        if (pod.contains('lib/src/generated/cpp')) {
          ctx.ok(iosSec, '*.native.g.h reachable via HEADER_SEARCH_PATHS → lib/src/generated/cpp');
        } else {
          ctx.warn(iosSec, 'HEADER_SEARCH_PATHS may not include lib/src/generated/cpp (needed for *.native.g.h)', hint: 'Run: nitrogen link');
        }
      }
    } else {
      final swiftFiles = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('Plugin.swift')).toList() : <File>[];
      if (swiftFiles.isEmpty) {
        ctx.err(iosSec, 'No *Plugin.swift in ios/Classes/', hint: 'Run: nitrogen init');
      } else {
        final swift = swiftFiles.first.readAsStringSync();
        if (hasAnyNonCppSpec) {
          if (swift.contains('Registry.register(') || swift.contains('.register(')) {
            ctx.ok(iosSec, 'Plugin.swift has Registry.register(...)');
          } else {
            ctx.warn(iosSec, 'Registry.register(...) not found in Plugin.swift', hint: 'Add: NitroModules.Registry.register(...) in register(with:)');
          }
        } else {
          ctx.info(iosSec, 'Registry.register not needed — all modules use NativeImpl.cpp');
        }

        // Check for stale XxxRegistry.register() calls for C++ modules.
        // AppleNativeImpl.cpp modules have no Swift Registry — the call causes
        // "Cannot find 'XxxRegistry' in scope". nitrogen link auto-removes these.
        for (final spec in ctx.specs.where(isCppModule)) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
          final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
          if (swift.contains('${moduleName}Registry.register(')) {
            ctx.err(
              iosSec,
              'Stale ${moduleName}Registry.register() in Plugin.swift — $moduleName is now NativeImpl.cpp',
              hint: 'Run: nitrogen link  (auto-removes stale Swift registry calls for C++ modules)',
            );
          }
        }
      }
    }
  }

  void _checkIosDartApi(_DoctorCtx ctx, DoctorSection iosSec, Directory iosDir, SpmStatus spmStatus) {
    // ── dart_api_dl.c / nitro.h ─────────────────────────────────────────────
    // For SPM builds (Flutter 3.22+) these files live in Sources/<PluginCpp>/,
    // not ios/Classes/. Only check ios/Classes/ when there is no Package.swift.
    if (!spmStatus.iosHasSpm) {
      final dartApiDl = File(p.join(iosDir.path, 'Classes', 'dart_api_dl.c'));
      if (dartApiDl.existsSync()) {
        ctx.ok(iosSec, 'ios/Classes/dart_api_dl.c present');
      } else {
        ctx.err(iosSec, 'ios/Classes/dart_api_dl.c missing', hint: 'Run: nitrogen link');
      }

      final nitroH = File(p.join(iosDir.path, 'Classes', 'nitro.h'));
      if (nitroH.existsSync()) {
        ctx.ok(iosSec, 'ios/Classes/nitro.h present');
      } else {
        ctx.err(iosSec, 'ios/Classes/nitro.h missing', hint: 'Run: nitrogen link');
      }
      if (nitroH.existsSync()) {
        final content = nitroH.readAsStringSync();
        if (content.contains('NITRO_EXPORT')) {
          ctx.ok(iosSec, 'nitro.h contains NITRO_EXPORT visibility macro');
        } else {
          ctx.err(iosSec, 'nitro.h missing NITRO_EXPORT visibility macro', hint: 'Run: nitrogen link');
        }
      }
    }
  }

  void _checkIosMmBridges(_DoctorCtx ctx, DoctorSection iosSec, Directory classesDir, bool allSpecsCpp, SpmStatus spmStatus) {
    // Bridge files must use .mm (Objective-C++) not .cpp (pure C++).
    // .cpp files cause __OBJC__ to be undefined, making @try/@catch dead
    // code — NSException from Swift propagates uncaught and crashes the app.
    final staleCppBridges = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.cpp')).toList() : <File>[];
    if (staleCppBridges.isNotEmpty) {
      for (final f in staleCppBridges) {
        ctx.err(iosSec, 'Stale .cpp bridge: ${p.basename(f.path)} (must be .mm)', hint: 'Run: nitrogen link (auto-renames .bridge.g.cpp → .bridge.g.mm)');
      }
    }

    final mmBridges = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).toList() : <File>[];
    if (mmBridges.isNotEmpty) {
      ctx.ok(iosSec, '${mmBridges.length} .bridge.g.mm file(s) in ios/Classes/');
    } else if (ctx.specs.isNotEmpty && !allSpecsCpp && !spmStatus.iosHasSpm) {
      // For CocoaPods-only builds, warn about missing .mm bridges.
      // For SPM builds, the bridge.g.mm belongs in Sources/<PluginCpp>/, not Classes/.
      ctx.warn(iosSec, 'No .bridge.g.mm files in ios/Classes/', hint: 'Run: nitrogen link');
    }
  }

  void _checkIosSpm(_DoctorCtx ctx, DoctorSection iosSec, SpmStatus spmStatus) {
    if (!(spmStatus.iosHasSpm && spmStatus.iosPackageSwiftPath != null)) return;
    final packageSwiftFile = File(spmStatus.iosPackageSwiftPath!);
    final packageRoot = packageSwiftFile.parent.path;
    final cppTargetName = '${_toPascalCase(ctx.pluginName)}Cpp';
    final spmCppDir = Directory(p.join(packageRoot, 'Sources', cppTargetName));
    final pkgSwift = packageSwiftFile.readAsStringSync();
    _checkIosSpmCppTarget(ctx, iosSec, pkgSwift, cppTargetName, spmCppDir);
    _checkIosSpmSwiftTarget(ctx, iosSec, pkgSwift, packageRoot);
  }

  void _checkIosSpmCppTarget(_DoctorCtx ctx, DoctorSection iosSec, String pkgSwift, String cppTargetName, Directory spmCppDir) {
    if (pkgSwift.contains(cppTargetName)) {
      ctx.ok(iosSec, 'Package.swift: $cppTargetName target defined');
    } else {
      ctx.err(iosSec, 'Package.swift: $cppTargetName target missing', hint: 'Run: nitrogen init  (re-creates Package.swift with the correct C++ target)');
    }
    if (pkgSwift.contains(BuildVersions.podCxxStandard) || pkgSwift.contains(BuildVersions.spmCxxFlag)) {
      ctx.ok(iosSec, 'Package.swift: cxxSettings ${BuildVersions.spmCxxFlag} present');
    } else {
      ctx.warn(
        iosSec,
        'Package.swift: ${BuildVersions.spmCxxFlag} missing in cxxSettings',
        hint: 'Add .unsafeFlags(["${BuildVersions.spmCxxFlag}"]) to the $cppTargetName cxxSettings',
      );
    }
    if (pkgSwift.contains('publicHeadersPath')) {
      ctx.ok(iosSec, 'Package.swift: publicHeadersPath configured for $cppTargetName');
    } else {
      ctx.warn(iosSec, 'Package.swift: publicHeadersPath missing for $cppTargetName', hint: 'Run: nitrogen init  (sets publicHeadersPath: "include")');
    }

    if (spmCppDir.existsSync()) {
      // dart_api_dl.c — compiled as plain C; provides the Dart FFI bootstrap ABI
      final dartApiDlSpm = File(p.join(spmCppDir.path, 'dart_api_dl.c'));
      if (dartApiDlSpm.existsSync()) {
        ctx.ok(iosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c present');
        final dartApiDlContent = dartApiDlSpm.readAsStringSync();
        if (dartApiDlContent.contains('.symlinks') || RegExp(r'#include\s*"\/').hasMatch(dartApiDlContent)) {
          ctx.warn(iosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c uses a machine-specific or .symlinks path', hint: 'Run: nitrogen link  (rewrites to portable bundled stub)');
        } else if (!dartApiDlContent.contains('Dart_InitializeApiDL')) {
          ctx.err(
            iosSec,
            'SPM Sources/$cppTargetName/dart_api_dl.c is a header-only stub — missing Dart_InitializeApiDL implementation',
            hint: 'Run: nitrogen link  (rewrites to full self-contained implementation)',
          );
        }
      } else {
        ctx.err(iosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c missing', hint: 'Run: nitrogen link');
      }

      // <plugin>.cpp — forwarder that pulls in src/<plugin>.cpp via #include
      final pluginCppSpm = File(p.join(spmCppDir.path, '${ctx.pluginName}.cpp'));
      final pluginCSpm = File(p.join(spmCppDir.path, '${ctx.pluginName}.c'));
      if (pluginCppSpm.existsSync() || pluginCSpm.existsSync()) {
        ctx.ok(iosSec, 'SPM Sources/$cppTargetName/${ctx.pluginName}.cpp forwarder present');
      } else {
        ctx.warn(iosSec, 'SPM Sources/$cppTargetName/${ctx.pluginName}.cpp forwarder missing', hint: 'Run: nitrogen link');
      }

      // include/nitro.h — exposes NITRO_EXPORT and Nitro types to the C++ target
      final nitroHSpm = File(p.join(spmCppDir.path, 'include', 'nitro.h'));
      if (nitroHSpm.existsSync()) {
        ctx.ok(iosSec, 'SPM Sources/$cppTargetName/include/nitro.h present');
      } else {
        ctx.err(iosSec, 'SPM Sources/$cppTargetName/include/nitro.h missing', hint: 'Run: nitrogen link');
      }

      // bridge.g.mm — CRITICAL: compiled as Obj-C++ so that the SPM target
      // links the C symbols defined in bridge.g.cpp (init_dart_api_dl etc.).
      // Without this the plugin crashes at startup with:
      //   "Failed to lookup symbol '${ctx.pluginName}_init_dart_api_dl'"
      final spmMmBridges = spmCppDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).toList();
      if (spmMmBridges.isNotEmpty) {
        ctx.ok(iosSec, '${spmMmBridges.length} .bridge.g.mm in SPM Sources/$cppTargetName/');
      } else if (ctx.specs.isNotEmpty) {
        ctx.err(iosSec, 'Missing .bridge.g.mm in SPM Sources/$cppTargetName/', hint: 'Run: nitrogen link  (symbol ${ctx.pluginName}_init_dart_api_dl will be missing at runtime)');
      }
    } else if (ctx.specs.isNotEmpty) {
      ctx.warn(iosSec, 'SPM Sources/$cppTargetName/ directory not found', hint: 'Run: nitrogen link  (creates the SPM C++ target with bridge forwarders)');
    }
  }

  void _checkIosSpmSwiftTarget(_DoctorCtx ctx, DoctorSection iosSec, String pkgSwift, String packageRoot) {
    // ── Swift target completeness (nested-SPM gap fix) ───────────────────
    // The Package.swift must also declare a Swift target (named <ctx.pluginName>)
    // that depends on the C++ target and the FlutterFramework. Its sources
    // live in Sources/<PascalCaseName>/ and must include the generated
    // <ctx.pluginName>.bridge.g.swift file so Swift can call the C ABI.
    final isSwift = ctx.specs.isEmpty || _isAppleSwiftModule(ctx.specs.first);
    if (isSwift) {
      final swiftDirName = _toPascalCase(ctx.pluginName);
      final spmSwiftDir = Directory(p.join(packageRoot, 'Sources', swiftDirName));

      // Look for the Swift target declaration specifically (not just the Package name).
      // The target name must appear as name: "<plugin>" inside a .target(...) call.
      // Swift Package.swift uses double-quoted names; check for target name: "<plugin>".
      final hasSwiftTarget = RegExp(r'\.target\s*\(\s*name\s*:\s*"' + RegExp.escape(ctx.pluginName) + r'"').hasMatch(pkgSwift);
      if (hasSwiftTarget) {
        ctx.ok(iosSec, 'Package.swift: ${ctx.pluginName} Swift target defined');
      } else {
        ctx.warn(iosSec, 'Package.swift: ${ctx.pluginName} Swift target missing', hint: 'Run: nitrogen init  (re-creates Package.swift with the correct Swift target)');
      }

      if (spmSwiftDir.existsSync()) {
        ctx.ok(iosSec, 'SPM Sources/$swiftDirName/ directory present');
        final swiftBridge = File(p.join(spmSwiftDir.path, '${ctx.pluginName}.bridge.g.swift'));
        if (swiftBridge.existsSync()) {
          ctx.ok(iosSec, 'SPM Sources/$swiftDirName/${ctx.pluginName}.bridge.g.swift present');
        } else if (ctx.specs.isNotEmpty) {
          ctx.err(iosSec, 'Missing ${ctx.pluginName}.bridge.g.swift in SPM Sources/$swiftDirName/', hint: 'Run: nitrogen link  (copies generated bridge to the SPM Swift target)');
        }
      } else if (ctx.specs.isNotEmpty) {
        ctx.warn(iosSec, 'SPM Sources/$swiftDirName/ directory not found', hint: 'Run: nitrogen link  (creates SPM Swift target directory with bridge)');
      }
    }
  }

  void _checkMacos(_DoctorCtx ctx, SpmStatus spmStatus, bool allSpecsCpp, bool hasAnyNonCppSpec) {
    final macosSec = DoctorSection('macOS');
    ctx.sections.add(macosSec);
    final macosDir = Directory(p.join(ctx.root.path, 'macos'));
    if (!macosDir.existsSync()) {
      ctx.info(macosSec, 'macos/ directory not present — skipped');
      return;
    }
    _checkMacosPodspec(ctx, macosSec, macosDir, allSpecsCpp);
    final macosClassesDir = Directory(p.join(macosDir.path, 'Classes'));
    _checkMacosSwiftBridge(ctx, macosSec, macosDir, macosClassesDir, allSpecsCpp, hasAnyNonCppSpec);
    _checkMacosDartApi(ctx, macosSec, macosDir, spmStatus);
    _checkMacosMmBridges(ctx, macosSec, macosClassesDir, allSpecsCpp, spmStatus);
    _checkMacosSpm(ctx, macosSec, spmStatus);
  }

  void _checkMacosPodspec(_DoctorCtx ctx, DoctorSection macosSec, Directory macosDir, bool allSpecsCpp) {
    final podFiles = macosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
    if (podFiles.isEmpty) {
      ctx.err(macosSec, 'No .podspec found in macos/', hint: 'Run: nitrogen init');
    } else {
      ctx.checkFilePermissions(
        macosSec,
        podFiles.first,
        p.relative(podFiles.first.path, from: ctx.root.path),
      );
      final pod = podFiles.first.readAsStringSync();
      final podName = p.basename(podFiles.first.path);
      if (pod.contains("s.dependency 'nitro'")) {
        ctx.ok(macosSec, "s.dependency 'nitro' in $podName");
      } else {
        ctx.err(macosSec, "s.dependency 'nitro' missing in $podName", hint: 'Run: nitrogen link');
      }
      if (pod.contains('HEADER_SEARCH_PATHS')) {
        ctx.ok(macosSec, 'HEADER_SEARCH_PATHS in $podName');
      } else {
        ctx.err(macosSec, 'HEADER_SEARCH_PATHS missing in $podName', hint: 'Run: nitrogen link');
      }
      if (pod.contains(BuildVersions.podCxxStandard)) {
        ctx.ok(macosSec, 'CLANG_CXX_LANGUAGE_STANDARD = ${BuildVersions.podCxxStandard}');
      } else {
        ctx.warn(
          macosSec,
          'CLANG_CXX_LANGUAGE_STANDARD not set to ${BuildVersions.podCxxStandard}',
          hint: "Set: 'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}' in pod_target_xcconfig",
        );
      }
      if (pod.contains('lib/src/generated/cpp') && pod.contains('src/native')) {
        ctx.ok(macosSec, 'Comprehensive HEADER_SEARCH_PATHS in podspec');
      } else {
        ctx.warn(macosSec, 'Incomplete HEADER_SEARCH_PATHS in podspec', hint: 'Run: nitrogen link');
      }

      // Check source_files points to an existing path.
      final sourceFilesMatchMacos = RegExp(r"s\.source_files\s*=\s*'([^']+)'").firstMatch(pod);
      if (sourceFilesMatchMacos != null) {
        final sfPath = sourceFilesMatchMacos.group(1)!;
        final firstSegment = sfPath.split('/').first;
        final firstDir = Directory(p.join(macosDir.path, firstSegment));
        if (firstSegment == 'Classes' || firstDir.existsSync()) {
          ctx.ok(macosSec, 'source_files path valid: $sfPath');
        } else {
          ctx.err(macosSec, 'source_files points to non-existent path: $sfPath', hint: "Run: nitrogen link  (fixes to 'Classes/**/*')");
        }
      }
    }
  }

  void _checkMacosSwiftBridge(_DoctorCtx ctx, DoctorSection macosSec, Directory macosDir, Directory macosClassesDir, bool allSpecsCpp, bool hasAnyNonCppSpec) {
    if (allSpecsCpp) {
      ctx.info(macosSec, 'All modules use NativeImpl.cpp — Swift bridge (Registry.register) not required');
      // .native.g.h uses C++ types and must NOT be placed in macos/Classes/ —
      // CocoaPods includes every header there into the umbrella header, which
      // breaks Swift/ObjC compilation. Check HEADER_SEARCH_PATHS instead (same
      // logic as iOS). If SPM is active the file is also reachable via
      // Sources/NitroVaniCpp/ so the podspec check is advisory only.
      final macosPodFiles = macosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
      if (macosPodFiles.isNotEmpty) {
        final pod = macosPodFiles.first.readAsStringSync();
        if (pod.contains('lib/src/generated/cpp')) {
          ctx.ok(macosSec, '*.native.g.h reachable via HEADER_SEARCH_PATHS → lib/src/generated/cpp');
        } else {
          ctx.warn(macosSec, 'HEADER_SEARCH_PATHS may not include lib/src/generated/cpp (needed for *.native.g.h)', hint: 'Run: nitrogen link');
        }
      }
    } else {
      final swiftFiles = macosClassesDir.existsSync() ? macosClassesDir.listSync().whereType<File>().where((f) => f.path.endsWith('Plugin.swift')).toList() : <File>[];
      if (swiftFiles.isEmpty) {
        ctx.err(macosSec, 'No *Plugin.swift in macos/Classes/', hint: 'Run: nitrogen init');
      } else {
        final swift = swiftFiles.first.readAsStringSync();
        if (hasAnyNonCppSpec) {
          if (swift.contains('Registry.register(') || swift.contains('.register(')) {
            ctx.ok(macosSec, 'Plugin.swift has Registry.register(...)');
          } else {
            ctx.warn(macosSec, 'Registry.register(...) not found in Plugin.swift', hint: 'Add: NitroModules.Registry.register(...) in register(with:)');
          }
        } else {
          ctx.info(macosSec, 'Registry.register not needed — all modules use NativeImpl.cpp');
        }
      }
    }
  }

  void _checkMacosDartApi(_DoctorCtx ctx, DoctorSection macosSec, Directory macosDir, SpmStatus spmStatus) {
    // ── dart_api_dl.c / nitro.h ─────────────────────────────────────────────
    // For SPM builds (Flutter 3.22+) these files live in Sources/<PluginCpp>/,
    // not macos/Classes/. Only check macos/Classes/ when there is no Package.swift.
    if (!spmStatus.macosHasSpm) {
      final dartApiDl = File(p.join(macosDir.path, 'Classes', 'dart_api_dl.c'));
      if (dartApiDl.existsSync()) {
        ctx.ok(macosSec, 'macos/Classes/dart_api_dl.c present');
      } else {
        ctx.err(macosSec, 'macos/Classes/dart_api_dl.c missing', hint: 'Run: nitrogen link');
      }

      final nitroH = File(p.join(macosDir.path, 'Classes', 'nitro.h'));
      if (nitroH.existsSync()) {
        ctx.ok(macosSec, 'macos/Classes/nitro.h present');
      } else {
        ctx.err(macosSec, 'macos/Classes/nitro.h missing', hint: 'Run: nitrogen link');
      }
      if (nitroH.existsSync()) {
        final content = nitroH.readAsStringSync();
        if (content.contains('NITRO_EXPORT')) {
          ctx.ok(macosSec, 'nitro.h contains NITRO_EXPORT visibility macro');
        } else {
          ctx.err(macosSec, 'nitro.h missing NITRO_EXPORT visibility macro', hint: 'Run: nitrogen link');
        }
      }
    }
  }

  void _checkMacosMmBridges(_DoctorCtx ctx, DoctorSection macosSec, Directory macosClassesDir, bool allSpecsCpp, SpmStatus spmStatus) {
    final staleCppBridges = macosClassesDir.existsSync() ? macosClassesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.cpp')).toList() : <File>[];
    if (staleCppBridges.isNotEmpty) {
      for (final f in staleCppBridges) {
        ctx.err(macosSec, 'Stale .cpp bridge: ${p.basename(f.path)} (must be .mm)', hint: 'Run: nitrogen link (auto-renames .bridge.g.cpp → .bridge.g.mm)');
      }
    }

    final mmBridges = macosClassesDir.existsSync() ? macosClassesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).toList() : <File>[];
    if (mmBridges.isNotEmpty) {
      ctx.ok(macosSec, '${mmBridges.length} .bridge.g.mm file(s) in macos/Classes/');
    } else if (ctx.specs.isNotEmpty && !allSpecsCpp && !spmStatus.macosHasSpm) {
      // For CocoaPods-only builds, warn about missing .mm bridges.
      // For SPM builds, the bridge.g.mm belongs in Sources/<PluginCpp>/, not Classes/.
      ctx.warn(macosSec, 'No .bridge.g.mm files in macos/Classes/', hint: 'Run: nitrogen link');
    }
  }

  void _checkMacosSpm(_DoctorCtx ctx, DoctorSection macosSec, SpmStatus spmStatus) {
    if (!(spmStatus.macosHasSpm && spmStatus.macosPackageSwiftPath != null)) return;
    final packageSwiftFile = File(spmStatus.macosPackageSwiftPath!);
    final packageRoot = packageSwiftFile.parent.path;
    final cppTargetName = '${_toPascalCase(ctx.pluginName)}Cpp';
    final spmCppDir = Directory(p.join(packageRoot, 'Sources', cppTargetName));
    final pkgSwift = packageSwiftFile.readAsStringSync();
    _checkMacosSpmCppTarget(ctx, macosSec, pkgSwift, cppTargetName, spmCppDir);
    _checkMacosSpmSwiftTarget(ctx, macosSec, pkgSwift, packageRoot);
  }

  void _checkMacosSpmCppTarget(_DoctorCtx ctx, DoctorSection macosSec, String pkgSwift, String cppTargetName, Directory spmCppDir) {
    if (pkgSwift.contains(cppTargetName)) {
      ctx.ok(macosSec, 'Package.swift: $cppTargetName target defined');
    } else {
      ctx.err(macosSec, 'Package.swift: $cppTargetName target missing', hint: 'Run: nitrogen init  (re-creates Package.swift with the correct C++ target)');
    }
    if (pkgSwift.contains(BuildVersions.podCxxStandard) || pkgSwift.contains(BuildVersions.spmCxxFlag)) {
      ctx.ok(macosSec, 'Package.swift: cxxSettings ${BuildVersions.spmCxxFlag} present');
    } else {
      ctx.warn(
        macosSec,
        'Package.swift: ${BuildVersions.spmCxxFlag} missing in cxxSettings',
        hint: 'Add .unsafeFlags(["${BuildVersions.spmCxxFlag}"]) to the $cppTargetName cxxSettings',
      );
    }
    if (pkgSwift.contains('publicHeadersPath')) {
      ctx.ok(macosSec, 'Package.swift: publicHeadersPath configured for $cppTargetName');
    } else {
      ctx.warn(macosSec, 'Package.swift: publicHeadersPath missing for $cppTargetName', hint: 'Run: nitrogen init  (sets publicHeadersPath: "include")');
    }

    if (spmCppDir.existsSync()) {
      // dart_api_dl.c — compiled as plain C; provides the Dart FFI bootstrap ABI
      final dartApiDlSpm = File(p.join(spmCppDir.path, 'dart_api_dl.c'));
      if (dartApiDlSpm.existsSync()) {
        ctx.ok(macosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c present');
        final dartApiDlContent = dartApiDlSpm.readAsStringSync();
        if (dartApiDlContent.contains('.symlinks') || RegExp(r'#include\s*"\/').hasMatch(dartApiDlContent)) {
          ctx.warn(macosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c uses a machine-specific or .symlinks path', hint: 'Run: nitrogen link  (rewrites to portable bundled stub)');
        } else if (!dartApiDlContent.contains('Dart_InitializeApiDL')) {
          ctx.err(
            macosSec,
            'SPM Sources/$cppTargetName/dart_api_dl.c is a header-only stub — missing Dart_InitializeApiDL implementation',
            hint: 'Run: nitrogen link  (rewrites to full self-contained implementation)',
          );
        }
      } else {
        ctx.err(macosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c missing', hint: 'Run: nitrogen link');
      }

      // <plugin>.cpp — forwarder that pulls in src/<plugin>.cpp via #include
      final pluginCppSpm = File(p.join(spmCppDir.path, '${ctx.pluginName}.cpp'));
      final pluginCSpm = File(p.join(spmCppDir.path, '${ctx.pluginName}.c'));
      if (pluginCppSpm.existsSync() || pluginCSpm.existsSync()) {
        ctx.ok(macosSec, 'SPM Sources/$cppTargetName/${ctx.pluginName}.cpp forwarder present');
      } else {
        ctx.warn(macosSec, 'SPM Sources/$cppTargetName/${ctx.pluginName}.cpp forwarder missing', hint: 'Run: nitrogen link');
      }

      // include/nitro.h — exposes NITRO_EXPORT and Nitro types to the C++ target
      final nitroHSpm = File(p.join(spmCppDir.path, 'include', 'nitro.h'));
      if (nitroHSpm.existsSync()) {
        ctx.ok(macosSec, 'SPM Sources/$cppTargetName/include/nitro.h present');
      } else {
        ctx.err(macosSec, 'SPM Sources/$cppTargetName/include/nitro.h missing', hint: 'Run: nitrogen link');
      }

      // bridge.g.mm — CRITICAL: compiled as Obj-C++ so that the SPM target
      // links the C symbols defined in bridge.g.cpp (init_dart_api_dl etc.).
      // Without this the plugin crashes at startup with:
      //   "Failed to lookup symbol '${ctx.pluginName}_init_dart_api_dl'"
      final spmMmBridges = spmCppDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).toList();
      if (spmMmBridges.isNotEmpty) {
        ctx.ok(macosSec, '${spmMmBridges.length} .bridge.g.mm in SPM Sources/$cppTargetName/');
      } else if (ctx.specs.isNotEmpty) {
        ctx.err(
          macosSec,
          'Missing .bridge.g.mm in SPM Sources/$cppTargetName/',
          hint: 'Run: nitrogen link  (symbol ${ctx.pluginName}_init_dart_api_dl will be missing at runtime)',
        );
      }
    } else if (ctx.specs.isNotEmpty) {
      ctx.warn(macosSec, 'SPM Sources/$cppTargetName/ directory not found', hint: 'Run: nitrogen link  (creates the SPM C++ target with bridge forwarders)');
    }
  }

  void _checkMacosSpmSwiftTarget(_DoctorCtx ctx, DoctorSection macosSec, String pkgSwift, String packageRoot) {
    // ── Swift target completeness (nested-SPM gap fix) ───────────────────
    final isMacosSwift = ctx.specs.isEmpty || _isAppleSwiftModule(ctx.specs.first);
    if (isMacosSwift) {
      final swiftDirName = _toPascalCase(ctx.pluginName);
      final spmSwiftDir = Directory(p.join(packageRoot, 'Sources', swiftDirName));

      final hasMacosSwiftTarget = RegExp(r'\.target\s*\(\s*name\s*:\s*"' + RegExp.escape(ctx.pluginName) + r'"').hasMatch(pkgSwift);
      if (hasMacosSwiftTarget) {
        ctx.ok(macosSec, 'Package.swift: ${ctx.pluginName} Swift target defined');
      } else {
        ctx.warn(macosSec, 'Package.swift: ${ctx.pluginName} Swift target missing', hint: 'Run: nitrogen init  (re-creates Package.swift with the correct Swift target)');
      }

      if (spmSwiftDir.existsSync()) {
        ctx.ok(macosSec, 'SPM Sources/$swiftDirName/ directory present');
        final swiftBridge = File(p.join(spmSwiftDir.path, '${ctx.pluginName}.bridge.g.swift'));
        if (swiftBridge.existsSync()) {
          ctx.ok(macosSec, 'SPM Sources/$swiftDirName/${ctx.pluginName}.bridge.g.swift present');
        } else if (ctx.specs.isNotEmpty) {
          ctx.err(
            macosSec,
            'Missing ${ctx.pluginName}.bridge.g.swift in SPM Sources/$swiftDirName/',
            hint: 'Run: nitrogen link  (copies generated bridge to the SPM Swift target)',
          );
        }
      } else if (ctx.specs.isNotEmpty) {
        ctx.warn(macosSec, 'SPM Sources/$swiftDirName/ directory not found', hint: 'Run: nitrogen link  (creates SPM Swift target directory with bridge)');
      }
    }
  }
}
