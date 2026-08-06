part of '../link_command.dart';

// Desktop linking: Windows/Linux FFI pubspec + platform impl stubs.
// Part of the link_command library.

/// True when [pluginClass] is backed by a real implementation under
/// `<baseDir>/<platform>/` — i.e. the platform sources define the exact
/// symbol Flutter's generated_plugin_registrant will call:
///   windows → `<PluginClass>RegisterWithRegistrar`,
///   linux → `<snake_case(PluginClass)>_register_with_registrar`.
/// A dangling templated class (issue #10) has no such symbol and must be
/// stripped, or CMake fails with "No target `<plugin>_plugin`". A hand-written
/// hybrid plugin (`ffiPlugin: true` PLUS `pluginClass` — e.g. FFI bindings
/// with a texture-registrar plugin class) defines it, and stripping the
/// entry silently empties the registrant at runtime (issue #23).
bool _desktopPluginClassIsReal(String baseDir, String platform, String pluginClass) {
  final dir = Directory(p.join(baseDir, platform));
  if (!dir.existsSync()) return false;
  final symbol = platform == 'windows' ? '${pluginClass}RegisterWithRegistrar' : '${_snakeCasePluginClass(pluginClass)}_register_with_registrar';
  final srcRe = RegExp(r'\.(c|cc|cpp|h|hpp)$');
  for (final f in dir.listSync(recursive: true, followLinks: false).whereType<File>()) {
    final path = f.path.replaceAll(r'\', '/');
    if (path.contains('/ephemeral/') || path.contains('/build/') || path.contains('/.symlinks/')) continue;
    if (!srcRe.hasMatch(path)) continue;
    try {
      if (f.readAsStringSync().contains(symbol)) return true;
    } catch (_) {
      // Unreadable/binary file — not the registrant source.
    }
  }
  return false;
}

void linkDesktopPubspecFfiOnly(
  List<ModuleInfo> moduleInfos, {
  String baseDir = '.',
}) {
  final pubspecFile = File(p.join(baseDir, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) return;
  final fixWindows = moduleInfos.any((m) => m.windowsIsCpp);
  final fixLinux = moduleInfos.any((m) => m.linuxIsCpp);
  if (!fixWindows && !fixLinux) return;

  final targets = <String>{if (fixWindows) 'windows', if (fixLinux) 'linux'};
  final lines = pubspecFile.readAsStringSync().split('\n');
  final out = <String>[];
  var inPlatforms = false;
  var platformsIndent = -1;
  var changed = false;

  int indentOf(String l) => l.length - l.trimLeft().length;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed == 'platforms:') {
      inPlatforms = true;
      platformsIndent = indentOf(line);
      out.add(line);
      continue;
    }
    if (inPlatforms && trimmed.isNotEmpty && indentOf(line) <= platformsIndent) {
      inPlatforms = false; // left the platforms block
    }

    final stripped = _ffiStrippedFlowMapLine(line, targets, baseDir, inPlatforms);
    if (stripped != null) {
      out.add(stripped);
      changed = true;
      continue;
    }

    final block = _ffiEmitBlockFormEntry(
      lines,
      i,
      line,
      targets,
      baseDir,
      inPlatforms,
      out,
    );
    if (block.handled) {
      if (block.changed) changed = true;
      i = block.lastIndex;
      continue;
    }

    out.add(line);
  }

  if (changed) {
    pubspecFile.writeAsStringSync(out.join('\n'));
    stdout.writeln('  pubspec.yaml: removed pluginClass from FFI-only desktop platform entries (fixes "No target <plugin>_plugin")');
  }
}

/// Returns the rewritten inline flow-map line (e.g. `windows: { ffiPlugin:
/// true }`) with a DANGLING `pluginClass:` stripped, or null when [line] is
/// not a target-platform flow map, lacks ffiPlugin+pluginClass, or the class
/// is real (a user-owned hybrid config, issue #23).
String? _ffiStrippedFlowMapLine(
  String line,
  Set<String> targets,
  String baseDir,
  bool inPlatforms,
) {
  final flowMatch = inPlatforms ? RegExp(r'^(\s*)(\w+):\s*\{(.*)\}\s*$').firstMatch(line) : null;
  if (flowMatch != null && targets.contains(flowMatch.group(2))) {
    // Inline flow map: windows: { pluginClass: Xxx, ffiPlugin: true }
    final entries = flowMatch.group(3)!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (entries.any((e) => e.startsWith('ffiPlugin:')) && entries.any((e) => e.startsWith('pluginClass:'))) {
      // Only strip a DANGLING class — one with no registrant implementation
      // in the platform sources. ffiPlugin + a real pluginClass is a
      // documented hybrid configuration and user-owned (issue #23).
      final cls = entries.firstWhere((e) => e.startsWith('pluginClass:')).substring('pluginClass:'.length).trim();
      if (!_desktopPluginClassIsReal(baseDir, flowMatch.group(2)!, cls)) {
        entries.removeWhere((e) => e.startsWith('pluginClass:'));
        return '${flowMatch.group(1)}${flowMatch.group(2)}: { ${entries.join(', ')} }';
      }
    }
  }
  return null;
}

