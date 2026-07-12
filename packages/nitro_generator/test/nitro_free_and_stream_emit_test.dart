// Regression tests for two memory-safety root causes found by the first
// nitro_type_coverage CI run whose desktop builds actually executed:
//
// 1. Windows heap corruption — generated Dart freed native-malloc'd pointers
//    with package:ffi's `malloc.free`, which binds to CoTaskMemFree on
//    Windows. The Windows CI job died at exactly its 15th test
//    (`echoString('')` — the first call that frees a native pointer from
//    Dart; the 14 preceding int/double/bool tests return scalars). Every
//    bridge section now exports `<lib>_nitro_free(void*)` (a plain C-runtime
//    free) and generated Dart routes ALL native-owned frees through it.
//
// 2. Desktop record/variant stream-emit double prefix — `emit_<stream>()`
//    re-wrapped the impl's already-prefixed `toNativeBuffer()` block in a
//    second [4B len] prefix. Dart's `readString` then consumed the inner
//    prefix as string bytes and threw `FormatException: Missing extension
//    byte (at offset 33)` on every configStream event (threshold 0.5's
//    0xE0 0x3F IEEE-754 tail is invalid UTF-8), failing §30.1 and hanging
//    the Linux job for 33 minutes. The emit contract is now ownership
//    transfer, identical to record returns: post `item.data` directly.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

/// Mixed-platform spec (android:kotlin + ios:swift + windows/linux:cpp) with
/// a record stream, an int stream, and a string-returning method — the
/// smallest spec that exercises every changed code path at once.
BridgeSpec _spec() => BridgeSpec(
  dartClassName: 'FreeTest',
  lib: 'nitro_free_test',
  namespace: 'nitro_free_test',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  windowsImpl: NativeImpl.cpp,
  linuxImpl: NativeImpl.cpp,
  sourceUri: 'nitro_free_test.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Config',
      fields: [
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'threshold', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoString',
      cSymbol: 'nitro_free_test_echo_string',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'String'))],
    ),
    BridgeFunction(
      dartName: 'getConfig',
      cSymbol: 'nitro_free_test_get_config',
      isAsync: false,
      returnType: BridgeType(name: 'Config', isRecord: true),
      params: [],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'configStream',
      registerSymbol: 'nitro_free_test_register_config_stream_stream',
      releaseSymbol: 'nitro_free_test_release_config_stream_stream',
      itemType: BridgeType(name: 'Config', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'tickStream',
      registerSymbol: 'nitro_free_test_register_tick_stream_stream',
      releaseSymbol: 'nitro_free_test_release_tick_stream_stream',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

void main() {
  group('<lib>_nitro_free export — Windows CoTaskMemFree heap-corruption fix', () {
    test('C bridge exports nitro_free unconditionally in JNI, Apple-shim, and desktop sections', () {
      final out = CppBridgeGenerator.generate(_spec());
      const exportLine = 'NITRO_EXPORT void nitro_free_test_nitro_free(void* ptr) { if (ptr) { free(ptr); } }';
      // One per platform section of the mixed-platform bridge: JNI (Android),
      // ObjC++ shim (iOS/macOS Swift), and Windows/Linux desktop dispatch.
      final count = exportLine.allMatches(out).length;
      expect(count, 3, reason: 'expected the export in all 3 platform sections, found $count');
    });

    test('C header declares nitro_free unconditionally (no zero-copy needed)', () {
      final out = CppHeaderGenerator.generate(_spec());
      expect(out, contains('NITRO_EXPORT void nitro_free_test_nitro_free(void* ptr);'));
    });

    test('Dart impl class binds _nitroFree + finalizer variant from the export', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains("_dylib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('nitro_free_test_nitro_free')"));
      expect(out, contains('void _nitroFree(Pointer<NativeType> ptr) => _nitroFreePtr(ptr.cast());'));
      expect(out, contains("_dylib.lookup<NativeFinalizerFunction>('nitro_free_test_nitro_free').cast()"));
    });

    test('string return decodes via toDartStringFreedBy(_nitroFree), never toDartStringWithFree', () {
      // toDartStringWithFree() uses package:ffi's malloc.free — CoTaskMemFree
      // on Windows — on the native strdup'd string. This was the exact call
      // that killed the Windows CI job at its 15th test.
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('.toDartStringFreedBy(_nitroFree)'));
      expect(out, isNot(contains('.toDartStringWithFree()')));
    });

    test('record return frees the native blob via _nitroFree, not malloc.free', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_nitroFree(res)'));
      expect(out, isNot(contains('malloc.free(res)')));
    });

    test('record stream unpack frees the posted blob via _nitroFree', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('finally { _nitroFree(rawPtr); }'));
      expect(out, isNot(contains('finally { malloc.free(rawPtr); }')));
    });

    test('S8 error-slot checks pass the native free for the strdup\'d string fields', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('NitroRuntime.throwIfOutParamError(_nitroErr, nativeFree: _nitroFree);'));
    });
  });

  group('desktop stream emit — ownership transfer (Linux §30.1 double-prefix regression)', () {
    test('record emit posts item.data directly — no second [4B len] wrap', () {
      final out = CppBridgeGenerator.generate(_spec());
      expect(out, contains('void HybridFreeTest::emit_configStream(NitroCppBuffer item) {'));
      expect(out, contains('obj.value.as_int64 = (intptr_t)item.data;'));
      // The old re-wrap: malloc(4 + item.size) + memcpy of a fresh length
      // prefix. Paired with the impl's natural toNativeBuffer() call this
      // double-prefixed the wire payload (FormatException at offset 33) and
      // leaked the impl's block on every emit.
      expect(out, isNot(contains('malloc(4 + item.size)')));
    });

    test('record emit frees the block when the port is closed', () {
      final out = CppBridgeGenerator.generate(_spec());
      expect(out, contains('if (port == 0) { if (item.data) { free((void*)item.data); } return; }'));
    });

    test('record emit frees the block when the post fails (ownership never transferred)', () {
      final out = CppBridgeGenerator.generate(_spec());
      expect(out, contains('free((void*)item.data);'));
    });

    test('record emit posts kNull for a {nullptr,0} item (nullable streams)', () {
      final out = CppBridgeGenerator.generate(_spec());
      expect(out, contains('if (item.data == nullptr) {'));
    });

    test('non-record (int) stream emit keeps the plain closed-port early return', () {
      final out = CppBridgeGenerator.generate(_spec());
      expect(out, contains('void HybridFreeTest::emit_tickStream(int64_t item) {'));
      // No buffer to release on a scalar stream — the bare return stays.
      final start = out.indexOf('emit_tickStream(int64_t item)');
      final tickBody = out.substring(start, start + 200);
      expect(tickBody, contains('if (port == 0) { return; }'));
      expect(tickBody, isNot(contains('free(')));
    });
  });
}
