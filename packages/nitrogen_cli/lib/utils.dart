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

/// Synchronizes generated bridge files from lib/src/generated to native project roots (ios/Classes).
/// This is needed for iOS development as CocoaPods normally uses copies instead of symlinks.
void syncBridgeFiles(String workingDirectory) {
  final classesDir = Directory(p.join(workingDirectory, 'ios', 'Classes'));
  if (!classesDir.existsSync()) return;

  final generatedDir = Directory(p.join(workingDirectory, 'lib', 'src', 'generated'));
  if (!generatedDir.existsSync()) return;

  // Discover which modules use the direct C++ path (NativeImpl.cpp).
  // Their generated .bridge.g.swift must NOT be copied into ios/Classes/:
  //   - the C++ bridge calls g_impl directly — it never calls the @_cdecl stubs
  //   - those stubs share the same symbol names as the non-cpp Swift bridge,
  //     causing duplicate-symbol linker errors.
  final cppLibs = _discoverCppLibs(workingDirectory);

  // Sync Swift bridges — skip C++ modules.
  final swiftSource = Directory(p.join(generatedDir.path, 'swift'));
  if (swiftSource.existsSync()) {
    for (final file in swiftSource.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (name.endsWith('.bridge.g.swift')) {
        final lib = name.replaceFirst('.bridge.g.swift', '');
        if (cppLibs.contains(lib)) {
          // Remove any stale copy that may have been placed here previously.
          final stale = File(p.join(classesDir.path, name));
          if (stale.existsSync()) stale.deleteSync();
          continue;
        }
        file.copySync(p.join(classesDir.path, name));
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
}

/// Returns the set of lib names that are NativeImpl.cpp modules, by reading
/// the *.native.dart spec files in lib/.
Set<String> _discoverCppLibs(String workingDirectory) {
  final libDir = Directory(p.join(workingDirectory, 'lib'));
  if (!libDir.existsSync()) return {};
  final result = <String>{};
  for (final file in libDir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.native.dart')) continue;
    final content = file.readAsStringSync();
    final libMatch = RegExp(r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''').firstMatch(content);
    if (libMatch == null) continue;
    final annotationMatch = RegExp(r'@NitroModule\s*\(([^)]+)\)').firstMatch(content);
    if (annotationMatch == null) continue;
    final annotation = annotationMatch.group(1)!;
    // A module is "cpp" when both platform impls are NativeImpl.cpp.
    final cppCount = RegExp(r'NativeImpl\.cpp').allMatches(annotation).length;
    if (cppCount >= 2) result.add(libMatch.group(1)!);
  }
  return result;
}
