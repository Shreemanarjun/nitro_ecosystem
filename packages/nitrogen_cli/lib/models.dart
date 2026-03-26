import 'dart:io';

enum NitroCommand {
  init(
    'Initialize',
    'Scaffold a new Nitro FFI plugin project.',
    '/init',
    'Creates all necessary boilerplate for your C++/Kotlin/Swift bridges.',
  ),
  generate(
    'Generate',
    'Run the Nitro code generator (build_runner).',
    '/generate',
    'Parses your Dart interfaces and generates the native marshalling code.',
  ),
  link(
    'Link',
    'Wire native bridges into the build system.',
    '/link',
    'Automatically configures CMake, Gradle, and CocoaPods for your bridges.',
  ),
  doctor(
    'Doctor',
    'Check if the plugin is production-ready.',
    '/doctor',
    'Validates your project structure, native dependencies, and environment.',
  ),
  update(
    'Update',
    'Self-update the Nitrogen CLI.',
    '/update',
    'Fetches the latest version of nitrogen from pub.dev.',
  ),
  openCode(
    'Open in VS Code',
    'Open project in VS Code.',
    '/',
    'Launches standard VS Code for development.',
  ),
  openAntigravity(
    'Open in Antigravity',
    'Open project in Antigravity.',
    '/',
    'Launches the Antigravity editor for AI-first development.',
  ),
  exit(
    'Exit',
    'Close the Nitrogen CLI.',
    '/exit',
    'Quits the interactive dashboard session.',
  );

  const NitroCommand(this.label, this.description, this.path, this.longInfo);
  final String label;
  final String description;
  final String path;
  final String longInfo;
}

class ProjectInfo {
  final String name;
  final String version;
  final Directory directory;
  const ProjectInfo(this.name, this.version, this.directory);
}
