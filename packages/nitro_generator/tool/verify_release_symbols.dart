// Release gate for the names a Nitro plugin resolves at runtime instead of at
// link time. A release build removes or renames whatever nothing references by
// symbol: the Xcode archive strip drops the unmarked exports of the app binary,
// and R8 renames or removes JVM members. Neither fails the build; the app fails
// on its first native call. This reads those names from the plugin's generated
// code and checks every one against the built artifact:
//
//   Dart → native    lookup / lookupFunction / providesSymbol / @Native
//                    → Mach-O export trie (Apple), ELF .dynsym (Android)
//   Kotlin → native  external fun → still a native method in the DEX, and its
//                    Java_* function is in .dynsym
//   native → Kotlin  FindClass / Get*MethodID / Get*FieldID → DEX class and
//                    member, with the exact descriptor
//
// A debug or unstripped build passes trivially, so it is rejected unless
// --allow-unstripped is given. Build the artifact first:
//   flutter build ipa --release [--no-codesign]  → build/ios/archive/Runner.xcarchive
//   xcodebuild archive (macOS)                   → <name>.xcarchive
//   flutter build apk --release | appbundle      → app-release.apk | app-release.aab
// Usage: dart run tool/verify_release_symbols.dart --plugin <plugin dir> [--plugin …] <artifact> …
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

typedef _JvmMember = ({String? cls, String receiver, String name, String type, bool isStatic});

/// Stands for the class of an object, which `GetObjectClass` only knows at run time.
const _objectClass = '*';

/// The names one generated module (one `.native.dart` spec) resolves at runtime.
class _Module {
  _Module(this.plugin, this.name);
  final String plugin, name;
  String? lib; // first argument of NitroRuntime.loadLibForTargets
  Map<String, bool>? targets; // its platform flags; null when the code has none
  final lookups = <String>{}; // found in the process (Apple) or in lib<lib>.so (Android)
  final initLookups = <String, Set<String>>{}; // those bound in a static `X._init`, by class X
  final unbound = <String>{}; // those whose `X._init` nothing calls
  final assetSymbols = <String, String>{}; // @Native symbol → assetId
  final dynamicNames = <String>[]; // where a lookup name is not a literal
  final externals = <(String, String)>{}; // Kotlin `external fun`: (class, method)
  final jniDefinitions = <String>{}; // JNIEXPORT functions of the C++ bridge
  final jvmClasses = <String>{}; // FindClass
  final jvmMembers = <_JvmMember>[]; // Get(Static)MethodID / Get(Static)FieldID
  var kotlinPackage = '', kotlin = ''; // the Kotlin bridge: its package, as a path, and its source

  bool get resolvesNames => lookups.isNotEmpty || assetSymbols.isNotEmpty || dynamicNames.isNotEmpty;
  bool targetsPlatform(String platform) => targets?[platform] ?? true;
}

class _DartNames extends RecursiveAstVisitor<void> {
  _DartNames(this.module, this.initialised, this.where);
  final _Module module;
  final Set<String> initialised; // classes whose `_init` is called, plugin-wide
  final String Function(AstNode) where;

