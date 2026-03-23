import 'dart:io';

/// The hardcoded baseline version.
/// In a true "automatic" setup, this could be updated by a build script,
/// but here we use it as a fallback if pubspec detection fails.
const String nitrogenVersion = '0.1.9';

/// Dynamically resolves the version of nitrogen from its own pubspec.yaml.
/// This works even when globally activated by looking near the script file.
String _getOwnVersion() {
  try {
    // 1. Try to find pubspec.yaml relative to the script entry point.
    // Platform.script points to the entry script (e.g. bin/nitrogen.dart)
    final scriptPath = Platform.script.toFilePath();
    final scriptFile = File(scriptPath);

    // We expect the script to be in bin/ or a snapshot nearby.
    // If bin/nitrogen.dart, then root is parent of bin/.
    var current = scriptFile.parent;
    while (current.path != current.parent.path) {
      final pubspec = File('${current.path}/pubspec.yaml');
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        if (content.contains('name: nitrogen_cli')) {
          for (final line in content.split('\n')) {
            if (line.trim().startsWith('version:')) {
              return line.replaceFirst('version:', '').trim();
            }
          }
        }
      }
      current = current.parent;
    }
  } catch (_) {
    // Fallback
  }
  return nitrogenVersion;
}

final String activeVersion = _getOwnVersion();
