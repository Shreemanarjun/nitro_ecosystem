part of '../doctor_command.dart';

extension _DoctorToolchainChecks on DoctorCommand {
  void _checkSystemToolchain(_DoctorCtx ctx) {
    // ── System Toolchain ────────────────────────────────────────────────────────
    final sysSec = DoctorSection('System Toolchain');
    ctx.sections.add(sysSec);

    // 1. C++ Compiler
    try {
      final clangResult = Process.runSync('clang++', ['--version']);
      if (clangResult.exitCode == 0) {
        ctx.ok(sysSec, 'clang++ found: ${clangResult.stdout.toString().split('\n').first}');
      } else {
        ctx.warn(sysSec, 'clang++ not found', hint: 'Install build-essential or Xcode Command Line Tools');
      }
    } catch (_) {
      ctx.warn(sysSec, 'clang++ not found', hint: 'Install build-essential or Xcode Command Line Tools');
    }

    // 2. Xcode (on Mac)
    if (Platform.isMacOS) {
      try {
        final xcodeResult = Process.runSync('xcode-select', ['-p']);
        if (xcodeResult.exitCode == 0) {
          ctx.ok(sysSec, 'Xcode at ${xcodeResult.stdout.toString().trim()}');
        } else {
          ctx.err(sysSec, 'Xcode not found', hint: 'Run: xcode-select --install');
        }
      } catch (_) {
        ctx.err(sysSec, 'Xcode select failed', hint: 'Run: xcode-select --install');
      }
    }

    // 3. Android NDK
    final ndkPath = Platform.environment['ANDROID_NDK_HOME'] ?? Platform.environment['NDK_HOME'];
    if (ndkPath != null && Directory(ndkPath).existsSync()) {
      ctx.ok(sysSec, 'Android NDK: ${p.basename(ndkPath)}');
    } else {
      // Check local.properties if in an android project, though we are in a plugin...
      // Usually users set ANDROID_NDK_HOME globally.
      ctx.warn(sysSec, 'ANDROID_NDK_HOME not set', hint: 'Set ANDROID_NDK_HOME in your environment');
    }

    // 4. Java
    try {
      final javaResult = Process.runSync('java', ['-version']);
      // java -version writes to stderr
      final javaOut = javaResult.stderr.toString();
      if (javaOut.contains('version')) {
        ctx.ok(sysSec, 'Java: ${javaOut.split('\n').first}');
      } else {
        ctx.warn(sysSec, 'Java not found', hint: 'Install JDK 17+');
      }
    } catch (_) {
      ctx.warn(sysSec, 'Java not found', hint: 'Install JDK 17+');
    }
    _checkDesktopToolchain(ctx, sysSec);
  }

  void _checkDesktopToolchain(_DoctorCtx ctx, DoctorSection sysSec) {
    // ── PX15: Windows / Linux toolchain checks ─────────────────────────────
    // Only run on the platform where Windows/Linux builds are performed.

    // CMake — required for any desktop C++ target (Windows, Linux, macOS)
    try {
      final cmakeResult = Process.runSync('cmake', ['--version']);
      if (cmakeResult.exitCode == 0) {
        final ver = cmakeResult.stdout.toString().split('\n').first;
        ctx.ok(sysSec, 'cmake: $ver');
      } else {
        ctx.warn(
          sysSec,
          'cmake not found',
          hint: Platform.isWindows
              ? 'Install CMake: winget install Kitware.CMake'
              : Platform.isLinux
              ? 'Install cmake: apt install cmake  (or equivalent)'
              : 'Install CMake from cmake.org',
        );
      }
    } catch (_) {
      ctx.warn(sysSec, 'cmake not found', hint: Platform.isWindows ? 'Install CMake: winget install Kitware.CMake' : 'Install cmake from cmake.org or your package manager');
    }

    if (Platform.isWindows) {
      // MSVC (Visual C++) — check for cl.exe
      final clPath = _findOnPath('cl.exe');
      if (clPath != null) {
        ctx.ok(sysSec, 'MSVC (cl.exe) found at $clPath');
      } else {
        ctx.err(
          sysSec,
          'MSVC (cl.exe) not found',
          hint:
              'Install Visual Studio Build Tools 2019+ and ensure '
              'the "Desktop development with C++" workload is selected. '
              'Run from a Developer Command Prompt for VS.',
        );
      }
      // Windows SDK
      final sdkDir = Platform.environment['WINDOWSSDKDIR'];
      if (sdkDir != null && Directory(sdkDir).existsSync()) {
        ctx.ok(sysSec, 'Windows SDK at $sdkDir');
      } else {
        ctx.warn(sysSec, 'WINDOWSSDKDIR not set', hint: 'Install the Windows SDK from Visual Studio Installer');
      }
    }

    if (Platform.isLinux) {
      // GCC or Clang (PX15: check for g++ or clang++)
      final hasGcc = _runVersionCheck('g++');
      final hasClang = _runVersionCheck('clang++');
      if (hasGcc != null) {
        ctx.ok(sysSec, 'g++ found: $hasGcc');
      } else if (hasClang != null) {
        ctx.ok(sysSec, 'clang++ found: $hasClang');
      } else {
        ctx.err(
          sysSec,
          'No C++ compiler found (g++ / clang++)',
          hint:
              'Install build tools: apt install build-essential  '
              'or: apt install clang',
        );
      }
      // libpthread & libdl (required by Nitro native modules on Linux)
      final pthreadOk =
          File('/usr/lib/libpthread.so').existsSync() ||
          File('/usr/lib/x86_64-linux-gnu/libpthread.so').existsSync() ||
          File('/usr/lib/aarch64-linux-gnu/libpthread.so').existsSync();
      if (pthreadOk) {
        ctx.ok(sysSec, 'libpthread available');
      } else {
        ctx.warn(sysSec, 'libpthread not detected in standard paths', hint: 'Ensure libpthread-dev is installed: apt install libpthread-stubs0-dev');
      }
    }
  }