  /// The class whose static `_init(DynamicLibrary)` contains [node]. A
  /// generated struct proxy binds its release symbol there, and the impl class
  /// that uses the proxy calls it. A type-only spec declares the proxy too,
  /// with no impl class to call it and no bridge that defines the symbol.
  String? _initOwner(AstNode node) {
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method == null || !method.isStatic || method.name.lexeme != '_init') return null;
    return method.thisOrAncestorOfType<ClassDeclaration>()?.namePart.typeName.lexeme;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final args = node.argumentList.arguments;
    final first = args.isEmpty ? null : args.first.argumentExpression;
    final name = first is StringLiteral ? first.stringValue : null;
    switch (node.methodName.name) {
      // Without type arguments it is not dart:ffi's lookup. Generated code
      // probes a symbol only to throw a clearer error when it is absent.
      case 'lookup' || 'lookupFunction' when node.typeArguments != null:
      case 'providesSymbol':
        if (name == null) {
          module.dynamicNames.add(where(node));
        } else if (_initOwner(node) case final owner?) {
          (module.initLookups[owner] ??= {}).add(name);
        } else {
          module.lookups.add(name);
        }
      case '_init':
        // `X._init(dylib)`, or a bare `_init(dylib)` inside X itself.
        final cls = switch (node.target) {
          SimpleIdentifier(:final name) => name,
          null => node.thisOrAncestorOfType<ClassDeclaration>()?.namePart.typeName.lexeme,
          _ => null,
        };
        if (cls != null) initialised.add(cls);
      case 'loadLibForTargets' || 'checkSupportedPlatform' when name != null:
        module.lib = name;
        module.targets = {
          for (final arg in args.whereType<NamedArgument>())
            if (arg.argumentExpression case BooleanLiteral(:final value)) arg.name.lexeme: value,
        };
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    final name = node.name;
    if ((name is PrefixedIdentifier ? name.identifier.name : name.name) == 'Native') {
      String? symbol, assetId;
      for (final arg in node.arguments?.arguments.whereType<NamedArgument>() ?? const <NamedArgument>[]) {
        final value = arg.argumentExpression;
        if (value is! StringLiteral) continue;
        if (arg.name.lexeme == 'symbol') symbol = value.stringValue;
        if (arg.name.lexeme == 'assetId') assetId = value.stringValue;
      }
      // Without `symbol:` the VM resolves the declaration's own name.
      symbol ??= switch (node.parent) {
        FunctionDeclaration(:final name) => name.lexeme,
        MethodDeclaration(:final name) => name.lexeme,
        _ => null,
      };
      if (symbol == null) {
        module.dynamicNames.add(where(node));
      } else {
        module.assetSymbols[symbol] = assetId ?? '';
      }
    }
    super.visitAnnotation(node);
  }
}

void _readCppBridge(_Module module, String source) {
  for (final definition in RegExp(r'JNIEXPORT\s+[\w\s*]+?\s+JNICALL\s+(\w+)\s*\(').allMatches(source)) {
    module.jniDefinitions.add(definition[1]!);
  }
  for (final cls in RegExp(r'FindClass\("([^"]+)"\)').allMatches(source)) {
    module.jvmClasses.add(cls[1]!);
  }
  // A member lookup names its class through a jclass variable. Follow each
  // variable back to the FindClass that filled it, or to the bridge class that
  // Kotlin hands to initialize().
  final classOf = <String, String>{};
  final steps = RegExp(
    r'(?<found>\w+)\s*=\s*(?:\(jclass\)\s*)?env->FindClass\("(?<class>[^"]+)"\)'
    r'|(?<global>\w+)\s*=\s*\(jclass\)\s*env->NewGlobalRef\((?<local>\w+)\)'
    r'|(?<object>\w+)\s*=\s*env->GetObjectClass\('
    r'|Java_(?<bridge>\w+)_initialize\s*\([^)]*\bjclass\s+(?<parameter>\w+)'
    r'|Get(?<static>Static)?(?:Method|Field)ID\(\s*(?<receiver>\w+|env->GetObjectClass\([^)]*\))\s*,\s*"(?<name>[^"]+)"\s*,\s*"(?<type>[^"]+)"\s*\)',
  );
  for (final step in steps.allMatches(source)) {
    if (step.namedGroup('found') case final variable?) {
      classOf[variable] = step.namedGroup('class')!;
    } else if (step.namedGroup('global') case final variable?) {
      if (classOf[step.namedGroup('local')] case final cls?) classOf[variable] = cls;
    } else if (step.namedGroup('object') case final variable?) {
      classOf[variable] = _objectClass;
    } else if (step.namedGroup('bridge') case final bridge?) {
      classOf[step.namedGroup('parameter')!] = bridge.replaceAll('_1', '\x00').replaceAll('_', '/').replaceAll('\x00', '_');
    } else {
      final receiver = step.namedGroup('receiver')!;
      module.jvmMembers.add((
        cls: receiver.startsWith('env->') ? _objectClass : classOf[receiver],
        receiver: receiver,
        name: step.namedGroup('name')!,
        type: step.namedGroup('type')!,
        isStatic: step.namedGroup('static') != null,
      ));
    }
  }
  // A global that is filled further down the file than its first use.
  for (final (i, member) in module.jvmMembers.indexed) {
    if (member.cls == null) {
      module.jvmMembers[i] = (cls: classOf[member.receiver], receiver: member.receiver, name: member.name, type: member.type, isStatic: member.isStatic);
    }
  }
}

