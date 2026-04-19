import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';

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
/// This is needed for Apple development as CocoaPods normally uses copies instead of symlinks.
void syncBridgeFiles(String workingDirectory, {String platform = 'ios'}) {
  final classesDir = Directory(p.join(workingDirectory, platform, 'Classes'));
  if (!classesDir.existsSync()) return;

  final generatedDir = Directory(p.join(workingDirectory, 'lib', 'src', 'generated'));
  if (!generatedDir.existsSync()) return;

  // Discover which modules use the direct C++ path (NativeImpl.cpp).
  // Swift bridges are compiled from lib/src/generated/swift/ directly via the
  // podspec source_files pattern — stale copies in ios/Classes/ cause
  // duplicate-symbol linker errors and must be removed.

  // Discover Apple C++ modules specifically — HybridXxx.cpp must be in ios/Classes/
  // so CocoaPods can compile them as part of the pod target.
  // For non-Apple-cpp modules, any stale HybridXxx.cpp must be removed.
  final appleCppModules = _discoverAppleCppModules(workingDirectory);

  // Sync Swift bridges.
  // We copy them to the native platform's source directory (Sources/ or Classes/)
  // to ensure they are always findable by Xcode, regardless of relative path issues.
  final swiftSource = Directory(p.join(generatedDir.path, 'swift'));
  if (swiftSource.existsSync()) {
    final pluginName = _readPluginName(workingDirectory);
    final className = toPascalCase(pluginName);
    
    // Check both legacy (Classes/) and modern (Sources/ClassName/) paths.
    final targetDirs = [
      Directory(p.join(workingDirectory, platform, 'Classes')),
      Directory(p.join(workingDirectory, platform, 'Sources', className)),
    ];

    for (final file in swiftSource.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (name.endsWith('.bridge.g.swift')) {
        // Skip Swift bridge for NativeImpl.cpp modules.
        final libName = name.replaceFirst('.bridge.g.swift', '');
        if (appleCppModules.containsKey(libName)) continue;
        
        for (final targetDir in targetDirs) {
          if (targetDir.existsSync()) {
            file.copySync(p.join(targetDir.path, name));
          }
        }
      }
    }
  }

  // Sync C++/Obj-C++ bridges
  final cppSource = Directory(p.join(generatedDir.path, 'cpp'));
  if (cppSource.existsSync()) {
    for (final file in cppSource.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (name.endsWith('.bridge.g.h') || name.endsWith('.bridge.g.cpp')) {
        // .bridge.g.cpp -> .bridge.g.mm for iOS Objective-C++ support
        final targetName = name.endsWith('.bridge.g.cpp') ? name.replaceFirst('.bridge.g.cpp', '.bridge.g.mm') : name;
        file.copySync(p.join(classesDir.path, targetName));
      }
    }
  }

  // Sync HybridXxx.cpp impl stubs for Apple C++ modules.
  //
  // CocoaPods compiles everything in ios/Classes/** — the impl stubs must be
  // there so the C++ HybridObject methods are compiled into the pod target.
  //
  // For modules that are NOT Apple C++ (e.g. benchmark: AppleNativeImpl.swift),
  // any stale HybridXxx.cpp in ios/Classes/ must be REMOVED — if left behind
  // they cause "Variable type 'HybridXxxImpl' is an abstract class" errors
  // because the abstract base (Hybrid$Xxx) has no implementation on iOS.
  final srcDir = Directory(p.join(workingDirectory, 'src'));
  if (srcDir.existsSync()) {
    // Build the set of Hybrid*.cpp files that SHOULD be present for Apple C++ modules.
    final expectedImplFiles = <String>{};
    for (final entry in appleCppModules.entries) {
      final className = toPascalCase(entry.key);  // lib → PascalCase
      expectedImplFiles.add('Hybrid$className.cpp');
      // Also try module name in case they differ.
      final moduleClassName = toPascalCase(entry.value);
      expectedImplFiles.add('Hybrid$moduleClassName.cpp');
    }

    // Copy expected Hybrid*.cpp files from src/ into ios/Classes/.
    for (final name in expectedImplFiles) {
      final srcFile = File(p.join(srcDir.path, name));
      if (srcFile.existsSync()) {
        srcFile.copySync(p.join(classesDir.path, name));
      }
    }

    // Remove stale Hybrid*.cpp files that should NOT be in ios/Classes/.
    if (classesDir.existsSync()) {
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
}

String toPascalCase(String s) =>
    s.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

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
    ).hasMatch(annotation)) { continue; }
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
