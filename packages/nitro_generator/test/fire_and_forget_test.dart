// Fire-and-forget void dispatch (issue #58): a `void` @nitroNativeAsync method
// is inferred (by return type — no extra annotation) as fire-and-forget. The
// C bridge emits a `<sym>_fnf` that copies args, enqueues the sync impl on the
// pool (bounded) and returns — no dart_port, no post — so a hot loop of small
// void calls isn't gated by the single-in-flight completion slot.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _spec = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Demo extends HybridObject {
  @nitroNativeAsync
  void push(int x);            // void + nativeAsync -> fire-and-forget
  @nitroNativeAsync
  Future<int> fetch(int id);   // awaited native-async (control)
}
''';

/// The body of `demo_push_fnf(...) { ... }` from the generated C bridge.
String _fnfBody(String cpp) {
  final start = cpp.indexOf('demo_push_fnf(');
  final open = cpp.indexOf('{', start);
  return cpp.substring(open, cpp.indexOf('\n}', open));
}

void main() {
  final spec = SpecFromSource.parse(_spec, sourceUri: 'package:demo/src/demo.native.dart');

  test('spec classifies the void native-async method as fire-and-forget (control is not)', () {
    final push = spec.functions.firstWhere((f) => f.dartName == 'push');
    final fetch = spec.functions.firstWhere((f) => f.dartName == 'fetch');
    expect(spec.fireAndForget(push), isTrue);
    expect(spec.fireAndForget(fetch), isFalse, reason: 'Future<int> is awaited, not fire-and-forget');
    expect(spec.nativeSymbol(push), 'demo_push_fnf');
  });

  test('C bridge emits <sym>_fnf: enqueues bounded, no port, no post', () {
    final cpp = CppBridgeGenerator.generate(spec);
    expect(cpp, contains('NITRO_EXPORT void demo_push_fnf('));
    expect(cpp, contains('g_nitro_pool_demo.enqueueBounded('));
    final body = _fnfBody(cpp);
    expect(body, contains('demo_push('), reason: 'enqueued lambda calls the plain sync impl');
    expect(body, isNot(contains('dart_port')), reason: 'fire-and-forget has no completion port');
    expect(body, isNot(contains('_nitro_post')), reason: 'fire-and-forget never posts a result');
  });

  test('C header declares the plain sync impl + the _fnf wrapper (no dart_port, no _dispatch)', () {
    final h = CppHeaderGenerator.generate(spec);
    expect(h, contains('NITRO_EXPORT void demo_push('));
    expect(h, contains('NITRO_EXPORT void demo_push_fnf('));
    expect(h, isNot(contains('demo_push_dispatch')));
  });

  test('Dart emits a bare void method that calls the _fnf pointer (no Future, no await/register)', () {
    final dart = DartFfiGenerator.generate(spec);
    // Bare void, not Future<void>.
    expect(dart, contains('void push(int x)'));
    expect(dart, isNot(contains('Future<void> push')));
    // The FFI pointer binds <sym>_fnf with a plain void signature (no NitroErrorFfi, no port).
    expect(dart, contains("lookupFunction<Void Function(Int64, Int64), void Function(int, int)>('demo_push_fnf')"));
    // Body just calls the pointer and returns — no openNativeAsync / register / await.
    expect(dart, contains('_pushPtr(_instanceId, x)'));
    // Control: fetch stays an awaited Future<int>.
    expect(dart, contains('Future<int> fetch('));
  });
}