void _readKotlinBridge(_Module module, String source) {
  final package = RegExp(r'^package\s+([\w.]+)', multiLine: true).firstMatch(source)?[1]?.replaceAll('.', '/') ?? '';
  module.kotlinPackage = package;
  module.kotlin = source;
  var cls = '';
  for (final line in const LineSplitter().convert(source)) {
    cls = RegExp(r'^(?:\w+ )*(?:object|class|interface) (\w+)').firstMatch(line)?[1] ?? cls;
    final external = RegExp(r'\bexternal fun (\w+)\s*\(').firstMatch(line)?[1];
    if (external != null) module.externals.add(('$package/$cls', external));
  }
}

List<_Module> _readPlugin(String dir) {
  final pubspec = File(p.join(dir, 'pubspec.yaml'));
  if (!pubspec.existsSync()) _die('$dir is not a package: it has no pubspec.yaml');
  final plugin = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec.readAsStringSync())?[1] ?? p.basename(dir);
  final modules = <String, _Module>{};
  final initialised = <String>{};
  // `geo.g.dart`, `geo.bridge.g.cpp` and `geo.bridge.g.kt` are one module.
  _Module module(String path) {
    final name = p.basename(path).split('.').first;
    return modules.putIfAbsent(name, () => _Module(plugin, name));
  }

  for (final file in Directory(p.join(dir, 'lib')).listSync(recursive: true).whereType<File>()) {
    final path = file.path;
    final relative = p.relative(path, from: dir);
    // The web bridge resolves its names in the wasm module, not in this artifact.
    if (p.split(relative).contains('web') || relative.contains('.web.')) continue;
    if (path.endsWith('.dart')) {
      final unit = parseString(content: file.readAsStringSync(), path: path, throwIfDiagnostics: false).unit;
      unit.accept(_DartNames(module(path), initialised, (node) => '$relative:${unit.lineInfo.getLocation(node.offset).lineNumber}'));
    } else if (path.endsWith('.bridge.g.cpp')) {
      _readCppBridge(module(path), file.readAsStringSync());
    } else if (path.endsWith('.bridge.g.kt')) {
      _readKotlinBridge(module(path), file.readAsStringSync());
    }
  }
  // `_init` is private to its library, and every file of that library is
  // under lib/, so a proxy nothing here initialises never binds its symbols.
  for (final module in modules.values) {
    module.initLookups.forEach((cls, symbols) => (initialised.contains(cls) ? module.lookups : module.unbound).addAll(symbols));
  }
  final resolving = modules.values.where((m) => m.resolvesNames || m.unbound.isNotEmpty).toList()..sort((a, b) => a.name.compareTo(b.name));
  if (resolving.isEmpty) _die('$dir: no generated code under lib/ resolves a native symbol — run `nitrogen generate` first');
  return resolving;
}

// ── Tools ────────────────────────────────────────────────────────────────────

Never _die(String message) {
  stderr.writeln('verify_release_symbols: $message');
  exit(2);
}

String _run(String tool, List<String> args) {
  final ProcessResult result;
  try {
    // dexdump prints modified UTF-8, which the UTF-8 decoder rejects.
    result = Process.runSync(tool, args, stdoutEncoding: latin1, stderrEncoding: latin1);
  } on ProcessException catch (e) {
    _die('cannot run $tool: ${e.message}');
  }
  if (result.exitCode != 0) _die('$tool ${args.join(' ')} exited ${result.exitCode}: ${(result.stderr as String).trim()}');
  return result.stdout as String;
}

