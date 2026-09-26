// Link fixes found by building test_projects/nitro_combo: one plugin whose
// modules each mix Swift / Kotlin / C++ per platform (and add a platform
// later). Each test fails without its fix.
import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/templates/scaffold_templates.dart' as scaffold;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('starters', starters);
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('nitro_mix_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('scaffolded Android plugin only calls methods the JniBridge has', () {
    final kt = scaffold.androidPluginKtTemplate('com.example', 'demo', 'Demo', 'Demo');
    expect(kt, isNot(contains('JniBridge.onDetached(')));
  });

  test('a module target made before its module became Linux C++ gains the impl source', () {
    File(p.join(root.path, 'src', 'CMakeLists.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/native")\n'
        'add_library(demo SHARED\n  "dart_api_dl.c"\n)\n'
        '\nadd_library(demo_kt SHARED\n  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/demo_kt.bridge.g.cpp"\n  "dart_api_dl.c"\n)\n'
        'set_target_properties(demo_kt PROPERTIES OUTPUT_NAME "demo_kt")\n',
      );
    final infos = [
      ModuleInfo(lib: 'demo', module: 'Demo', isCpp: false),
      ModuleInfo(lib: 'demo_kt', module: 'DemoKt', isCpp: true, isNativeCpp: true, linuxIsCpp: true),
    ];
    for (var run = 0; run < 2; run++) {
      linkCMake('demo', ['demo', 'demo_kt'], '/nitro/native', baseDir: root.path, moduleInfos: infos);
    }
    final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
    expect('target_sources(demo_kt PRIVATE "HybridDemoKt.cpp")'.allMatches(cmake), hasLength(1));
    expect(cmake, contains('if(NOT ANDROID)'), reason: 'Android stays Kotlin');
  });

  test("an existing stub's auto-register guard follows platforms added later", () {
    final stub = File(p.join(root.path, 'src', 'HybridDemoMix.cpp'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'class Impl {}; // user code\n'
        '// Auto-register on shared library load — no manual init call needed.\n'
        '#if defined(__APPLE__)\n  #include <TargetConditionals.h>\n#endif\n\n'
        '#if (defined(__APPLE__) && TARGET_OS_IOS)\n'
        '#if defined(_WIN32)\nnamespace {\n  struct _AutoRegister {\n  };\n}\n#endif\n#endif // auto-register on C++ platforms\n',
      );
    linkCppImplStubs([ModuleInfo(lib: 'demo_mix', module: 'DemoMix', isCpp: true, isNativeCpp: true, iosIsCpp: true, linuxIsCpp: true)], baseDir: root.path);
    final out = stub.readAsStringSync();
    expect(out, contains('#if (defined(__linux__) && !defined(__ANDROID__)) || (defined(__APPLE__) && TARGET_OS_IOS)\n#if defined(_WIN32)'));
    expect(out, startsWith('class Impl {}; // user code'));
  });
}

void starters() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('nitro_starters_'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String rel, String content) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  test('registered Swift/Kotlin impls that do not exist get compiling starters; existing ones are untouched', () {
    write('ios/Classes/SwiftDemoPlugin.swift', 'DemoRegistry.register(DemoImpl())\nExtraRegistry.register(ExtraModuleImpl())\n');
    write('ios/Classes/DemoImpl.swift', 'public class DemoImpl: HybridDemoProtocol {}\n');
    write('lib/src/generated/swift/extra.bridge.g.swift',
        'public protocol HybridExtraProtocol: AnyObject {\n    // source: x\n    func add(a: Int64, b: Int64) -> Int64\n    func later() async throws -> String\n    var level: Int64 { get set }\n    var label: String { get async throws }\n    var ticks: AnyPublisher<Int64, Never> { get }\n}\n');
    write('android/src/main/kotlin/com/ex/demo/DemoPlugin.kt', 'package com.ex.demo\nExtraJniBridge.registerFactory({ ExtraImpl() }, ctx)\n');
    write('lib/src/generated/kotlin/extra.bridge.g.kt',
        'package nitro.extra_module\n\nimport kotlinx.coroutines.flow.Flow\n\ninterface HybridExtraSpec {\n    fun onAttached() {}\n    fun add(a: Long, b: Long): Long\n    suspend fun later(): String\n    var level: Long\n    val ticks: Flow<Long>\n}\n');

    expect(linkNativeImplStarters(baseDir: root.path), {'ios'});
    final swift = File(p.join(root.path, 'ios/Classes/ExtraModuleImpl.swift')).readAsStringSync();
    expect(swift, contains('public class ExtraModuleImpl: HybridExtraProtocol {'));
    expect(swift, contains('public func add(a: Int64, b: Int64) -> Int64 { fatalError('));
    expect(swift, contains('public func later() async throws -> String { fatalError('));
    expect(swift, contains('public var level: Int64 {\n        get { fatalError('));
    expect(swift, contains('public var label: String { get async throws { fatalError('));
    expect(swift, contains('public var ticks: AnyPublisher<Int64, Never> { fatalError('));
    expect(File(p.join(root.path, 'ios/Classes/DemoImpl.swift')).readAsStringSync(), 'public class DemoImpl: HybridDemoProtocol {}\n');

    final kt = File(p.join(root.path, 'android/src/main/kotlin/com/ex/demo/ExtraImpl.kt')).readAsStringSync();
    expect(kt, contains('package com.ex.demo'));
    expect(kt, contains('import nitro.extra_module.*'));
    expect(kt, contains('override fun add(a: Long, b: Long): Long = TODO('));
    expect(kt, contains('override suspend fun later(): String = TODO('));
    expect(kt, contains('override var level: Long\n        get() = TODO('));
    expect(kt, contains('override val ticks: Flow<Long> get() = TODO('));
    expect(kt, isNot(contains('onAttached')));

    expect(linkNativeImplStarters(baseDir: root.path), isEmpty, reason: 'second run writes nothing');
  });

  test('a new C++ stub takes the generated starter class (compiles: every override present)', () {
    write('lib/src/generated/cpp/extra.impl.g.cpp',
        '#include "extra.native.g.h"\n\nclass ExtraImpl final : public HybridExtra {\npublic:\n    ExtraImpl() = default;\n    int64_t add(int64_t a, int64_t b) override {\n        throw std::runtime_error("Not implemented: add");\n    }\n};\n');
    linkCppImplStubs([ModuleInfo(lib: 'extra', module: 'Extra', isCpp: true, isNativeCpp: true, linuxIsCpp: true)], baseDir: root.path);
    final stub = File(p.join(root.path, 'src/HybridExtra.cpp')).readAsStringSync();
    expect(stub, contains('class HybridExtraImpl final : public HybridExtra {'));
    expect(stub, contains('HybridExtraImpl() = default;'));
    expect(stub, contains('int64_t add(int64_t a, int64_t b) override'));
    expect(stub, contains('#include <stdexcept>'));
    expect(stub, contains('static HybridExtraImpl g_impl;'));
  });

  test("init's desktop sample impl implements the sample methods", () {
    expect(scaffold.cppSampleImplClass('Demo'), allOf(contains('double add(double a, double b) override'), contains('std::string getGreeting(')));
  });
}
