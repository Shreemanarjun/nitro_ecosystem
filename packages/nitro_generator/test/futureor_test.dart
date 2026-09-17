// `FutureOr<T>` in a spec: an inline (@nitroFast @nitroNativeAsync) method
// returns the value itself, a dispatched @nitroAsync / @nitroNativeAsync
// method returns the bridge future as is — no `async` wrapper, no extra
// microtask. `Future<T>` specs keep the async shape (a disposed call fails
// its future). Native emitters see the inner type either way.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _src = '''
import 'dart:async';
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp)
abstract class Demo extends HybridObject {
  @nitroFast
  @nitroNativeAsync
  FutureOr<int> addOr(int a, int b);
  @nitroFast
  @nitroNativeAsync
  Future<int> add(int a, int b);
  @nitroAsync
  FutureOr<String> nameOr(String prefix);
  @nitroAsync
  Future<String> name(String prefix);
  @NitroAsync(timeout: 500)
  FutureOr<int> slowOr(int ms);
  @nitroNativeAsync
  FutureOr<int> echoOr(int v);
}
''';

void main() {
  final spec = SpecFromSource.parse(_src, sourceUri: 'package:demo/src/demo.native.dart');
  // Web-targeting twin: the FFI impl moves to the split `.ffi.g.dart` library.
  final webSpec = SpecFromSource.parse(_src.replaceFirst('windows: NativeImpl.cpp)', 'windows: NativeImpl.cpp, web: WebNativeImpl.wasm)'), sourceUri: 'package:demo/src/demo.native.dart');
  fn(String n) => spec.functions.firstWhere((f) => f.dartName == n);

  test('model: FutureOr is a signature flag; the wire type is the inner type', () {
    for (final n in ['addOr', 'nameOr', 'slowOr', 'echoOr']) {
      expect(fn(n).returnsFutureOr, isTrue, reason: n);
      expect(fn(n).returnType.isFuture, isTrue, reason: n);
    }
    expect(fn('add').returnsFutureOr, isFalse);
    expect(fn('nameOr').returnType.name, 'String');
    expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
  });

  test('Dart: inline FutureOr returns the value, no async; Future keeps async', () {
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains('FutureOr<int> addOr(int a, int b) {'));
    expect(dart, contains('Future<int> add(int a, int b) async {'));
    expect(DartFfiGenerator.generateFfiLibrary(webSpec), contains("import 'dart:async';"), reason: 'the split FFI library needs FutureOr');
  });

  test('Dart: dispatched @nitroAsync FutureOr returns the bridge future as is; Future awaits it', () {
    final dart = DartFfiGenerator.generate(spec);
    final nameOr = dart.substring(dart.indexOf('FutureOr<String> nameOr(String prefix) {'));
    expect(nameOr.substring(0, nameOr.indexOf('methodName:')), contains('      return NitroRuntime.openNativeAsync<String>('));
    final name = dart.substring(dart.indexOf('Future<String> name(String prefix) async {'));
    expect(name.substring(0, name.indexOf('methodName:')), contains('      return await NitroRuntime.openNativeAsync<String>('));
    expect(dart, contains('FutureOr<int> echoOr(int v) {'));
  });

  test('Dart: the isolate-pool path stays async under FutureOr (it awaits callAsync)', () {
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains('FutureOr<int> slowOr(int ms) async {'));
    expect(dart, contains('callAsync<int>'));
  });

  test('Defaults mixin mirrors the declared FutureOr', () {
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains('FutureOr<int> addOr(int a, int b) => throw UnimplementedError'));
    expect(dart, contains('Future<int> add(int a, int b) => throw UnimplementedError'));
  });

  test('web: same signatures, inline FutureOr without async', () {
    final web = WebBridgeGenerator.generate(webSpec);
    expect(web, contains('FutureOr<int> addOr(int a, int b) {'));
    expect(web, contains('Future<int> add(int a, int b) async {'));
    expect(web, contains('FutureOr<String> nameOr(String prefix) async {'), reason: '@nitroAsync on web runs inline via callAsync');
    expect(web, contains('FutureOr<int> echoOr(int v) {'));
  });

  test('native side is unchanged: inner types only', () {
    final h = CppHeaderGenerator.generate(spec);
    expect(h, contains('NITRO_EXPORT int64_t demo_add_or(int64_t instanceId, int64_t a, int64_t b'));
    expect(h, contains('NITRO_EXPORT const char* demo_name_or(int64_t instanceId, const char* prefix);'));
    expect(KotlinGenerator.generate(spec), isNot(contains('FutureOr')));
    expect(SwiftGenerator.generate(spec), isNot(contains('FutureOr')));
  });
}
