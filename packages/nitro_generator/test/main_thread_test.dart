// @mainThread dispatch annotation (issue #19).
//
// Kotlin: every impl call funnels through KotlinTypeMapper.runBlockingCall
// (coroutine paths) or KotlinTypeMapper.syncImplCall (direct sync paths) —
// both hop to Dispatchers.Main.immediate when the function is @mainThread.
// Swift: sync bodies are wrapped in the _nitroMainSync helper; async
// protocol requirements are marked @MainActor so conforming impls infer
// main-actor isolation.
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _spec({
  bool mainThread = true,
  bool isAsync = false,
  bool isNativeAsync = false,
  int? asyncTimeout,
  NativeImpl? macosImpl,
  NativeImpl? windowsImpl,
}) => BridgeSpec(
  dartClassName: 'Renderer',
  lib: 'renderer',
  namespace: 'renderer',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  macosImpl: macosImpl,
  windowsImpl: windowsImpl,
  sourceUri: 'renderer.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'render',
      cSymbol: 'renderer_render',
      isAsync: isAsync,
      isNativeAsync: isNativeAsync,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'frame', type: BridgeType(name: 'int'))],
      mainThread: mainThread,
      asyncTimeout: asyncTimeout,
    ),
  ],
);

void main() {
  group('@mainThread — Kotlin dispatch (issue #19)', () {
    test('sync call hops via runBlocking(Dispatchers.Main.immediate)', () {
      final out = KotlinGenerator.generate(_spec());
      expect(
        out,
        contains('runBlocking(kotlinx.coroutines.Dispatchers.Main.immediate) { impl.render(frame) }'),
      );
    });

    test('sync call without @mainThread stays a direct impl call', () {
      final out = KotlinGenerator.generate(_spec(mainThread: false));
      expect(out, isNot(contains('Dispatchers.Main')));
      expect(out, contains('impl.render(frame)'));
    });

    test('@nitroAsync executor body wraps in withContext(Dispatchers.Main.immediate)', () {
      final out = KotlinGenerator.generate(_spec(isAsync: true));
      expect(
        out,
        contains('runBlocking { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { impl.render(frame) } }'),
      );
    });

    test('@nitroAsync timeout composes AROUND the main-thread hop', () {
      final out = KotlinGenerator.generate(_spec(isAsync: true, asyncTimeout: 500));
      expect(
        out,
        contains(
          'runBlocking { kotlinx.coroutines.withTimeout(500L) { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { impl.render(frame) } } }',
        ),
      );
    });

    test('@nitroNativeAsync body wraps in withContext(Dispatchers.Main.immediate)', () {
      final out = KotlinGenerator.generate(_spec(isNativeAsync: true));
      expect(
        out,
        contains('runBlocking { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { impl.render(frame) } }'),
      );
    });
  });

  group('@mainThread — Swift dispatch (issue #19)', () {
    test('sync body is wrapped in one _nitroMainSync hop and the helper is emitted', () {
      final out = SwiftGenerator.generate(_spec());
      expect(out, contains('fileprivate func _nitroMainSync<T>(_ body: () -> T) -> T'));
      expect(out, contains('if Thread.isMainThread { return body() }'));
      expect(out, contains('return _nitroMainSync { () -> Int64 in'));
      // The impl call lives inside the wrapped body.
      final wrapIdx = out.indexOf('return _nitroMainSync { () -> Int64 in');
      final callIdx = out.indexOf('impl.render(frame: frame)', wrapIdx);
      expect(callIdx, greaterThan(wrapIdx));
    });

    test('without @mainThread neither the helper nor the wrapper appears', () {
      final out = SwiftGenerator.generate(_spec(mainThread: false));
      expect(out, isNot(contains('_nitroMainSync')));
    });

    test('@nitroAsync protocol requirement is @MainActor (impl infers main-actor isolation)', () {
      final out = SwiftGenerator.generate(_spec(isAsync: true));
      expect(out, contains('@MainActor func render(frame: Int64) async throws -> Int64'));
    });

    test('@nitroNativeAsync protocol requirement is @MainActor', () {
      final out = SwiftGenerator.generate(_spec(isNativeAsync: true));
      expect(out, contains('@MainActor func render(frame: Int64) async throws -> Int64'));
    });

    test('sync protocol requirement is NOT @MainActor (dispatch happens in the bridge)', () {
      final out = SwiftGenerator.generate(_spec());
      expect(out, contains('    func render(frame: Int64) -> Int64'));
      expect(out, isNot(contains('@MainActor func render')));
    });
  });

  group('@mainThread — extraction from source (issue #19)', () {
    test('@mainThread shorthand and @MainThread() class form both set the flag', () {
      final spec = SpecFromSource.parse('''
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, lib: 'renderer')
abstract class Renderer {
  @mainThread
  void attach(int surface);

  @MainThread()
  @nitroNativeAsync
  Future<void> attachAsync(int surface);

  void detach();
}
''');
      expect(spec.functions.singleWhere((f) => f.dartName == 'attach').mainThread, isTrue);
      expect(spec.functions.singleWhere((f) => f.dartName == 'attachAsync').mainThread, isTrue);
      expect(spec.functions.singleWhere((f) => f.dartName == 'detach').mainThread, isFalse);
    });
  });

  group('@mainThread — validator (issue #19)', () {
    test('warns when a C++ impl platform cannot honor the annotation', () {
      final issues = SpecValidator.validate(_spec(macosImpl: NativeImpl.cpp, windowsImpl: NativeImpl.cpp));
      final warning = issues.where((i) => i.code == 'MAIN_THREAD_NO_EFFECT').toList();
      expect(warning, hasLength(1));
      expect(warning.single.severity, ValidationSeverity.warning);
      expect(warning.single.message, contains('macos, windows'));
    });

    test('no warning for Kotlin/Swift-only platforms', () {
      final issues = SpecValidator.validate(_spec());
      expect(issues.where((i) => i.code == 'MAIN_THREAD_NO_EFFECT'), isEmpty);
    });
  });
}
