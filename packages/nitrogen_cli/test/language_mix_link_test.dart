// Link fixes found by building test_projects/nitro_combo: one plugin whose
// modules each mix Swift / Kotlin / C++ per platform (and add a platform
// later). Each test fails without its fix.
import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/templates/scaffold_templates.dart' as scaffold;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('edge cases', edgeCases);
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

void edgeCases() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('nitro_edges_'));
  tearDown(() => root.deleteSync(recursive: true));

  File write(String rel, String content) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();
  bool exists(String rel) => File(p.join(root.path, rel)).existsSync();

  const guardedStub = 'class Impl {}; // user code\n'
      '// Auto-register on shared library load — no manual init call needed.\n'
      '#if defined(__APPLE__)\n  #include <TargetConditionals.h>\n#endif\n\n'
      '#if (defined(__APPLE__) && TARGET_OS_IOS)\n'
      '#if defined(_WIN32)\nnamespace {\n  struct _AutoRegister {\n  };\n}\n#endif\n#endif // auto-register on C++ platforms\n';

  group('starters', () {
    test('no plugin dirs at all: nothing written, no throw', () {
      expect(linkNativeImplStarters(baseDir: root.path), isEmpty);
    });

    test('registered class but generate has not run (no protocol): skipped, no throw', () {
      write('ios/Classes/SwiftDemoPlugin.swift', 'ExtraRegistry.register(ExtraModuleImpl())\n');
      write('android/src/main/kotlin/com/ex/DemoPlugin.kt', 'package com.ex\nExtraJniBridge.registerFactory({ ExtraImpl() }, ctx)\n');
      expect(linkNativeImplStarters(baseDir: root.path), isEmpty);
      expect(exists('ios/Classes/ExtraModuleImpl.swift'), isFalse);
      expect(exists('android/src/main/kotlin/com/ex/ExtraImpl.kt'), isFalse);
    });

    test('class defined in a differently named file counts as existing', () {
      write('ios/Classes/SwiftDemoPlugin.swift', 'ExtraRegistry.register(ExtraModuleImpl())\n');
      write('ios/Classes/AllImpls.swift', 'public class ExtraModuleImpl: HybridExtraProtocol {}\n');
      write('lib/src/generated/swift/extra.bridge.g.swift', 'public protocol HybridExtraProtocol: AnyObject {\n    func add() -> Int64\n}\n');
      expect(linkNativeImplStarters(baseDir: root.path), isEmpty);
      expect(exists('ios/Classes/ExtraModuleImpl.swift'), isFalse);
    });

    test('a class whose name merely starts with the registered one does not count', () {
      write('ios/Classes/SwiftDemoPlugin.swift', 'ExtraRegistry.register(ExtraModuleImpl())\n');
      write('ios/Classes/Other.swift', 'public class ExtraModuleImplLegacy {}\n');
      write('lib/src/generated/swift/extra.bridge.g.swift', 'public protocol HybridExtraProtocol: AnyObject {\n    func add() -> Int64\n}\n');
      expect(linkNativeImplStarters(baseDir: root.path), {'ios'});
      expect(exists('ios/Classes/ExtraModuleImpl.swift'), isTrue);
    });

    test('empty protocol / interface: valid empty starters', () {
      write('macos/Classes/SwiftDemoPlugin.swift', 'ExtraRegistry.register(ExtraModuleImpl())\n');
      write('lib/src/generated/swift/extra.bridge.g.swift', 'public protocol HybridExtraProtocol: AnyObject {\n}\n');
      write('android/src/main/kotlin/com/ex/DemoPlugin.kt', 'package com.ex\nExtraJniBridge.registerFactory({ ExtraImpl() }, ctx)\n');
      write('lib/src/generated/kotlin/extra.bridge.g.kt', 'package nitro.extra_module\n\ninterface HybridExtraSpec {\n    fun onAttached() {}\n}\n');
      expect(linkNativeImplStarters(baseDir: root.path), {'macos'}, reason: 'macOS-only plugin');
      expect(read('macos/Classes/ExtraModuleImpl.swift'), contains('public class ExtraModuleImpl: HybridExtraProtocol {\n    public init() {}\n\n}'));
      expect(read('android/src/main/kotlin/com/ex/ExtraImpl.kt'), contains('class ExtraImpl : HybridExtraSpec {\n}'));
    });

    test('unlabeled params, nested generics and imported-type packages carry through', () {
      write('ios/Classes/SwiftDemoPlugin.swift', 'ExtraRegistry.register(ExtraModuleImpl())\n');
      write('lib/src/generated/swift/extra.bridge.g.swift', 'public protocol HybridExtraProtocol: AnyObject {\n    func put(_ key: String, value: [String: Int64]) -> Void\n}\n');
      write('android/src/main/kotlin/com/ex/DemoPlugin.kt', 'package com.ex\nExtraJniBridge.registerFactory({ ExtraImpl() }, ctx)\n');
      write('lib/src/generated/kotlin/extra.bridge.g.kt',
          'package nitro.extra_module\n\nimport nitro.shared_module.*\n\ninterface HybridExtraSpec {\n    fun put(key: String, value: Map<String, List<Long>>): Unit\n}\n');
      linkNativeImplStarters(baseDir: root.path);
      expect(read('ios/Classes/ExtraModuleImpl.swift'), contains('public func put(_ key: String, value: [String: Int64]) -> Void { fatalError('));
      final kt = read('android/src/main/kotlin/com/ex/ExtraImpl.kt');
      expect(kt, contains('override fun put(key: String, value: Map<String, List<Long>>): Unit = TODO('));
      expect(kt, contains('import nitro.shared_module.*'));
    });
  });

  group('auto-register guard refresh', () {
    test('already-correct guard: file byte-identical', () {
      const ok = 'x\n#if (defined(__linux__) && !defined(__ANDROID__))\n#if defined(_WIN32)\nnamespace {\n  struct _AutoRegister {\n  };\n}\n#endif\n#endif\n';
      write('src/HybridDemoMix.cpp', ok);
      linkCppImplStubs([ModuleInfo(lib: 'demo_mix', module: 'DemoMix', isCpp: true, isNativeCpp: true, linuxIsCpp: true)], baseDir: root.path);
      expect(read('src/HybridDemoMix.cpp'), ok);
    });

    test('user removed the auto-register block: file untouched', () {
      const custom = 'class Impl {};\nvoid init() { demo_mix_register_impl(nullptr); }\n';
      write('src/HybridDemoMix.cpp', custom);
      linkCppImplStubs([ModuleInfo(lib: 'demo_mix', module: 'DemoMix', isCpp: true, isNativeCpp: true, linuxIsCpp: true)], baseDir: root.path);
      expect(read('src/HybridDemoMix.cpp'), custom);
    });

    test('module C++ everywhere: guard becomes unconditional', () {
      write('src/HybridDemoMix.cpp', guardedStub);
      linkCppImplStubs([ModuleInfo(lib: 'demo_mix', module: 'DemoMix', isCpp: true, isNativeCpp: true, isAndroidCpp: true, iosIsCpp: true, macosIsCpp: true, windowsIsCpp: true)], baseDir: root.path);
      expect(read('src/HybridDemoMix.cpp'), contains('#if 1\n#if defined(_WIN32)'));
    });

    test('new guard needs TARGET_OS_* but the stub lacks TargetConditionals.h: include added', () {
      write('src/HybridDemoMix.cpp', 'class Impl {};\n#if (defined(__linux__) && !defined(__ANDROID__))\n#if defined(_WIN32)\nnamespace {\n  struct _AutoRegister {\n  };\n}\n#endif\n#endif\n');
      linkCppImplStubs([ModuleInfo(lib: 'demo_mix', module: 'DemoMix', isCpp: true, isNativeCpp: true, linuxIsCpp: true, macosIsCpp: true)], baseDir: root.path);
      final out = read('src/HybridDemoMix.cpp');
      expect(out, contains('#include <TargetConditionals.h>'));
      expect(out.indexOf('TargetConditionals.h'), lessThan(out.indexOf('TARGET_OS_OSX')));
    });
  });

  group('C++ stub seeding', () {
    test('no generated starter yet: falls back to the template stub', () {
      linkCppImplStubs([ModuleInfo(lib: 'extra', module: 'Extra', isCpp: true, isNativeCpp: true, linuxIsCpp: true)], baseDir: root.path);
      expect(read('src/HybridExtra.cpp'), contains('class HybridExtraImpl final : public HybridExtra {'));
    });

    test('an existing stub is never replaced by the generated starter', () {
      write('src/HybridExtra.cpp', 'class Mine {};\n');
      write('lib/src/generated/cpp/extra.impl.g.cpp', 'class ExtraImpl final : public HybridExtra {\npublic:\n};\n');
      linkCppImplStubs([ModuleInfo(lib: 'extra', module: 'Extra', isCpp: true, isNativeCpp: true, linuxIsCpp: true)], baseDir: root.path);
      expect(read('src/HybridExtra.cpp'), 'class Mine {};\n');
    });
  });

  group('CMake target retrofit', () {
    String cmakeWith(String target) => 'set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/native")\nadd_library(demo SHARED\n  "dart_api_dl.c"\n)\n$target';
    const kt = '\nadd_library(demo_kt SHARED\n  "dart_api_dl.c"\n)\nset_target_properties(demo_kt PROPERTIES OUTPUT_NAME "demo_kt")\n';

    test('module still Kotlin/Swift everywhere: no impl source added', () {
      write('src/CMakeLists.txt', cmakeWith(kt));
      linkCMake('demo', ['demo', 'demo_kt'], '/n', baseDir: root.path, moduleInfos: [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: false), ModuleInfo(lib: 'demo_kt', module: 'DemoKt', isCpp: false)]);
      expect(read('src/CMakeLists.txt'), isNot(contains('HybridDemoKt.cpp')));
    });

    test('Android C++ target: impl source unguarded (compiled on Android too)', () {
      write('src/CMakeLists.txt', cmakeWith(kt));
      linkCMake('demo', ['demo', 'demo_kt'], '/n', baseDir: root.path, moduleInfos: [
        ModuleInfo(lib: 'demo', module: 'Demo', isCpp: false),
        ModuleInfo(lib: 'demo_kt', module: 'DemoKt', isCpp: true, isNativeCpp: true, isAndroidCpp: true),
      ]);
      final target = read('src/CMakeLists.txt').split('add_library(demo_kt').last;
      expect(target, contains('HybridDemoKt.cpp'));
      expect(target, isNot(contains('if(NOT ANDROID)')));
    });

    test('a target already carrying NITRO_IMPL_SRC is left alone', () {
      const done = '\nadd_library(demo_kt SHARED\n  "dart_api_dl.c"\n)\nif(DEFINED NITRO_IMPL_SRC_demo_kt)\n  target_sources(demo_kt PRIVATE "\${NITRO_IMPL_SRC_demo_kt}")\nendif()\n';
      write('src/CMakeLists.txt', cmakeWith(done));
      linkCMake('demo', ['demo', 'demo_kt'], '/n', baseDir: root.path, moduleInfos: [
        ModuleInfo(lib: 'demo', module: 'Demo', isCpp: false),
        ModuleInfo(lib: 'demo_kt', module: 'DemoKt', isCpp: true, isNativeCpp: true, linuxIsCpp: true),
      ]);
      expect('NITRO_IMPL_SRC_demo_kt}'.allMatches(read('src/CMakeLists.txt')), hasLength(1));
    });
  });
}
