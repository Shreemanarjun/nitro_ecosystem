import 'dart:io';
import 'models.dart';

ProjectInfo? getProjectInfo() {
  try {
    // 1. Check current directory
    final rootInfo = parsePubspec(Directory.current);
    if (rootInfo != null) return rootInfo;

    // 2. Check direct subdirectories (common for monorepos or just-after-init)
    for (final entity in Directory.current.listSync()) {
      if (entity is Directory) {
        final info = parsePubspec(entity);
        if (info != null) return info;
      }
    }
  } catch (_) {}
  return null;
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

Future<String> getGitBranch() async {
  try {
    final result = await Process.run('git', ['branch', '--show-current']);
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
