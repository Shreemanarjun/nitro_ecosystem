// Shared-port completion batching: what each backend must emit so that a
// @nitroNativeAsync completion travels through <lib>_nitro_post.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _spec = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Demo extends HybridObject {
  int add(int a, int b);
  @nitroNativeAsync
  Future<int> fetch(int id);
  @nitroNativeAsync
  Future<String> name(int id);
}
''';

void main() {
  final spec = SpecFromSource.parse(_spec, sourceUri: 'package:demo/src/demo.native.dart');
  final cppOnly = SpecFromSource.parse(_spec.replaceFirst('ios: NativeImpl.swift, android: NativeImpl.kotlin', 'ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp'), sourceUri: 'package:demo/src/demo.native.dart');

  test('Dart: bind/ack bindings are leaf, one NitroCompletionBatch per instance, every native-async call passes it', () {
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains("_dylib.lookupFunction<Int64 Function(Int64), int Function(int)>('demo_nitro_bind', isLeaf: true)"));
    expect(dart, contains("_dylib.lookupFunction<Void Function(Int64), void Function(int)>('demo_nitro_ack', isLeaf: true)"));
    expect(dart, contains('late final NitroCompletionBatch _nitroBatch = NitroCompletionBatch(bind: _nitroBindPtr, ack: _nitroAckPtr);'));
    expect(RegExp(r'batch: _nitroBatch,').allMatches(dart).length, 2);
  });

  test('Dart: a spec without native-async methods carries no batch', () {
    final dart = DartFfiGenerator.generate(SpecFromSource.parse(_spec.replaceAll('@nitroNativeAsync\n  ', '').replaceAll('Future<int> fetch', 'int fetch').replaceAll('Future<String> name', 'String name'), sourceUri: 'package:demo/src/demo.native.dart'));
    expect(dart, isNot(contains('NitroCompletionBatch')));
  });

  test('C header: the three exports and the macro that redirects every post site (not on web)', () {
    final h = CppHeaderGenerator.generate(spec);
    expect(h, contains('NITRO_EXPORT bool demo_nitro_post(int64_t port, struct _Dart_CObject* obj);'));
    expect(h, contains('NITRO_EXPORT int64_t demo_nitro_bind(int64_t batchPort);'));
    expect(h, contains('NITRO_EXPORT void demo_nitro_ack(int64_t batchPort);'));
    expect(h, contains('#define Dart_PostCObject_DL(port, obj) demo_nitro_post((port), (obj))'));
    expect(h.indexOf('#ifndef __EMSCRIPTEN__'), lessThan(h.indexOf('demo_nitro_post')));
  });

  test('C++ bridges (JNI/Swift and direct) own one batcher and define the exports', () {
    for (final cpp in [CppBridgeGenerator.generate(spec), CppBridgeGenerator.generate(cppOnly)]) {
      expect(cpp, contains('#include "nitro_completion_batch.h"'));
      expect(cpp, contains('static NitroCompletionBatch g_nitro_batch_demo;'));
      expect(cpp, contains('NITRO_EXPORT bool demo_nitro_post(int64_t port, struct _Dart_CObject* obj) { return g_nitro_batch_demo.post(port, obj); }'));
      expect(cpp, contains('NITRO_EXPORT int64_t demo_nitro_bind(int64_t batchPort) { return g_nitro_batch_demo.bind(batchPort); }'));
      expect(cpp, contains('NITRO_EXPORT void demo_nitro_ack(int64_t batchPort) { g_nitro_batch_demo.ack(batchPort); }'));
    }
  });

  test('Swift: completions post through the exported function, never the raw DL pointer', () {
    final sw = SwiftGenerator.generate(spec);
    expect(sw, contains('_ = demo_nitro_post(dartPort, &'));
    expect(sw, isNot(contains('Dart_PostCObject_DL(')));
  });
}
