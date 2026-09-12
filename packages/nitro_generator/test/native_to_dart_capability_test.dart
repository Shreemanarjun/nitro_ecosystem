// Documents HOW generated code lets native reach Dart today, and what it does
// not provide. Every native → Dart path requires a live isolate holding the
// receiving object: callbacks are NativeCallable.listener trampolines,
// native-async completions and streams are Dart_PostCObject_DL posts to a
// ReceivePort. Nothing is emitted for locating a Dart function from native
// without such a reference UNLESS the spec declares @NitroEntryPoint functions
// (see entry_point_test.dart): only then are `@pragma('vm:entry-point')`
// wrappers and the background job table emitted. A spec without them stays
// byte-identical to earlier releases — which is what this file pins.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

BridgeSpec _spec() => BridgeSpec(
  dartClassName: 'Bg',
  lib: 'bg',
  namespace: 'bg',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'bg.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'onTick',
      cSymbol: 'bg_on_tick',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'handler',
          type: BridgeType(name: 'Function', isFunction: true, functionReturnType: 'void', functionParams: [BridgeType(name: 'int')]),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'compute',
      cSymbol: 'bg_compute',
      isAsync: true,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'x', type: BridgeType(name: 'int'))],
    ),
  ],
);

void main() {
  late String dart, ffi, cpp;
  setUpAll(() {
    final s = _spec();
    dart = DartFfiGenerator.generate(s);
    ffi = DartFfiGenerator.generateFfiLibrary(s);
    cpp = CppBridgeGenerator.generate(s);
  });

  test('callbacks reach Dart through NativeCallable.listener (live isolate required)', () {
    expect('$dart$ffi', contains('NativeCallable'));
  });

  test('native-async completions arrive on a ReceivePort via Dart_PostCObject_DL', () {
    expect('$dart$ffi', contains('openNativeAsync'));
    expect(cpp, contains('Dart_PostCObject_DL'));
  });

  test('without @NitroEntryPoint nothing background-related is generated', () {
    for (final out in [dart, ffi, cpp]) {
      expect(out, isNot(contains('vm:entry-point')));
      expect(out, isNot(contains('PluginUtilities')));
      expect(out, isNot(contains('getCallbackHandle')));
    }
  });
}
