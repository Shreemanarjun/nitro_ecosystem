import 'dart:io';
import 'models.dart';

List<ProjectInfo> getAllProjects() {
  final List<ProjectInfo> projects = [];
  try {
    // 1. Check current directory
    final rootInfo = parsePubspec(Directory.current);
    if (rootInfo != null) projects.add(rootInfo);

    // 2. Check subdirectories (up to 2 levels for monorepos)
    for (final entity in Directory.current.listSync()) {
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