List<String> _directories(String path) => Directory(path).existsSync() ? [for (final dir in Directory(path).listSync().whereType<Directory>()) dir.path] : const [];

/// The newest installed `dexdump` (build-tools) or `llvm-nm` (NDK).
String _androidTool(String name) {
  final home = Platform.environment['HOME'] ?? '';
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      (Platform.isMacOS ? p.join(home, 'Library', 'Android', 'sdk') : p.join(home, 'Android', 'Sdk'));
  final installed = [
    for (final version in _directories(p.join(sdk, 'build-tools'))) p.join(version, name),
    for (final version in _directories(p.join(sdk, 'ndk')))
      for (final host in _directories(p.join(version, 'toolchains', 'llvm', 'prebuilt'))) p.join(host, 'bin', name),
  ].where((path) => File(path).existsSync()).toList()..sort();
  if (installed.isEmpty) _die('$name was not found under $sdk — set ANDROID_HOME to an SDK that has build-tools and an NDK');
  return installed.last;
}

String _some(Iterable<String> names) => names.length <= 8 ? names.join(', ') : '${names.take(8).join(', ')} … +${names.length - 8} more';

/// `{assetId: file name}` from the app's NativeAssetsManifest.json, which is
/// where the VM finds the library behind an `@Native(assetId:)` symbol.
Map<String, String> _nativeAssets(String root) {
  final assets = <String, String>{};
  for (final file in Directory(root).listSync(recursive: true).whereType<File>()) {
    if (p.basename(file.path) != 'NativeAssetsManifest.json') continue;
    final targets = (jsonDecode(file.readAsStringSync()) as Map)['native-assets'] as Map? ?? const {};
    for (final target in targets.values) {
      (target as Map).forEach((id, location) => assets['$id'] = p.basename('${(location as List).last}'));
    }
  }
  return assets;
}

bool _report(String label, _Module module, List<String> problems, String passed) {
  if (module.dynamicNames.isNotEmpty) {
    problems.add('${module.dynamicNames.length} lookups build their name at runtime and cannot be checked: ${_some(module.dynamicNames)}');
  }
  final unbound = module.unbound.isEmpty ? '' : ' (${module.unbound.length} bound by a proxy that nothing initialises: ${_some(module.unbound)})';
  if (problems.isEmpty && !module.resolvesNames) {
    print('  –  $label: resolves nothing$unbound');
    return true;
  }
  print(problems.isEmpty ? '  ✓  $label: $passed$unbound' : '  ✗  $label');
  for (final problem in problems) {
    print('       $problem');
  }
  return problems.isEmpty;
}

// ── Apple ────────────────────────────────────────────────────────────────────

/// What dlsym can find in [image]: its export trie, not its symbol table.
Set<String> _machoExports(String image) {
  final slices = <Set<String>>[];
  for (final line in const LineSplitter().convert(_run('xcrun', ['dyld_info', '-exports', image]))) {
    if (RegExp(r' \[[\w.]+\]:$').hasMatch(line)) slices.add({});
    final symbol = RegExp(r'^\s+0x[0-9A-Fa-f]+\s+_(\S+)').firstMatch(line)?[1];
    if (symbol != null && slices.isNotEmpty) slices.last.add(symbol);
  }
  // A symbol missing from one architecture is missing.
  return slices.isEmpty ? {} : slices.reduce((a, b) => a.intersection(b));
}

