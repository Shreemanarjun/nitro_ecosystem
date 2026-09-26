part of '../link_command.dart';

// Starter Swift/Kotlin implementations. `link` registers an impl class for
// every Swift/Kotlin module (`XRegistry.register(Y())`,
// `XJniBridge.registerFactory({ Y() })`) but a module added after `init` had
// no such class: the plugin failed to compile until one was hand-written with
// the exact name and every member. Each missing class gets a starter built
// from the generated protocol / interface; members fail loudly until filled.
// Never touches an existing class.

/// Writes missing Swift and Kotlin impl classes. Returns the Apple platforms
/// (`ios`/`macos`) that received a new file (their SwiftPM sources need a resync).
Set<String> linkNativeImplStarters({String baseDir = '.'}) {
  final generated = p.join(baseDir, 'lib', 'src', 'generated');
  final touched = <String>{};
  for (final platform in ['ios', 'macos']) {
    final classes = Directory(p.join(baseDir, platform, 'Classes'));
    if (!classes.existsSync()) continue;
    final sources = classes.listSync().whereType<File>().where((f) => f.path.endsWith('.swift')).toList();
    final plugin = sources.where((f) => f.path.endsWith('Plugin.swift')).firstOrNull;
    if (plugin == null) continue;
    final existing = sources.map((f) => f.readAsStringSync()).join('\n');
    for (final m in RegExp(r'(\w+)Registry\.register\((\w+)\(').allMatches(plugin.readAsStringSync())) {
      final (module, cls) = (m.group(1)!, m.group(2)!);
      if (RegExp('class\\s+$cls\\b').hasMatch(existing)) continue;
      final members = _protocolMembers(Directory(p.join(generated, 'swift')), 'public protocol Hybrid${module}Protocol: AnyObject {', '.swift');
      if (members == null) continue;
      File(p.join(classes.path, '$cls.swift')).writeAsStringSync(_swiftStarter(module, cls, members));
      touched.add(platform);
    }
  }

  final ktRoot = Directory(p.join(baseDir, 'android', 'src', 'main', 'kotlin'));
  if (ktRoot.existsSync()) {
    final kts = ktRoot.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt')).toList();
    final plugin = kts.where((f) => f.path.endsWith('Plugin.kt')).firstOrNull;
    if (plugin != null) {
      final pluginSrc = plugin.readAsStringSync();
      final pkg = RegExp(r'^package\s+([\w.]+)', multiLine: true).firstMatch(pluginSrc)?.group(1);
      final existing = kts.map((f) => f.readAsStringSync()).join('\n');
      for (final m in RegExp(r'(\w+)JniBridge\.registerFactory\(\{\s*(\w+)\(').allMatches(pluginSrc)) {
        final (module, cls) = (m.group(1)!, m.group(2)!);
        if (pkg == null || RegExp('class\\s+$cls\\b').hasMatch(existing)) continue;
        final genFile = _fileDeclaring(Directory(p.join(generated, 'kotlin')), 'interface Hybrid${module}Spec {', '.kt');
        final members = genFile == null ? null : _blockMembers(genFile.readAsStringSync(), 'interface Hybrid${module}Spec {');
        if (members == null) continue;
        final imports = RegExp(r'^import .+$', multiLine: true).allMatches(genFile!.readAsStringSync()).map((i) => i.group(0)!).toSet();
        final genPkg = RegExp(r'^package\s+([\w.]+)', multiLine: true).firstMatch(genFile.readAsStringSync())!.group(1)!;
        File(p.join(plugin.parent.path, '$cls.kt')).writeAsStringSync(_kotlinStarter(pkg, genPkg, imports, module, cls, members));
      }
    }
  }
  return touched;
}

File? _fileDeclaring(Directory dir, String decl, String ext) {
  if (!dir.existsSync()) return null;
  return dir.listSync().whereType<File>().where((f) => f.path.endsWith(ext) && f.readAsStringSync().contains(decl)).firstOrNull;
}

List<String>? _protocolMembers(Directory dir, String decl, String ext) {
  final f = _fileDeclaring(dir, decl, ext);
  return f == null ? null : _blockMembers(f.readAsStringSync(), decl);
}

/// Member lines of the `{ … }` block opened by [decl] (comments dropped).
List<String>? _blockMembers(String src, String decl) {
  final start = src.indexOf(decl);
  if (start < 0) return null;
  final end = src.indexOf('\n}', start);
  return src.substring(start + decl.length, end).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('//')).toList();
}

String _swiftStarter(String module, String cls, List<String> members) {
  final body = StringBuffer();
  for (final m in members) {
    final todo = 'fatalError("TODO: implement $cls.${RegExp(r'(?:func|var)\s+(\w+)').firstMatch(m)?.group(1)}")';
    final prop = RegExp(r'^var (.+) \{ (get(?: async throws)?)( set)? \}$').firstMatch(m);
    if (prop != null) {
      final accessor = prop.group(2)!;
      body.writeln(prop.group(3) != null
          ? '    public var ${prop.group(1)} {\n        get { $todo }\n        set { $todo }\n    }'
          : accessor == 'get'
              ? '    public var ${prop.group(1)} { $todo }'
              : '    public var ${prop.group(1)} { $accessor { $todo } }');
    } else if (m.startsWith('func ')) {
      body.writeln('    public $m { $todo }');
    }
  }
  return '// Starter for Hybrid${module}Protocol — written once by `nitrogen link`; yours to edit.\n'
      'import Combine\nimport Foundation\n\n'
      'public class $cls: Hybrid${module}Protocol {\n    public init() {}\n\n$body}\n';
}

String _kotlinStarter(String pkg, String genPkg, Set<String> imports, String module, String cls, List<String> members) {
  final body = StringBuffer();
  for (final m in members) {
    if (m.contains('=') || m.endsWith('{}') || m.contains('{')) continue; // interface defaults
    final name = RegExp(r'(?:fun|va[lr])\s+(\w+)').firstMatch(m)?.group(1);
    final todo = 'TODO("implement $cls.$name")';
    if (m.startsWith('var ')) {
      body.writeln('    override $m\n        get() = $todo\n        set(value) { $todo }');
    } else if (m.startsWith('val ')) {
      body.writeln('    override $m get() = $todo');
    } else if (m.contains('fun ')) {
      body.writeln('    override $m = $todo');
    }
  }
  return '// Starter for Hybrid${module}Spec — written once by `nitrogen link`; yours to edit.\n'
      'package $pkg\n\n'
      '${({...imports, 'import $genPkg.*'}.toList()..sort()).join('\n')}\n\n'
      '@Suppress("UNUSED_PARAMETER")\n'
      'class $cls : Hybrid${module}Spec {\n$body}\n';
}

/// [linkNativeImplStarters], then resyncs SwiftPM sources on the Apple
/// platforms that got a new file (the sync ran before registrations existed).
void writeImplStarters(String pluginName, List<ModuleInfo> moduleInfos, {String baseDir = '.'}) {
  final touched = linkNativeImplStarters(baseDir: baseDir);
  if (touched.contains('ios')) ensureIosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);
  if (touched.contains('macos')) ensureMacosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);
}
