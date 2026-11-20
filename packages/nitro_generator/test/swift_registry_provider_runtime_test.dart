// Compiles the generated Swift bridge with swiftc and runs it: the registry
// must find its implementation by itself when nothing registered one (a host
// that never calls the plugin's `register(with:)`, such as DartNative), and
// must not crash when there is none.
//
// A text test cannot see this. The first version of the lookup walked every
// class in the process and crashed in `swift_dynamicCast` → `___forwarding___`
// on a class that cannot be messaged (`__NSGenericDeallocHandler`); it only
// showed when the code ran.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  final hasSwiftc = Process.runSync('which', ['swiftc']).exitCode == 0;

  group('generated Swift registry at run time', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('nitro_swift_registry_');
      File('${tmp.path}/bridge.swift').writeAsStringSync(SwiftGenerator.generate(simpleSpec()));
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    /// Builds the bridge with [mainSwift] as the program and runs it.
    ProcessResult run(String name, String mainSwift) {
      final dir = Directory('${tmp.path}/$name')..createSync();
      File('${dir.path}/main.swift').writeAsStringSync(mainSwift);
      final build = Process.runSync('swiftc', ['${tmp.path}/bridge.swift', '${dir.path}/main.swift', '-o', '${dir.path}/probe']);
      expect(build.exitCode, 0, reason: '${build.stderr}');
      return Process.runSync('${dir.path}/probe', const []);
    }

    // `_my_camera_module_call_add` is the stub the C bridge calls.
    test('a provider class in the image is asked once and registers the implementation', () {
      final result = run('provider', r'''
import Foundation

final class Impl: HybridMyCameraProtocol {
    func add(a: Double, b: Double) -> Double { a + b }
    func getGreeting(name: String) async throws -> String { "hi \(name)" }
}

final class Plugin: NSObject, MyCameraImplementationProvider {
    static var asked = 0
    static func registerMyCameraImplementation() {
        asked += 1
        MyCameraRegistry.register(Impl())
    }
}

print("first=\(_my_camera_module_call_add(2, 3)) second=\(_my_camera_module_call_add(4, 5)) asked=\(Plugin.asked)")
''');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'first=5.0 second=9.0 asked=1\n');
    });

    test('with no provider the lookup ends without a crash, says so once and calls return defaults', () {
      final result = run('none', r'''
import Foundation

print("first=\(_my_camera_module_call_add(2, 3)) second=\(_my_camera_module_call_add(4, 5)) empty=\(MyCameraRegistry.impl == nil)")
''');
      expect(result.exitCode, 0, reason: 'the lookup must not crash: ${result.stderr}');
      expect(result.stdout, 'first=0.0 second=0.0 empty=true\n');
      expect('no implementation is registered'.allMatches(result.stderr as String), hasLength(1));
    });

    test('an implementation registered up front is used and no provider is asked', () {
      final result = run('registered', r'''
import Foundation

final class Impl: HybridMyCameraProtocol {
    func add(a: Double, b: Double) -> Double { a * b }
    func getGreeting(name: String) async throws -> String { name }
}

final class Plugin: NSObject, MyCameraImplementationProvider {
    static var asked = 0
    static func registerMyCameraImplementation() { asked += 1 }
}

MyCameraRegistry.register(Impl())
print("value=\(_my_camera_module_call_add(2, 3)) asked=\(Plugin.asked)")
''');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'value=6.0 asked=0\n');
    });
  }, skip: hasSwiftc ? false : 'swiftc not on PATH');
}