bool _checkApple(String app, List<_Module> modules, bool allowUnstripped) {
  final isMacos = Directory(p.join(app, 'Contents', 'MacOS')).existsSync();
  final platform = isMacos ? 'macos' : 'ios';
  final root = isMacos ? p.join(app, 'Contents') : app;
  final executable = _run('plutil', ['-extract', 'CFBundleExecutable', 'raw', p.join(root, 'Info.plist')]).trim();
  final main = isMacos ? p.join(root, 'MacOS', executable) : p.join(root, executable);

  // Embedded images, by the name other images link them under.
  final embedded = <String, String>{
    for (final entry in _directories(p.join(root, 'Frameworks')))
      if (entry.endsWith('.framework')) p.basenameWithoutExtension(entry): p.join(entry, p.basenameWithoutExtension(entry)),
    if (Directory(p.join(root, 'Frameworks')).existsSync())
      for (final entry in Directory(p.join(root, 'Frameworks')).listSync().whereType<File>())
        if (entry.path.endsWith('.dylib')) p.basename(entry.path): entry.path,
  };
  // DynamicLibrary.process() searches what dyld loaded at launch: the
  // executable and everything it links, transitively.
  final loaded = <String>{main};
  final unvisited = [main];
  while (unvisited.isNotEmpty) {
    for (final line in const LineSplitter().convert(_run('otool', ['-L', unvisited.removeLast()]))) {
      final dependency = RegExp(r'^\s+(\S+) \(').firstMatch(line)?[1];
      final image = dependency == null ? null : embedded[p.basename(dependency)];
      if (image != null && loaded.add(image)) unvisited.add(image);
    }
  }
  final exportsOf = <String, Set<String>>{};
  Set<String> exports(String image) => exportsOf.putIfAbsent(image, () => _machoExports(image));
  final inProcess = <String, String>{
    for (final image in loaded)
      for (final symbol in exports(image)) symbol: p.basename(image),
  };

  // The archive strip (STRIP_STYLE=all) leaves the executable only the
  // exports marked REFERENCED_DYNAMICALLY and its weak definitions, which dyld
  // binds by name. If any other is still there, this build was not stripped
  // that way and proves nothing about one that is.
  final unmarked = const LineSplitter()
      .convert(_run('nm', ['-m', '-g', '-U', main]))
      .where((line) => line.contains(' external ') && !line.contains(' weak external ') && !line.contains('[referenced dynamically]'))
      .length;
  print('${p.basename(app)}  ($platform)  executable ${unmarked == 0 ? 'is archive-stripped' : 'is NOT archive-stripped: $unmarked unmarked exports remain'}');
  var ok = unmarked == 0 || allowUnstripped;
  if (!ok) print('  ✗  not a release archive — build one, or pass --allow-unstripped to check this build anyway');

  final assets = _nativeAssets(app);
  for (final module in modules) {
    final label = '${module.plugin}/${module.name}';
    if (!module.targetsPlatform(platform)) {
      print('  –  $label: not targeted on $platform');
      continue;
    }
    final problems = <String>[];
    final images = <String>{};
    final missing = <String>[];
    for (final symbol in module.lookups) {
      final image = inProcess[symbol];
      if (image == null) {
        missing.add(symbol);
      } else {
        images.add(image);
      }
    }
    if (missing.isNotEmpty) problems.add('${missing.length} of ${module.lookups.length} Dart lookups are not exported: ${_some(missing)}');
    for (final assetId in module.assetSymbols.values.toSet()) {
      final symbols = [
        for (final MapEntry(key: symbol, value: id) in module.assetSymbols.entries)
          if (id == assetId) symbol,
      ];
      // Without an assetId the VM falls back to a process lookup.
      final file = assets[assetId];
      final image = file == null ? null : embedded[file] ?? embedded[p.basenameWithoutExtension(file)];
      if (assetId.isNotEmpty && image == null) {
        problems.add('asset $assetId (${symbols.length} @Native symbols) is not bundled in this app');
        continue;
      }
      final absent = symbols.where((s) => image == null ? !inProcess.containsKey(s) : !exports(image).contains(s)).toList();
      if (absent.isNotEmpty) {
        problems.add('${absent.length} of ${symbols.length} @Native symbols are not exported by ${image == null ? 'the process' : p.basename(image)}: ${_some(absent)}');
      }
      if (image != null) images.add(p.basename(image));
    }
    ok = _report(label, module, problems, '${module.lookups.length + module.assetSymbols.length} Dart symbols in ${images.join(', ')}') && ok;
  }
  return ok;
}