  void _checkPubspec(_DoctorCtx ctx) {
    final pubspecFile = File(p.join(ctx.root.path, 'pubspec.yaml'));
    final pubSec = DoctorSection('pubspec.yaml');
    ctx.sections.add(pubSec);
    final pubspec = pubspecFile.readAsStringSync();

    if (pubspec.contains('nitro:')) {
      ctx.ok(pubSec, 'nitro dependency present');
    } else {
      ctx.err(pubSec, 'nitro dependency missing', hint: 'Add: nitro: { path: ../packages/nitro }');
    }

    if (pubspec.contains('build_runner:')) {
      ctx.ok(pubSec, 'build_runner dev dependency present');
    } else {
      ctx.err(pubSec, 'build_runner dev dependency missing', hint: 'Add to dev_dependencies: build_runner: ^2.4.0');
    }

    if (pubspec.contains('nitro_generator:')) {
      ctx.ok(pubSec, 'nitro_generator dev dependency present');
    } else {
      ctx.err(pubSec, 'nitro_generator dev dependency missing', hint: 'Add to dev_dependencies: nitro_generator: { path: ../packages/nitro_generator }');
    }

    if (RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspec)) {
      ctx.ok(pubSec, 'android pluginClass defined');
    } else {
      ctx.err(pubSec, 'android pluginClass missing', hint: 'Add pluginClass under flutter.plugin.platforms.android');
    }

    if (RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+package:').hasMatch(pubspec)) {
      ctx.ok(pubSec, 'android package defined');
    } else {
      ctx.err(pubSec, 'android package missing', hint: 'Add package under flutter.plugin.platforms.android');
    }

    if (RegExp(r'ios:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspec)) {
      ctx.ok(pubSec, 'ios pluginClass defined');
    } else if (RegExp(r'ios:\s*\n(?:\s+\S[^\n]*\n)*\s+ffiPlugin:\s*true').hasMatch(pubspec)) {
      ctx.ok(pubSec, 'ios ffiPlugin: true (pluginClass optional for FFI plugins)');
    } else {
      ctx.err(pubSec, 'ios pluginClass missing', hint: 'Add pluginClass under flutter.plugin.platforms.ios');
    }

    if (pubspec.contains('  macos:')) {
      if (RegExp(r'macos:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspec)) {
        ctx.ok(pubSec, 'macos pluginClass defined');
      } else if (RegExp(r'macos:\s*\n(?:\s+\S[^\n]*\n)*\s+ffiPlugin:\s*true').hasMatch(pubspec)) {
        ctx.ok(pubSec, 'macos ffiPlugin: true (pluginClass optional for FFI plugins)');
      } else {
        ctx.warn(pubSec, 'macos pluginClass missing', hint: 'Add pluginClass or ffiPlugin: true under flutter.plugin.platforms.macos');
      }
    }

    // Windows/Linux Nitro backends are pure FFI: pluginClass alongside
    // ffiPlugin makes Flutter link a nonexistent <plugin>_plugin CMake target
    // ("CMake Error: No target") in every consuming desktop app — issue #10.
    for (final desktop in ['windows', 'linux']) {
      if (!pubspec.contains('  $desktop:')) continue;
      final block = RegExp('$desktop:\\s*\\n(?:\\s+\\S[^\\n]*\\n)*');
      final flow = RegExp('$desktop:\\s*\\{[^}]*\\}');
      final entry = block.firstMatch(pubspec)?.group(0) ?? flow.firstMatch(pubspec)?.group(0) ?? '';
      final hasClass = entry.contains('pluginClass:');
      final hasFfi = RegExp(r'ffiPlugin:\s*true').hasMatch(entry);
      if (hasClass && hasFfi) {
        ctx.err(
          pubSec,
          '$desktop declares pluginClass on an FFI-only platform',
          hint: 'Remove it (Run: nitrogen link) — Flutter otherwise links a nonexistent <plugin>_plugin CMake target',
        );
      } else if (hasFfi) {
        ctx.ok(pubSec, '$desktop ffiPlugin: true (FFI-only, no pluginClass)');
      }
    }
  }
}
