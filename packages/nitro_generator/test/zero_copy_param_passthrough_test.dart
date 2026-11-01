// Coverage for @zeroCopy TypedData on the DynamicLibrary path:
//   params  → pass a nitro native-backed view (NitroBuffer / @zeroCopy return) as
//             its pointer via nitroZeroCopyPtr(); anything else falls back to toPointer().
//   returns → the handed-out view is registered so passing it back is pointer-only.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

BridgeSpec _spec() => BridgeSpec(
  dartClassName: 'Frames',
  lib: 'frames',
  namespace: 'frames_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'frames.native.dart',
  structs: const [],
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'frames_module_process',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'data', type: BridgeType(name: 'Uint8List'), zeroCopy: true)],
    ),
    BridgeFunction(
      dartName: 'processF',
      cSymbol: 'frames_module_process_f',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'samples', type: BridgeType(name: 'Float32List'), zeroCopy: true)],
    ),
    BridgeFunction(
      dartName: 'plain',
      cSymbol: 'frames_module_plain',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'raw', type: BridgeType(name: 'Uint8List'))],
    ),
    BridgeFunction(
      dartName: 'maybe',
      cSymbol: 'frames_module_maybe',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'opt', type: BridgeType(name: 'Uint8List?'), zeroCopy: true)],
    ),
    BridgeFunction(
      dartName: 'grab',
      cSymbol: 'frames_module_grab',
      isAsync: false,
      returnType: BridgeType(name: 'Uint8List'),
      zeroCopyReturn: true,
      params: const [],
    ),
    // @nitroAsync: crosses on the callAsync path; the param marshals through the
    // same arena-wrapped callArgs, so the pass-through must survive the await.
    BridgeFunction(
      dartName: 'processAsync',
      cSymbol: 'frames_module_process_async',
      isAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'adata', type: BridgeType(name: 'Uint8List'), zeroCopy: true)],
    ),
    // @nitroNativeAsync: native posts the result from a background thread; the
    // buffer rides openNativeAsync's call closure and the arena outlives the await.
    BridgeFunction(
      dartName: 'processNativeAsync',
      cSymbol: 'frames_module_process_native_async',
      isAsync: true,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'ndata', type: BridgeType(name: 'Uint8List'), zeroCopy: true)],
    ),
  ],
);

void main() {
  late String out;
  setUpAll(() => out = DartFfiGenerator.generate(_spec()));

  group('@zeroCopy TypedData param — DynamicLibrary path', () {
    test('passes a registered native-backed view as its pointer, else copies', () {
      expect(out, contains('(nitroZeroCopyPtr(data)?.cast<Uint8>() ?? data.toPointer(arena)), data.length'));
    });

    test('casts to the element type of the TypedData', () {
      expect(out, contains('(nitroZeroCopyPtr(samples)?.cast<Float>() ?? samples.toPointer(arena)), samples.length'));
    });

    test('a non-@zeroCopy TypedData param keeps the plain copy (callee may retain it)', () {
      expect(out, contains('raw.toPointer(arena), raw.length'));
      expect(out, isNot(contains('nitroZeroCopyPtr(raw)')));
    });

    test('nullable @zeroCopy param: nullptr when null, pass-through otherwise', () {
      expect(out, contains('opt == null ? nullptr : (nitroZeroCopyPtr(opt)?.cast<Uint8>() ?? opt.toPointer(arena)), opt?.length ?? 0'));
    });

    test('@nitroAsync param passes through (not copied) across the await', () {
      expect(out, contains('(nitroZeroCopyPtr(adata)?.cast<Uint8>() ?? adata.toPointer(arena)), adata.length'));
    });

    test('@nitroNativeAsync param passes through (not copied) on the background-dispatch path', () {
      expect(out, contains('(nitroZeroCopyPtr(ndata)?.cast<Uint8>() ?? ndata.toPointer(arena)), ndata.length'));
    });
  });

  group('@zeroCopy TypedData return', () {
    test('registers the handed-out view so it can be passed back without a copy', () {
      expect(out, contains('return nitroRegisterZeroCopyView(payloadPtr.asTypedList('));
      expect(out, contains(', payloadPtr.cast<Void>());'));
    });
  });
}