// ── Android ──────────────────────────────────────────────────────────────────

class _Dex {
  final superclassOf = <String, String>{};
  final members = <String, Map<String, String>>{}; // class → `name:descriptor` → access flags
  final natives = <String>{}; // `class.method`
  var shrunk = false;

  /// The access flags of [key] in [cls] or in the nearest superclass that has it.
  String? member(String cls, String key) {
    for (String? c = 'L$cls;'; c != null; c = superclassOf[c]) {
      if (members[c]?[key] case final flags?) return flags;
    }
    return null;
  }

  bool anyClassHas(String package, String key, {required bool isStatic}) =>
      members.entries.any((cls) => cls.key.startsWith('L$package/') && cls.value[key]?.contains('STATIC') == isStatic);
}

_Dex _readDex(List<String> dexFiles) {
  final dex = _Dex();
  // R8 leaves a `~~R8{…}` marker in the string pool; D8 alone leaves `~~D8{…}`.
  dex.shrunk = dexFiles.any((file) => latin1.decode(File(file).readAsBytesSync()).contains('~~R8{'));
  final field = RegExp(r"^\s+(Class descriptor|Superclass|name|type|access)\s+: (?:'(.*)'|0x[0-9a-f]+ \((.*)\))$");
  var cls = '', name = '', type = '';
  for (final line in const LineSplitter().convert(_run(_androidTool('dexdump'), dexFiles))) {
    final match = field.firstMatch(line);
    if (match == null) continue;
    final value = match[2] ?? match[3] ?? '';
    switch (match[1]) {
      case 'Class descriptor':
        cls = value;
        dex.members[cls] = {};
      case 'Superclass':
        dex.superclassOf[cls] = value;
      case 'name':
        name = value;
      case 'type':
        type = value;
      case 'access' when name.isNotEmpty:
        dex.members[cls]!['$name:$type'] = value;
        if (value.contains('NATIVE')) dex.natives.add('$cls.$name');
        name = '';
    }
  }
  return dex;
}

String _jniMangle(String name) => name
    .replaceAllMapped(
      RegExp(r'[^A-Za-z0-9/]'),
      (m) => switch (m[0]!) {
        '_' => '_1',
        ';' => '_2',
        '[' => '_3',
        final c => '_0${c.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
      },
    )
    .replaceAll('/', '_');

