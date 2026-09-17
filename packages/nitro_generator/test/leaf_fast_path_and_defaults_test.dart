// Issues #51 (bare leaf body for `...Fast` methods), #52 (NativeHandle
// parameters are leaf-eligible) and #53 (`<Class>Defaults` mixin).
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _source = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Demo extends HybridObject {
  /// Hot path: no error check, no callSync closure.
  void resetFast(NativeHandle<Void> writer);
  double addFast(double a, double b);
  /// Annotation form of the same contract (no suffix).
  @nitroFast
  int hot(int a, int b);
  /// @nitroFast + @nitroNativeAsync: Future signature, sync bridge call.
  @nitroFast
  @nitroNativeAsync
  Future<int> hotAsync(int a, int b);
  /// Fast, but a String parameter needs an arena — keeps the callSync path.
  int lengthFast(String s);
  /// Plain method taking a handle: leaf-eligible now (#52).
  int write(NativeHandle<Void> writer, int byte);
  /// Returning an owned handle allocates a wrapper + finalizer: never leaf.
  @NitroOwned()
  NativeHandle<Void> open(String path);
  double add(double a, double b);
  Future<int> slowAdd(int a, int b);
  @nitroNativeAsync
  Future<String> fetch(String url);
  int get counter;
  set counter(int value);
  String get name;
  Stream<int> get ticks;
  Stream<String> get logs;
}
''';

void main() {
  late String out;
  setUpAll(() {
    out = DartFfiGenerator.generate(SpecFromSource.parse(_source, sourceUri: 'package:demo/src/demo.native.dart'));
  });

  group('#51 bare leaf body for Fast methods', () {
    test('void Fast method: checkDisposed + direct call, no callSync, no error check', () {
      expect(out, contains('  void resetFast(NativeHandle<Void> writer) {\n    checkDisposed();\n    _resetFastPtr(_instanceId, writer'));
      final body = out.substring(out.indexOf('void resetFast('), out.indexOf('double addFast('));
      expect(body, isNot(contains('callSync')));
      expect(body, isNot(contains('_assertCheckError')));
      expect(body, isNot(contains('checkError')));
    });

    test('returning Fast method: direct call and plain return, no closure', () {
      final body = out.substring(out.indexOf('double addFast('), out.indexOf('int hot('));
      expect(body, contains('final res = _addFastPtr(_instanceId, a, b, _nitroErr);'));
      expect(body, contains('return res;'));
      expect(body, isNot(contains('callSync')));
    });

    test('Fast method that needs an arena keeps the instrumented withArena path', () {
      final body = out.substring(out.indexOf('int lengthFast('), out.indexOf('int write('));
      expect(body, contains("NitroRuntime.syncStart('lengthFast')"));
      expect(body, contains('withArena'));
      expect(body, isNot(contains('checkError')), reason: 'Fast still skips the error check');
    });

    test('@nitroFast without the suffix gets the same bare body and leaf binding', () {
      final body = out.substring(out.indexOf('int hot(int a, int b)'), out.indexOf('int lengthFast('));
      expect(body, contains('final res = _hotPtr(_instanceId, a, b, _nitroErr);'));
      expect(body, isNot(contains('callSync')));
      final i = out.indexOf("'demo_hot'");
      expect(out.substring(out.lastIndexOf('late final', i), out.indexOf(';', i)), contains('isLeaf: true'));
    });

    test('@nitroFast + @nitroNativeAsync: Future signature, inline sync body, every backend sees a sync method', () {
      final spec = SpecFromSource.parse(_source, sourceUri: 'package:demo/src/demo.native.dart');
      final f = spec.functions.firstWhere((x) => x.dartName == 'hotAsync');
      expect(f.inlineFuture, isTrue);
      expect(f.isNativeAsync, isFalse);
      expect(f.returnType.name, 'int');
      final body = out.substring(out.indexOf('Future<int> hotAsync(int a, int b) async {'), out.indexOf('int lengthFast('));
      expect(body, contains('final res = _hotAsyncPtr(_instanceId, a, b, _nitroErr);'));
      expect(body, isNot(contains('openNativeAsync')));
      expect(body, isNot(contains('ReceivePort')));
      final i = out.indexOf("'demo_hot_async'");
      expect(out.substring(out.lastIndexOf('late final', i), out.indexOf(';', i)), contains('isLeaf: true'));
      expect(SpecValidator.validate(spec).map((x) => x.code), isNot(contains('FAST_NOT_SYNC')));
      // Defaults mixin keeps the Future shape.
      expect(out.replaceAll(RegExp(r'\s+'), ' '), contains("Future<int> hotAsync(int a, int b) => throw UnimplementedError('Demo.hotAsync');"));
      // Native sides: plain sync signatures, no coroutine / async / port.
      final kt = KotlinGenerator.generate(spec);
      expect(kt, contains('fun hotAsync(a: Long, b: Long): Long'));
      expect(kt, isNot(contains('suspend fun hotAsync')));
      final sw = SwiftGenerator.generate(spec);
      expect(sw, contains('func hotAsync(a: Int64, b: Int64)'));
      expect(sw, isNot(contains('func hotAsync(a: Int64, b: Int64) async')));
      final cppOnly = _source.replaceFirst('ios: NativeImpl.swift, android: NativeImpl.kotlin', 'ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp');
      final cppSpec = SpecFromSource.parse(cppOnly, sourceUri: 'package:demo/src/demo.native.dart');
      expect(CppHeaderGenerator.generate(cppSpec), contains('NITRO_EXPORT int64_t demo_hot_async(int64_t instanceId, int64_t a, int64_t b, NitroError* _nitro_err);'));
      expect(CppBridgeGenerator.generate(cppSpec), isNot(contains('demo_hot_async(int64_t instanceId, int64_t a, int64_t b, NitroError* _nitro_err, int64_t dart_port)')));
      final web = WebBridgeGenerator.generate(SpecFromSource.parse(_source.replaceFirst('android: NativeImpl.kotlin', 'android: NativeImpl.kotlin, web: NativeImpl.wasm'), sourceUri: 'package:demo/src/demo.native.dart'));
      expect(web, contains('Future<int> hotAsync(int a, int b) async {'));
    });

    test('validator: @nitroFast on an async method is FAST_NOT_SYNC', () {
      final bad = _source.replaceFirst('Future<int> slowAdd(int a, int b);', '@nitroFast\n  Future<int> slowAdd(int a, int b);');
      final codes = SpecValidator.validate(SpecFromSource.parse(bad, sourceUri: 'package:demo/src/demo.native.dart')).map((i) => i.code).toList();
      expect(codes, contains('FAST_NOT_SYNC'));
      final okCodes = SpecValidator.validate(SpecFromSource.parse(_source, sourceUri: 'package:demo/src/demo.native.dart')).map((i) => i.code).toList();
      expect(okCodes, isNot(contains('FAST_NOT_SYNC')));
    });

    test('non-Fast methods: inline body between syncStart/syncEnd, error check names the method, no closure', () {
      final body = out.substring(out.indexOf('double add(double a, double b)'), out.indexOf('Future<int> slowAdd('));
      expect(body, contains("final t0 = NitroRuntime.syncStart('add');"));
      expect(body, contains("NitroRuntime.throwIfOutParamError(_nitroErr, nativeFree: _nitroFree, methodName: 'add');"));
      expect(body, contains("NitroRuntime.syncEnd(t0, 'add');"));
      expect(body, isNot(contains('callSync')));
    });
  });

  group('#52 NativeHandle parameters are leaf-eligible', () {
    // The whole binding statement for a symbol (it spans lines after dart_style).
    String binding(String symbol) {
      final i = out.indexOf("'$symbol'");
      return out.substring(out.lastIndexOf('late final', i), out.indexOf(';', i));
    }

    test('a plain method taking a handle binds isLeaf: true', () {
      expect(binding('demo_write'), contains('isLeaf: true'));
    });

    test('a method returning an owned handle stays non-leaf', () {
      expect(binding('demo_open'), isNot(contains('isLeaf: true')));
    });

    test('Fast handle method is leaf by contract', () {
      expect(binding('demo_reset_fast'), contains('isLeaf: true'));
    });

    test('the FFI argument is the wrapped pointer, not the handle object', () {
      expect(out, contains('_writePtr(_instanceId, writer.pointer, byte, _nitroErr)'));
      expect(out, contains('_resetFastPtr(_instanceId, writer.pointer, _nitroErr)'));
    });
  });

  group('web bridge with handle parameters', () {
    test('handle-parameter overrides carry the scoped invalid_override ignore', () {
      final web = WebBridgeGenerator.generate(SpecFromSource.parse(_source.replaceFirst('android: NativeImpl.kotlin', 'android: NativeImpl.kotlin, web: NativeImpl.wasm'), sourceUri: 'package:demo/src/demo.native.dart'));
      final i = web.indexOf('int write(NativeHandle<Void> writer, int byte)');
      expect(i, greaterThan(-1));
      expect(web.substring(web.lastIndexOf('@override', i), i), contains('// ignore: invalid_override'));
      expect(web, contains('((writer as dynamic).address as int).toJS'));
    });
  });

  group('#53 <Class>Defaults mixin', () {
    late String mixin;
    setUpAll(() {
      final start = out.indexOf('mixin DemoDefaults on Demo {');
      expect(start, greaterThan(-1), reason: 'mixin emitted');
      // dart_style may wrap `=> throw ...` onto the next line: compare on one line.
      mixin = out.substring(start, out.indexOf('\n}\n', start) + 3).replaceAll(RegExp(r'\s+'), ' ');
    });

    test('every function, with its exact spec return type', () {
      expect(mixin, contains("void resetFast(NativeHandle<Void> writer) => throw UnimplementedError('Demo.resetFast');"));
      expect(mixin, contains("double add(double a, double b) => throw UnimplementedError('Demo.add');"));
      expect(mixin, contains("Future<int> slowAdd(int a, int b) => throw UnimplementedError('Demo.slowAdd');"));
      expect(mixin, contains("Future<String> fetch(String url) => throw UnimplementedError('Demo.fetch');"));
      expect(mixin, contains("NativeHandle<Void> open(String path) => throw UnimplementedError('Demo.open');"));
    });

    test('properties: getter and setter, getter-only', () {
      expect(mixin, contains("int get counter => throw UnimplementedError('Demo.counter');"));
      expect(mixin, contains("set counter(int value) => throw UnimplementedError('Demo.counter');"));
      expect(mixin, contains("String get name => throw UnimplementedError('Demo.name');"));
      expect(mixin, isNot(contains('set name(')));
    });

    // The test-only SpecFromSource parser sees streams as getters; the
    // method-style form (`Stream<T> name()`) is covered end-to-end by the
    // nitro_type_coverage fake test, whose spec goes through the real extractor.
    test('streams', () {
      expect(mixin, contains("Stream<int> get ticks => throw UnimplementedError('Demo.ticks');"));
      expect(mixin, contains("Stream<String> get logs => throw UnimplementedError('Demo.logs');"));
    });

    test('every member is an @override so a missing spec member is a compile error, not a silent extra', () {
      expect(RegExp(r'@override').allMatches(mixin).length, 15);
    });
  });

  group('direct C++ bridge (C++-only spec)', () {
    test('emits the @NitroOwned release export the Dart finalizer looks up', () {
      // The test parser defaults ios/android to Swift/Kotlin when omitted, so
      // every platform is spelled out as C++ to reach the direct bridge.
      final cppOnly = _source.replaceFirst('ios: NativeImpl.swift, android: NativeImpl.kotlin', 'ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp');
      final bridge = CppBridgeGenerator.generate(SpecFromSource.parse(cppOnly, sourceUri: 'package:demo/src/demo.native.dart'));
      expect(bridge, contains('NITRO_EXPORT void demo_open_release(void* handle) {'));
      expect(bridge, contains('if (handle) { free(handle); }'));
    });
  });
}
