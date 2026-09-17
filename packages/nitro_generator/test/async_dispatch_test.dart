// @nitroAsync on C++-only specs: bridge-side dispatch instead of the Dart
// isolate pool. The sync export stays; a `<sym>_dispatch` twin runs it on
// the worker pool and posts through the completion batcher.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _cpp = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@HybridRecord()
class Job { final String id; final int n; const Job({required this.id, required this.n}); }
@HybridStruct()
class Pt { final double x; final double y; Pt({required this.x, required this.y}); }
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp)
abstract class Demo extends HybridObject {
  @nitroAsync
  Future<int> echo(int v, String label, Uint8List bytes, Pt at, Job job, int? maybe);
  @nitroAsync
  Future<String> name(int id);
  @nitroAsync
  Future<Job> load(int id);
  @nitroAsync
  Future<void> ping();
  @nitroAsync
  Future<Uint8List> raw(int n);
  @NitroAsync(timeout: 500)
  Future<int> slow(int ms);
  @nitroAsync
  Future<Pt> where(int id);
  @nitroAsync
  Future<int?> maybe(int id);
}
''';

void main() {
  final spec = SpecFromSource.parse(_cpp, sourceUri: 'package:demo/src/demo.native.dart');
  final mixed = SpecFromSource.parse(_cpp.replaceFirst('ios: NativeImpl.cpp, android: NativeImpl.cpp,', 'ios: NativeImpl.swift, android: NativeImpl.kotlin,'), sourceUri: 'package:demo/src/demo.native.dart');

  test('eligibility: plain kinds dispatch on every backend; typed-data, struct and nullable-prim returns and per-method timeouts stay on the pool', () {
    const want = {'echo': true, 'name': true, 'load': true, 'ping': true, 'raw': false, 'slow': false, 'where': false, 'maybe': false};
    expect({for (final f in spec.functions) f.dartName: spec.dispatchesAsync(f)}, want);
    expect({for (final f in mixed.functions) f.dartName: mixed.dispatchesAsync(f)}, want, reason: 'Kotlin/Swift specs dispatch too');
    expect(spec.nativeSymbol(spec.functions.first), 'demo_echo_dispatch');
    expect(spec.nativeSymbol(spec.functions.firstWhere((f) => f.dartName == 'raw')), 'demo_raw');
  });

  test('C++: on a mixed spec every twin sits inside the platform section that defines its sync export', () {
    // nitro_ar-style module (Swift + Kotlin only): on Windows/Linux no section
    // compiles, so a twin outside the #ifdef chain would be an unresolved
    // external in the DLL link.
    final swiftKotlin = SpecFromSource.parse(
      _cpp.replaceFirst('ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp', 'ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift'),
      sourceUri: 'package:demo/src/demo.native.dart',
    );
    final cpp = CppBridgeGenerator.generate(swiftKotlin);
    final lastEndif = cpp.lastIndexOf('\n#endif');
    final lastTwin = cpp.lastIndexOf('_dispatch(int64_t instanceId');
    expect(lastTwin, greaterThan(0));
    expect(lastTwin, lessThan(lastEndif), reason: 'twins must be emitted inside the JNI / Apple sections, not after the chain');
    expect('demo_echo_dispatch(int64_t instanceId'.allMatches(cpp).length, 2, reason: 'one per platform section (JNI + Apple)');
  });

  test('Dart: dispatched methods bind <sym>_dispatch with the native-async signature and complete through the batch', () {
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains("('demo_echo_dispatch')"));
    expect(dart, contains("('demo_raw')"), reason: 'pool function keeps the sync symbol');
    final echo = dart.substring(dart.indexOf('Future<int> echo('), dart.indexOf('Future<String> name('));
    expect(echo, contains('NitroRuntime.openNativeAsync<int>('));
    expect(echo, contains('batch: _nitroBatch,'));
    expect(echo, contains('_nitroErr, port)'), reason: 'error slot then port, like native-async');
    expect(echo, isNot(contains('callAsync')));
    final raw = dart.substring(dart.indexOf('Future<Uint8List> raw('), dart.indexOf('Future<int> slow('));
    expect(raw, contains('NitroRuntime.callAsync'));
  });

  test('C header: the dispatch twin is declared next to the sync export', () {
    final h = CppHeaderGenerator.generate(spec);
    expect(h, contains('NITRO_EXPORT int64_t demo_echo(int64_t instanceId, int64_t v, const char* label, uint8_t* bytes, size_t bytes_length, void* at, void* job, const uint8_t* maybe);'));
    expect(h, contains('NITRO_EXPORT void demo_echo_dispatch(int64_t instanceId, int64_t v, const char* label, uint8_t* bytes, size_t bytes_length, void* at, void* job, const uint8_t* maybe, NitroError* _nitro_err, int64_t dart_port);'));
    expect(h, isNot(contains('demo_raw_dispatch')));
  });

  test('C++: the twin copies every pointer argument, runs the sync export on the pool, forwards the TLS error, posts by kind', () {
    final cpp = CppBridgeGenerator.generate(spec);
    expect(cpp, contains('#include "nitro_worker_pool.h"'));
    expect(cpp, contains('static NitroWorkerPool g_nitro_pool_demo;'));
    final twin = cpp.substring(cpp.indexOf('NITRO_EXPORT void demo_echo_dispatch('), cpp.indexOf('NITRO_EXPORT void demo_name_dispatch('));
    expect(twin, contains('std::string _c_label(label ? label : ""); const bool _n_label = label == nullptr;'));
    expect(twin, contains('std::vector<uint8_t> _c_bytes = _nitro_copy_bytes(bytes, (size_t)bytes_length * sizeof(*bytes));'));
    expect(twin, contains('*_c_at = _nitro_clone_Pt(*static_cast<const Pt*>(at));'));
    expect(twin, contains('std::vector<uint8_t> _c_job = _nitro_copy_framed(job);'));
    expect(twin, contains('_nitro_copy_bytes(maybe, sizeof(NitroOptInt64))'));
    expect(twin, contains('g_nitro_pool_demo.enqueue([=]() mutable {'));
    expect(twin, contains('int64_t _r = demo_echo(instanceId, v, _n_label ? nullptr : _c_label.c_str(), (uint8_t*)_c_bytes.data(), bytes_length, (void*)_c_at, _c_job.empty() ? nullptr : (void*)_c_job.data(), _c_maybe.empty() ? nullptr : (const uint8_t*)_c_maybe.data());'));
    expect(twin, contains('if (_c_at) demo_release_Pt(_c_at);'));
    expect(twin, contains('if (_e->hasError) { _nitro_move_err(_nitro_err, _e); _nitro_post_null(dart_port); return; }'));
    expect(twin, contains('_nitro_post_i64(dart_port, _r);'));
    expect(cpp, contains('_nitro_post_str_owned(dart_port, (char*)_r);'));
    expect(cpp, contains('_nitro_post_ptr(dart_port, (const void*)_r);'));
    expect(cpp, contains('NITRO_EXPORT void demo_ping_dispatch(int64_t instanceId, NitroError* _nitro_err, int64_t dart_port) {'));
    expect(cpp, isNot(contains('demo_raw_dispatch')));
  });
}