bool _checkAndroid(String artifact, List<_Module> modules, bool allowUnstripped) {
  final tmp = Directory.systemTemp.createTempSync('nitro_release_symbols_');
  try {
    // unzip exits 11 for a pattern with no match: an .apk has no base/, an .aab no top-level lib/.
    Process.runSync('unzip', [
      '-q', '-o', artifact,
      for (final prefix in ['', 'base/']) ...['${prefix}lib/*', '${prefix}assets/flutter_assets/NativeAssetsManifest.json'],
      'classes*.dex', 'base/dex/*',
      '-d', tmp.path,
    ]);
    final files = tmp.listSync(recursive: true).whereType<File>().map((f) => f.path).toList();
    final dexFiles = files.where((f) => f.endsWith('.dex')).toList()..sort();
    final libraries = <String, Map<String, String>>{}; // abi → file name → path
    for (final so in files.where((f) => f.endsWith('.so'))) {
      (libraries[p.basename(p.dirname(so))] ??= {})[p.basename(so)] = so;
    }
    if (dexFiles.isEmpty || libraries.isEmpty) _die('$artifact has no DEX or no native libraries — is it an .apk or .aab?');
    // `flutter build --target-platform` ships the engine for the chosen ABIs
    // only, while Gradle still builds each plugin's library for all of its own.
    // The app cannot start on an ABI without the engine, so there is nothing
    // to resolve there.
    final skipped = [
      for (final abi in libraries.keys.toList())
        if (!libraries[abi]!.containsKey('libflutter.so') && libraries.values.any((l) => l.containsKey('libflutter.so'))) abi,
    ];
    skipped.forEach(libraries.remove);

    final dex = _readDex(dexFiles);
    final nm = _androidTool('llvm-nm');
    final dynsymOf = <String, Set<String>>{};
    // What dlsym and the JNI method resolver can find: .dynsym, not .symtab.
    Set<String> dynsym(String so) => dynsymOf.putIfAbsent(so, () => const LineSplitter().convert(_run(nm, ['-D', '--defined-only', '-j', so])).toSet());

    final abis = '${libraries.keys.join(', ')}${skipped.isEmpty ? '' : '; no engine for ${skipped.join(', ')}'}';
    print('${p.basename(artifact)}  (android: $abis)  DEX ${dex.shrunk ? 'is shrunk by R8' : 'is NOT shrunk by R8'}');
    var ok = dex.shrunk || allowUnstripped;
    if (!ok) print('  ✗  not a release build — build with --release, or pass --allow-unstripped to check this build anyway');

    final assets = _nativeAssets(tmp.path);
    // The framework's own classes are not in the app's DEX, and R8 cannot touch them.
    bool inApp(String cls) => !RegExp(r'^\[|^(java|javax|android|dalvik)/').hasMatch(cls);
    for (final module in modules) {
      final label = '${module.plugin}/${module.name}';
      if (!module.targetsPlatform('android')) {
        print('  –  $label: not targeted on android');
        continue;
      }
      final problems = <String>[];
      // Kotlin declares its externals for a C++ module too; they are only
      // called when the bridge implements them.
      final usesJni = module.jniDefinitions.any((d) => d.startsWith('Java_'));
      final jniSymbols = {
        if (usesJni)
          for (final (cls, method) in module.externals) 'Java_${_jniMangle(cls)}_${_jniMangle(method)}',
        if (module.jniDefinitions.contains('JNI_OnLoad')) 'JNI_OnLoad',
      };
      final byLibrary = <String, Set<String>>{
        if (module.lookups.isNotEmpty || jniSymbols.isNotEmpty) 'lib${module.lib ?? module.name}.so': {...module.lookups, ...jniSymbols},
      };
      module.assetSymbols.forEach((symbol, assetId) {
        if (assets[assetId] case final library?) {
          (byLibrary[library] ??= {}).add(symbol);
        } else if (!problems.any((problem) => problem.contains(assetId))) {
          problems.add('asset $assetId is not bundled in this app');
        }
      });
      for (final MapEntry(key: abi, value: abiLibraries) in libraries.entries) {
        byLibrary.forEach((library, symbols) {
          final so = abiLibraries[library];
          if (so == null) {
            problems.add('$abi: $library is not in the artifact');
            return;
          }
          final absent = symbols.difference(dynsym(so));
          if (absent.isNotEmpty) problems.add('$abi: ${absent.length} of ${symbols.length} symbols are not exported by $library: ${_some(absent)}');
        });
      }
      if (usesJni) {
        final removed = [
          for (final (cls, method) in module.externals)
            if (!dex.natives.contains('L$cls;.$method')) '${p.basename(cls)}.$method',
        ];
        if (removed.isNotEmpty) problems.add('${removed.length} of ${module.externals.length} external funs were renamed or removed by R8: ${_some(removed)}');
      }
      final classes = module.jvmClasses.where(inApp).toList();
      final lostClasses = classes.where((cls) => !dex.members.containsKey('L$cls;')).toList();
      if (lostClasses.isNotEmpty) problems.add('${lostClasses.length} of ${classes.length} classes the bridge finds by name are not in the DEX: ${_some(lostClasses)}');
      final unresolved = module.jvmMembers.where((m) => m.cls == null).map((m) => '${m.receiver}.${m.name}').toList();
      if (unresolved.isNotEmpty) problems.add('cannot tell which class ${unresolved.length} member lookups are on: ${_some(unresolved)}');
      // An object's class is only known at run time. A member the module's
      // own Kotlin declares, such as an enum's `nativeValue`, has to survive in
      // some class of its package; any other belongs to a framework type such
      // as java.lang.Long.
      bool declared(_JvmMember m) => RegExp('\\b(?:val|var|fun) ${RegExp.escape(m.name)}\\b').hasMatch(module.kotlin);
      final members = module.jvmMembers.where((m) => m.cls == _objectClass ? declared(m) : m.cls != null && inApp(m.cls!)).toList();
      String show(_JvmMember m) => m.type.startsWith('(') ? '${m.name}${m.type}' : '${m.name}: ${m.type}';
      final lostMembers = [
        for (final member in members)
          if (member.cls == _objectClass) ...[
            if (!dex.anyClassHas(module.kotlinPackage, '${member.name}:${member.type}', isStatic: member.isStatic))
              '<any class of ${module.kotlinPackage}>.${show(member)}',
          ] else if (dex.member(member.cls!, '${member.name}:${member.type}')?.contains('STATIC') != member.isStatic)
            '${p.basename(member.cls!)}.${show(member)}',
      ];
      if (lostMembers.isNotEmpty) problems.add('${lostMembers.length} of ${members.length} members the bridge finds by name are not in the DEX: ${_some(lostMembers)}');

      final checked = [
        '${module.lookups.length + module.assetSymbols.length} Dart symbols',
        if (jniSymbols.isNotEmpty) '${jniSymbols.length} JNI functions',
        if (classes.isNotEmpty || members.isNotEmpty) '${classes.length} classes and ${members.length} members in the DEX',
      ];
      ok = _report(label, module, problems, '${checked.join(', ')} (${byLibrary.keys.join(', ')})') && ok;
    }
    return ok;
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

bool _checkArtifact(String path, List<_Module> modules, bool allowUnstripped) {
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) _die('$path does not exist');
  // Not `every`: report each app, not only up to the first failure.
  bool apps(String dir) {
    final found = _directories(dir).where((entry) => entry.endsWith('.app')).toList();
    if (found.isEmpty) _die('$path contains no .app');
    return !found.map((app) => _checkApple(app, modules, allowUnstripped)).toList().contains(false);
  }

  switch (p.extension(path)) {
    case '.apk' || '.aab':
      return _checkAndroid(path, modules, allowUnstripped);
    case '.app':
      return _checkApple(path, modules, allowUnstripped);
    case '.xcarchive':
      return apps(p.join(path, 'Products', 'Applications'));
    case '.ipa':
      final tmp = Directory.systemTemp.createTempSync('nitro_release_symbols_');
      try {
        _run('unzip', ['-q', '-o', path, '-d', tmp.path]);
        return apps(p.join(tmp.path, 'Payload'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    default:
      _die('$path: expected an .xcarchive, .app, .ipa, .apk or .aab');
  }
}

void main(List<String> args) {
  final plugins = <String>[], artifacts = <String>[];
  var allowUnstripped = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--plugin' when i + 1 < args.length:
        plugins.add(args[++i]);
      case '--allow-unstripped':
        allowUnstripped = true;
      case final option when option.startsWith('-'):
        _die('unknown option $option');
      case final artifact:
        artifacts.add(artifact);
    }
  }
  if (plugins.isEmpty || artifacts.isEmpty) {
    _die('usage: dart run tool/verify_release_symbols.dart --plugin <plugin dir> [--plugin …] [--allow-unstripped] <.xcarchive | .app | .ipa | .apk | .aab> …');
  }
  final modules = [for (final plugin in plugins) ..._readPlugin(plugin)];
  final passed = [for (final artifact in artifacts) _checkArtifact(artifact, modules, allowUnstripped)];
  final ok = !passed.contains(false);
  print(ok ? 'RELEASE SYMBOLS: PASS' : 'RELEASE SYMBOLS: FAIL');
  exit(ok ? 0 : 1);
}