/// Processes a block-form target platform entry beginning at [line] (index
/// [i]): appends it and its children to [out], dropping a dangling
/// `pluginClass:` child (ffiPlugin present + class not real). Returns
/// handled=false when [line] is not a target block; otherwise the index of
/// the last consumed line and whether a class was stripped.
({bool handled, int lastIndex, bool changed}) _ffiEmitBlockFormEntry(
  List<String> lines,
  int i,
  String line,
  Set<String> targets,
  String baseDir,
  bool inPlatforms,
  List<String> out,
) {
  final blockKey = inPlatforms ? RegExp(r'^(\s*)(\w+):\s*$').firstMatch(line) : null;
  if (blockKey == null || !targets.contains(blockKey.group(2))) {
    return (handled: false, lastIndex: i, changed: false);
  }
  int indentOf(String l) => l.length - l.trimLeft().length;
  var changed = false;
  // Block form: collect the child lines (strictly deeper indent).
  final keyIndent = indentOf(line);
  var end = i + 1;
  while (end < lines.length && (lines[end].trim().isEmpty || indentOf(lines[end]) > keyIndent)) {
    end++;
  }
  final children = lines.sublist(i + 1, end);
  final hasFfi = children.any((l) => l.trim().startsWith('ffiPlugin:') && l.contains('true'));
  final hasClass = children.any((l) => l.trim().startsWith('pluginClass:'));
  // Only strip a DANGLING class — one whose registrant symbol appears
  // nowhere in the platform sources. ffiPlugin + a real pluginClass is a
  // documented hybrid configuration and user-owned (issue #23).
  var classIsDangling = false;
  if (hasFfi && hasClass) {
    final cls = children.firstWhere((l) => l.trim().startsWith('pluginClass:')).trim().substring('pluginClass:'.length).trim();
    classIsDangling = !_desktopPluginClassIsReal(baseDir, blockKey.group(2)!, cls);
  }
  out.add(line);
  for (final child in children) {
    if (hasFfi && hasClass && classIsDangling && child.trim().startsWith('pluginClass:')) {
      changed = true;
      continue;
    }
    out.add(child);
  }
  return (handled: true, lastIndex: end - 1, changed: changed);
}

