import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';

/// Kills any existing `build_runner` processes before starting a new one.
///
/// build_runner uses a lock file (`.dart_tool/build/lock`) so a second
/// invocation in the same project will hang indefinitely waiting for the
/// lock. This function uses two complementary strategies:
///
///   **Strategy 1 — lock-file owner (most reliable)**
///   Uses `lsof -t` to find the exact PID(s) holding the lock file and
///   kills them directly. This bypasses command-line truncation issues that
///   can cause `pkill -f` to miss the process (e.g. when Flutter/puro runs
///   build_runner via a long snapshot path).
///
///   **Strategy 2 — pkill fallback**
///   `pkill -f build_runner` catches any remaining dart processes whose
///   argv contains "build_runner" in case `lsof` found nothing (e.g. when
///   the lock file doesn't exist yet but the process is still starting).
///
///   Finally, the entire `.dart_tool/build` directory is deleted so no
///   stale lock can block the new process, even if the killed process held
///   the file handle right up to SIGKILL.
///
/// Returns the number of processes that were killed (0 = none were running).
Future<int> killBuildRunner({String? workingDirectory}) async {
  int killed = 0;

  if (Platform.isWindows) {
    // Windows: use WMIC to find dart.exe processes running build_runner.
    try {
      final list = await Process.run(
        'wmic',
        ['process', 'where', "CommandLine like '%build_runner%'", 'get', 'ProcessId'],
        runInShell: true,
      );
      final pids = (list.stdout as String).split(RegExp(r'\s+')).where((s) => RegExp(r'^\d+$').hasMatch(s)).toList();
      for (final pid in pids) {
        final r = await Process.run('taskkill', ['/F', '/PID', pid], runInShell: true);
        if (r.exitCode == 0) killed++;
      }
    } catch (_) {}
  } else {
    // ── Strategy 1: lsof — find the process holding the lock file ───────────
    // This is the most reliable method: we know exactly which process is
    // blocking. It is immune to argv truncation issues in pkill -f.
    if (workingDirectory != null) {
      for (final lockName in ['lock', '.lock']) {
        final lockPath = p.join(workingDirectory, '.dart_tool', 'build', lockName);
        if (!File(lockPath).existsSync()) continue;
        try {
          final lsof = await Process.run('lsof', ['-t', lockPath]);
          final pids = (lsof.stdout as String).trim().split(RegExp(r'\s+')).where((s) => RegExp(r'^\d+$').hasMatch(s)).toList();
          for (final pid in pids) {
            await Process.run('kill', ['-TERM', pid]);
            killed++;
          }
          if (pids.isNotEmpty) {
            // Grace period for clean shutdown.
            await Future.delayed(const Duration(milliseconds: 700));
            for (final pid in pids) {
              await Process.run('kill', ['-KILL', pid]);
            }
          }
        } catch (_) {}
      }
    }

    // ── Strategy 2: pkill -f as a broad fallback ────────────────────────────
    // Catches processes whose lock file doesn't exist yet (still starting up)
    // or when lsof is unavailable. On macOS -f searches the full argv.
    try {
      final r = await Process.run('pkill', ['-f', 'build_runner']);
      if (r.exitCode == 0) {
        killed++;
        await Future.delayed(const Duration(milliseconds: 800));
        await Process.run('pkill', ['-9', '-f', 'build_runner']);
      }
    } catch (_) {}
  }

  // ── Delete the entire .dart_tool/build directory ─────────────────────────
  // Deleting just the lock file is insufficient — the OS may keep the file
  // descriptor open briefly after SIGKILL. Removing the whole directory
  // guarantees a clean slate. Retry once after a short pause.
  if (workingDirectory != null) {
    final buildCache = Directory(p.join(workingDirectory, '.dart_tool', 'build'));
    if (buildCache.existsSync()) {
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        buildCache.deleteSync(recursive: true);
      } catch (_) {
        // If the first attempt races with the dying process, wait and retry.
        await Future.delayed(const Duration(milliseconds: 400));
        try {
          buildCache.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  return killed;
}

List<ProjectInfo> getAllProjects({Directory? baseDir}) {
  final List<ProjectInfo> projects = [];
  final root = baseDir ?? Directory.current;
  try {
    // 1. Check current directory
    final rootInfo = parsePubspec(root);
    if (rootInfo != null) projects.add(rootInfo);

    // 2. Check subdirectories (up to 2 levels for monorepos)
    for (final entity in root.listSync()) {
      if (entity is Directory) {
        final info = parsePubspec(entity);
        if (info != null) {
          projects.add(info);
        } else {
          // Check one level deeper (e.g. packages/my_package)
          try {
            for (final sub in entity.listSync()) {
              if (sub is Directory) {
                final subInfo = parsePubspec(sub);
                if (subInfo != null) projects.add(subInfo);
              }
            }
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  return projects;
}

ProjectInfo? getProjectInfo() {
  final all = getAllProjects();
  return all.isEmpty ? null : all.first;
}

ProjectInfo? parsePubspec(Directory dir) {
  final pubspecFile = File('${dir.path}/pubspec.yaml');
  if (!pubspecFile.existsSync()) return null;

  final content = pubspecFile.readAsStringSync();
  // Ensure it's a Nitro project (has dependency or generator)
  if (!content.contains('nitro:') && !content.contains('nitro_generator:')) {
    return null;
  }

  String name = 'unknown';
  String version = 'unknown';
  for (final line in content.split('\n')) {
    if (line.trim().startsWith('name: ')) {
      name = line.replaceFirst('name: ', '').trim();
    }
    if (line.trim().startsWith('version: ')) {
      version = line.replaceFirst('version: ', '').trim();
    }
  }
  return ProjectInfo(name, version, dir);
}

Future<String> getGitBranch([String? workingDirectory]) async {
  try {
    final result = await Process.run('git', ['branch', '--show-current'], workingDirectory: workingDirectory);
    if (result.exitCode == 0) return result.stdout.toString().trim();
  } catch (_) {}
  return 'no git';
}

void launchUrl(String url) {
  if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else if (Platform.isLinux) {
    Process.run('xdg-open', [url]);
  } else if (Platform.isWindows) {
    Process.run('powershell', ['Start-Process', '"$url"']);
  }
}

/// Synchronizes generated bridge files from lib/src/generated to native project roots.
/// [platform] is the platform directory name ('ios' or 'macos'). Defaults to 'ios'.
/// This is needed for Apple development as CocoaPods/SPM normally uses copies instead of symlinks.
void syncBridgeFiles(String workingDirectory, {String platform = 'ios'}) {
  final generatedDir = Directory(p.join(workingDirectory, 'lib', 'src', 'generated'));
  if (!generatedDir.existsSync()) return;

  // Discover Apple C++ modules (ios or macos using NativeImpl.cpp).
  // Their Swift bridge stubs must NOT be compiled alongside the direct C++ bridge
  // (duplicate-symbol guard). Any stale copies in Classes/ must be deleted.
  final appleCppModules = _discoverAppleCppModules(workingDirectory);
  final pluginName = _readPluginName(workingDirectory);
  final className = toPascalCase(pluginName);

  // Support both legacy (CocoaPods) and modern (SPM) source layouts.
  final classesDir = Directory(p.join(workingDirectory, platform, 'Classes'));
  final sourcesDir = Directory(p.join(workingDirectory, platform, 'Sources', className));

  if (!classesDir.existsSync() && !sourcesDir.existsSync()) return;

  final targetDirs = [
    if (classesDir.existsSync()) classesDir,
    if (sourcesDir.existsSync()) sourcesDir,
  ];

  // Sync Swift bridges.
  // Non-cpp modules: copy to all existing target dirs for reliability.
  // Cpp modules: delete any stale copy — the direct C++ bridge makes them unnecessary.
  final swiftSource = Directory(p.join(generatedDir.path, 'swift'));
  if (swiftSource.existsSync()) {
    for (final file in swiftSource.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (!name.endsWith('.bridge.g.swift')) continue;
      final libName = name.replaceFirst('.bridge.g.swift', '');
      if (appleCppModules.containsKey(libName)) {
        // Delete stale Swift bridge copies for C++ modules.
        for (final targetDir in targetDirs) {
          final stale = File(p.join(targetDir.path, name));
          if (stale.existsSync()) stale.deleteSync();
        }
        continue;
      }
      for (final targetDir in targetDirs) {
        file.copySync(p.join(targetDir.path, name));
      }
    }
  }

  // The following syncs target only the CocoaPods Classes/ layout.
  if (!classesDir.existsSync()) return;

  // Sync C++/Obj-C++ bridges (.bridge.g.cpp → .bridge.g.mm for Obj-C++ support).
  final cppSource = Directory(p.join(generatedDir.path, 'cpp'));
  if (cppSource.existsSync()) {
    for (final file in cppSource.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (name.endsWith('.bridge.g.h') || name.endsWith('.bridge.g.cpp')) {
        final targetName = name.endsWith('.bridge.g.cpp') ? name.replaceFirst('.bridge.g.cpp', '.bridge.g.mm') : name;
        file.copySync(p.join(classesDir.path, targetName));
      }
    }
  }

  // Sync HybridXxx.cpp impl stubs for Apple C++ modules.
  //
  // CocoaPods compiles everything in Classes/** — the impl stubs must be
  // there so the C++ HybridObject methods are compiled into the pod target.
  // Stale Hybrid*.cpp files for non-Apple-cpp modules are removed to prevent
  // "abstract class" compile errors.
  final srcDir = Directory(p.join(workingDirectory, 'src'));
  if (srcDir.existsSync()) {
    final expectedImplFiles = <String>{};
    for (final entry in appleCppModules.entries) {
      final libClassName = toPascalCase(entry.key);
      expectedImplFiles.add('Hybrid$libClassName.cpp');
      final moduleClassName = toPascalCase(entry.value);
      expectedImplFiles.add('Hybrid$moduleClassName.cpp');
    }

    for (final name in expectedImplFiles) {
      final srcFile = File(p.join(srcDir.path, name));
      if (srcFile.existsSync()) {
        srcFile.copySync(p.join(classesDir.path, name));
      }
    }

    for (final file in classesDir.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (name.startsWith('Hybrid') && name.endsWith('.cpp')) {
        if (!expectedImplFiles.contains(name)) {
          file.deleteSync();
        }
      }
    }
  }
}

String toPascalCase(String s) => s.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

/// Strips the shared public-type preamble from a Swift bridge file.
///
/// When multiple specs compile into the same Swift module each generated
/// `.bridge.g.swift` file starts with shared declarations (`NitroEncodable`,
/// `NitroNullableInt`, `NitroRecordWriter`, …).  Keeping those in 2nd+ files
/// causes an `invalid redeclaration` Swift compiler error.  This function
/// removes everything from the `public protocol NitroEncodable` line up to
/// (but not including) the `/**` doc-comment that begins the spec-specific
/// protocol, leaving only the file-private string helpers and the
/// spec-specific protocol/registry/stubs.
String stripSharedSwiftPreamble(String content) {
  final lines = content.split('\n');
  final result = <String>[];
  var inSharedBlock = false;

  for (final line in lines) {
    if (!inSharedBlock && line.startsWith('public protocol NitroEncodable')) {
      inSharedBlock = true;
      continue;
    }
    if (inSharedBlock) {
      if (line.startsWith('/**')) {
        inSharedBlock = false;
        result.add(line);
      }
      continue;
    }
    result.add(line);
  }

  return result.join('\n');
}

/// Returns a map of {lib → moduleName} for modules where Apple platforms
/// (ios or macos) use a direct C++ implementation (AppleNativeImpl.cpp).
/// These need their HybridXxx.cpp impl file copied to ios/Classes/ or macos/Classes/
/// so CocoaPods includes them in the pod target compilation.
Map<String, String> _discoverAppleCppModules(String workingDirectory) {
  final libDir = Directory(p.join(workingDirectory, 'lib'));
  if (!libDir.existsSync()) return {};
  final result = <String, String>{};
  for (final file in libDir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.native.dart')) continue;
    final content = file.readAsStringSync();
    final libMatch = RegExp(r"""@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]""", dotAll: true).firstMatch(content);
    if (libMatch == null) continue;
    final annotationMatch = RegExp(r'@NitroModule\s*\(([^)]+)\)', dotAll: true).firstMatch(content);
    if (annotationMatch == null) continue;
    final annotation = annotationMatch.group(1)!.replaceAll('\n', ' ');
    // Apple C++ = ios or macos using AppleNativeImpl.cpp (or legacy NativeImpl.cpp)
    if (!RegExp(
      r'\b(?:ios|macos)\s*:\s*(?:NativeImpl|AppleNativeImpl)\.cpp\b',
    ).hasMatch(annotation)) {
      continue;
    }
    final lib = libMatch.group(1)!;
    final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(content);
    final moduleName = moduleMatch?.group(1) ?? toPascalCase(lib);
    result[lib] = moduleName;
  }
  return result;
}

String _readPluginName(String projectRoot) {
  final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return 'my_plugin';
  for (final line in pubspec.readAsLinesSync()) {
    if (line.trim().startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
  }
  return 'my_plugin';
}
