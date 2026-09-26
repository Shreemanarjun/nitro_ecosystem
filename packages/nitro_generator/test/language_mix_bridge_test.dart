// Bridge fixes found by building test_projects/nitro_combo: modules that are
// C++ on some platforms and Swift/Kotlin on others, several in one plugin.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

String _src(String impls) => '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
@NitroModule($impls)
abstract class Mix extends HybridObject {
  int add(int a, int b);
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<int> get ticks;
}
''';

void main() {
  final iosCppMacSwift = SpecFromSource.parse(_src('ios: NativeImpl.cpp, android: NativeImpl.kotlin, macos: NativeImpl.swift'), sourceUri: 'package:demo/src/mix.native.dart');
  final iosSwiftAndroidCpp = SpecFromSource.parse(_src('ios: NativeImpl.swift, android: NativeImpl.cpp, macos: NativeImpl.cpp'), sourceUri: 'package:demo/src/mix.native.dart');

  test('Swift bridge: @_cdecl stubs only on the Apple platform that is Swift', () {
    final a = SwiftGenerator.generate(iosCppMacSwift);
    expect(a, contains('#if os(macOS)'));
    expect(a.substring(a.indexOf('#if os(macOS)'), a.indexOf('#else')), contains('@_cdecl("_mix_call_add")'));
    expect(a.substring(a.indexOf('#else')), isNot(contains('@_cdecl("_mix_call_add")')));
    expect(SwiftGenerator.generate(iosSwiftAndroidCpp), contains('#if os(iOS)'));
  });

  test('android: NativeImpl.cpp in a mixed spec uses direct C++, not JNI', () {
    final cpp = CppBridgeGenerator.generate(iosSwiftAndroidCpp);
    final android = cpp.substring(cpp.indexOf('#ifdef __ANDROID__\n#include'), cpp.indexOf('#elif __APPLE__'));
    expect(android, contains('mix_register_impl('));
    expect(android, isNot(contains('JNI_OnLoad')));
  });

  test('stream emit helpers are file-local (several modules may share a stream name)', () {
    final cpp = CppBridgeGenerator.generate(iosCppMacSwift);
    expect(cpp, contains('static bool _emit_ticks_to_dart('));
    expect(RegExp(r'^bool _emit_ticks_to_dart\(', multiLine: true).hasMatch(cpp), isFalse);
  });
}