/// Returns the index of the `}` that closes the block whose opening `{` is at [openBrace].
int _findBlockEnd(String content, int openBrace) {
  int depth = 0;
  for (int i = openBrace; i < content.length; i++) {
    if (content[i] == '{') {
      depth++;
    } else if (content[i] == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Content for a brand-new `$platform/src/Hybrid$className.cpp` file.
///
/// When [requestsSeparateImpl] is true (the annotation used the platform's
/// SPECIFIC marker type — see requestsSeparateWindowsImpl/requestsSeparateLinuxImpl)
/// AND the shared `src/Hybrid$className.cpp` already has real code (not just
/// the auto-generated  stub), that content is migrated in — one include
/// path level deeper to account for the extra directory — so this platform
/// starts from its EXISTING behavior rather than an empty stub. Activating
/// separation this way is a location change, not a behavior change. Falls
/// back to the generic starter template otherwise (implicit
/// hasCustomPlatformImpl-driven separation always starts empty — there's no
/// annotation signal yet at that point to justify migrating anything).
String _newPlatformImplContent({
  required String baseDir,
  required String lib,
  required String className,
  required bool requestsSeparateImpl,
  required String genericStubContent,
}) {
  if (requestsSeparateImpl) {
    final sharedFile = File(p.join(baseDir, 'src', 'Hybrid$className.cpp'));
    if (sharedFile.existsSync()) {
      final sharedContent = sharedFile.readAsStringSync();
      if (!sharedContent.contains(_implStubTodoMarker)) {
        return sharedContent.replaceAll('#include "../lib/', '#include "../../lib/');
      }
    }
  }
  return genericStubContent;
}

/// Creates `$platform/src/Hybrid$className.cpp`, or — when the annotation
/// explicitly requests per-platform separation and the file on disk is still
/// the UNTOUCHED auto-created stub — completes the migration of the shared
/// `src/Hybrid$className.cpp` content into it.
///
/// The second half is the issue #12 fix: the stub is auto-created on every
/// link (as an inert option), so by the time an author switches the
/// annotation to `WindowsNativeImpl.cpp`/`LinuxNativeImpl.cpp` the file
/// already exists and a bare "never overwrite" rule would strand the real
/// impl in the shared file while the platform CMakeLists points at the empty
/// stub. An untouched stub (TODO marker still present) is not user code —
/// replacing it with the shared impl's content is the location change the
/// explicit marker asked for. A file WITHOUT the marker is user code and is
/// never overwritten.
void _writeOrMigratePlatformImplStub({
  required String baseDir,
  required String platform,
  required String lib,
  required bool requestsSeparateImpl,
  required String genericStubContent,
}) {
  final className = _toPascalCase(lib);
  final srcDir = Directory(p.join(baseDir, platform, 'src'))..createSync(recursive: true);
  final stubFile = File(p.join(srcDir.path, 'Hybrid$className.cpp'));
  final content = _newPlatformImplContent(
    baseDir: baseDir,
    lib: lib,
    className: className,
    requestsSeparateImpl: requestsSeparateImpl,
    genericStubContent: genericStubContent,
  );
  if (!stubFile.existsSync()) {
    stubFile.writeAsStringSync(content);
    return;
  }
  final onDisk = stubFile.readAsStringSync();
  final isUntouchedStub = onDisk.contains(_implStubTodoMarker);
  final hasMigratedContent = content != genericStubContent;
  if (requestsSeparateImpl && isUntouchedStub && hasMigratedContent && onDisk != content) {
    stubFile.writeAsStringSync(content);
    stdout.writeln(
      '  $platform/src/Hybrid$className.cpp: migrated shared src/Hybrid$className.cpp content (explicit per-platform separation) — the shared file is left in place and no longer compiled for $platform',
    );
  }
}

/// Creates Windows-specific C++ impl stub files for modules that target
/// `windows: WindowsNativeImpl.cpp`. These stubs live in `windows/src/` so
/// `windows/CMakeLists.txt` can reference them via a relative path.
void linkWindowsCppImplStubs(
  List<ModuleInfo> moduleInfos, {
  String baseDir = '.',
}) {
  final libDir = Directory(p.join(baseDir, 'lib'));
  final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
  final windowsCppLibs = specFiles.where(isWindowsCppModule).map((f) {
    final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
    return extractLibNameFromSpec(f) ?? stem;
  }).toSet();

  for (final m in moduleInfos.where(
    (m) => m.isCpp && windowsCppLibs.contains(m.lib),
  )) {
    _writeOrMigratePlatformImplStub(
      baseDir: baseDir,
      platform: 'windows',
      lib: m.lib,
      requestsSeparateImpl: m.windowsRequestsSeparateImpl,
      genericStubContent: t.windowsCppStubContent(lib: m.lib, className: _toPascalCase(m.lib)),
    );
  }
}

/// Creates a Linux-specific C++ impl starter stub for every Linux-C++
/// module, mirroring [linkWindowsCppImplStubs]. Writing this stub does NOT
/// by itself make Linux use it instead of the shared `src/HybridXxx.cpp` —
/// that's a separate, opt-in decision (see [hasCustomPlatformImpl] and
/// ModuleInfo.linuxRequestsSeparateImpl, read by `_linkDesktopCMake`). Until
/// then it just sits alongside the shared file as an option, same as
/// Windows's stub always has.
void linkLinuxCppImplStubs(
  List<ModuleInfo> moduleInfos, {
  String baseDir = '.',
}) {
  for (final m in moduleInfos.where((m) => m.linuxIsCpp)) {
    _writeOrMigratePlatformImplStub(
      baseDir: baseDir,
      platform: 'linux',
      lib: m.lib,
      requestsSeparateImpl: m.linuxRequestsSeparateImpl,
      genericStubContent: t.linuxCppStubContent(lib: m.lib, className: _toPascalCase(m.lib)),
    );
  }
}

void linkWindows(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  _linkDesktopCMake(
    pluginName,
    moduleLibs,
    nitroNativePath,
    platform: 'windows',
    baseDir: baseDir,
    moduleInfos: moduleInfos,
  );
  if (moduleInfos != null) {
    linkWindowsCppImplStubs(moduleInfos, baseDir: baseDir);
  }
}

void linkLinux(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  _linkDesktopCMake(
    pluginName,
    moduleLibs,
    nitroNativePath,
    platform: 'linux',
    baseDir: baseDir,
    moduleInfos: moduleInfos,
  );
  if (moduleInfos != null) {
    linkLinuxCppImplStubs(moduleInfos, baseDir: baseDir);
  }
}

void linkClangd(
  String pluginName, {
  List<ModuleInfo>? moduleInfos,
  String baseDir = '.',
}) {
  final sb = StringBuffer()
    ..writeln('CompileFlags:')
    ..writeln('  Add:')
    ..writeln('    - -I\${PWD}/src')
    ..writeln('    - -I\${PWD}/src/native')
    ..writeln('    - -I\${PWD}/lib/src/generated/cpp')
    ..writeln('    - -I\${PWD}/src/native/internal');

  // For C++ modules also expose the test/ directory so IDEs resolve mock headers
  if (moduleInfos != null && moduleInfos.any((m) => m.isCpp)) {
    sb.writeln('    - -I\${PWD}/lib/src/generated/cpp/test');
  }
  File(p.join(baseDir, '.clangd')).writeAsStringSync(sb.toString());
}
