// A type-only `.native.dart` file (shared @HybridStruct/@HybridEnum/@HybridRecord,
// no @NitroModule) is not a module — no registry, JNI bridge, SwiftPM target
// or CMake library — but its generated C header must reach every module's
// C++ include dir. Real-plugin check: nitro_type_coverage §87.
import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  bundledLibraries();
  swiftModuleWithPluginCpp();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('nitro_shared_types_');
    File(p.join(root.path, 'lib', 'src', 'shared.native.dart'))
      ..createSync(recursive: true)
      // The comment mentions the annotation on purpose: it must not count.
      ..writeAsStringSync("// Type-only file (no @NitroModule).\n@HybridStruct()\nclass Vec { final double x; Vec(this.x); }\n");
    File(p.join(root.path, 'lib', 'src', 'second.native.dart')).writeAsStringSync(
      "import 'shared.native.dart';\n@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)\nabstract class Second extends HybridObject {}\n",
    );
    File(p.join(root.path, 'lib', 'src', 'generated', 'cpp', 'shared.bridge.g.h'))
      ..createSync(recursive: true)
      ..writeAsStringSync('typedef struct Vec { double x; } Vec;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('module discovery skips the type-only file, even when a comment names the annotation', () {
    expect(moduleSpecFiles(Directory(p.join(root.path, 'lib'))).map((f) => p.basename(f.path)), ['second.native.dart']);
    expect(discoverModuleInfos('demo', baseDir: root.path).map((m) => m.module), ['Second']);
  });

  test('declaresNitroModule matches the annotation, not a mention', () {
    expect(declaresNitroModule('// no @NitroModule here'), isFalse);
    expect(declaresNitroModule('@NitroModule(ios: NativeImpl.swift)\nabstract class A {}'), isTrue);
  });

  test("the type-only file's C header is listed for every C++ include dir", () {
    expect(typeOnlyBridgeHeaders(root.path).map((f) => p.basename(f.path)), ['shared.bridge.g.h']);
  });
}

void bundledLibraries() {
  test('every desktop C++ module is listed in <plugin>_bundled_libraries, once', () {
    final root = Directory.systemTemp.createTempSync('nitro_bundled_');
    addTearDown(() => root.deleteSync(recursive: true));
    final cmake = File(p.join(root.path, 'linux', 'CMakeLists.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'cmake_minimum_required(VERSION 3.10)\n'
        'add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../src" "\${CMAKE_CURRENT_BINARY_DIR}/shared")\n'
        'set(demo_bundled_libraries\n'
        '  \$<TARGET_FILE:demo>\n'
        '  PARENT_SCOPE\n'
        ')\n',
      );
    final modules = [
      ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, linuxIsCpp: true),
      ModuleInfo(lib: 'demo_second', module: 'DemoSecond', isCpp: true, linuxIsCpp: true),
    ];
    for (var run = 0; run < 2; run++) {
      linkLinux('demo', ['demo', 'demo_second'], '/nitro/native', baseDir: root.path, moduleInfos: modules);
    }
    final text = cmake.readAsStringSync();
    expect('\$<TARGET_FILE:demo_second>'.allMatches(text), hasLength(1));
    expect(text, contains('  \$<TARGET_FILE:demo>\n  \$<TARGET_FILE:demo_second>\n  PARENT_SCOPE'));
  });
}

void swiftModuleWithPluginCpp() {
  // nitro_camera: Swift module + src/<plugin>.cpp. The Swift bridge calls
  // <plugin>_nitro_post, so the SwiftPM C++ target must carry its header.
  test('Swift module with src/<plugin>.cpp: main bridge header reaches SPM include/', () {
    final root = Directory.systemTemp.createTempSync('nitro_swift_cpp_');
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'src', 'cam.cpp'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// plugin C++');
    File(p.join(root.path, 'lib', 'src', 'generated', 'cpp', 'cam.bridge.g.h'))
      ..createSync(recursive: true)
      ..writeAsStringSync('bool cam_nitro_post(long long port, void* obj);');
    ensureIosPackageSwift('cam', baseDir: root.path, moduleInfos: [ModuleInfo(lib: 'cam', module: 'Cam', isCpp: false)]);
    expect(File(p.join(root.path, 'ios', 'cam', 'Sources', 'CamCpp', 'include', 'cam.bridge.g.h')).existsSync(), isTrue);
  });
}
