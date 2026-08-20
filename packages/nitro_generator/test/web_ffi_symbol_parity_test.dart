// Anti-drift: the FFI library and the web bridge must drive the SAME C ABI.
// Extracts every C symbol each backend binds for a maximal fixture spec and
// asserts set equality (modulo a documented per-platform allowlist). A new
// method/stream/property that reaches only one backend fails here.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';

BridgeSpec _maximalSpec() => BridgeSpec(
  dartClassName: 'Par',
  lib: 'par',
  namespace: 'par',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  webImpl: NativeImpl.wasm,
  sourceUri: 'par.native.dart',
  enums: [
    BridgeEnum(name: 'ParMode', startValue: 0, values: ['a', 'b']),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'ParStat',
      fields: [
        BridgeRecordField(name: 'n', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'par_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'a', type: BridgeType(name: 'double')),
        BridgeParam(name: 'b', type: BridgeType(name: 'double')),
      ],
    ),
    BridgeFunction(
      dartName: 'greet',
      cSymbol: 'par_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [BridgeParam(name: 'who', type: BridgeType(name: 'String'))],
    ),
    BridgeFunction(
      dartName: 'stat',
      cSymbol: 'par_stat',
      isAsync: false,
      returnType: BridgeType(name: 'ParStat', isRecord: true),
      params: [BridgeParam(name: 'v', type: BridgeType(name: 'ParStat', isRecord: true))],
    ),
    BridgeFunction(
      dartName: 'crunch',
      cSymbol: 'par_crunch',
      isAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'echoAsync',
      cSymbol: 'par_echo_async',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'v', type: BridgeType(name: 'int'))],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'level',
      type: BridgeType(name: 'int'),
      getSymbol: 'par_get_level',
      setSymbol: 'par_set_level',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'ticks',
      registerSymbol: 'par_register_ticks_stream',
      releaseSymbol: 'par_release_ticks_stream',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// Every single-quoted `par_*` C symbol referenced by a generated backend —
/// robust to formatting (lookupFunction spans lines; the web side calls
/// through `_m.call('par_...')`).
Set<String> _symbols(String src) {
  final re = RegExp("'(par_[a-z0-9_]+)'");
  return re.allMatches(src).map((m) => m.group(1)!).toSet();
}

void main() {
  test('web bridge binds the same C symbol set as the FFI library', () {
    final spec = _maximalSpec();
    final ffi = _symbols(DartFfiGenerator.generateFfiLibrary(spec));
    final web = _symbols(WebBridgeGenerator.generate(spec));

    // Sanity: both backends found the core per-spec symbols.
    for (final sym in ['par_add', 'par_greet', 'par_stat', 'par_crunch', 'par_echo_async', 'par_get_level', 'par_set_level', 'par_register_ticks_stream', 'par_release_ticks_stream', 'par_create_instance', 'par_destroy_instance']) {
      expect(ffi, contains(sym), reason: 'FFI library must bind $sym');
      expect(web, contains(sym), reason: 'web bridge must call $sym');
    }
    expect(ffi, contains('par_nitro_free'));

    // Per-platform allowlist — everything else must match exactly.
    const ffiOnly = {
      // The VM handshake has no web meaning (compat shim returns 0).
      'par_init_dart_api_dl',
      // Bound by the web RUNTIME by convention — NitroWasmModule builds
      // '<lib>_nitro_free' / '<lib>_nitro_alloc' from the lib name, so the
      // literals never appear in the generated web file.
      'par_nitro_free',
      'par_nitro_alloc',
    };
    const webOnly = {
      // Web replacement for the Dart_PostCObject handshake.
      'par_nitro_set_post_fn',
    };

    final missingOnWeb = ffi.difference(web).difference(ffiOnly);
    expect(
      missingOnWeb,
      isEmpty,
      reason: 'C symbols the FFI library binds but the web bridge never calls '
          '(add them to the web generator or the allowlist): $missingOnWeb',
    );

    final extraOnWeb = web.difference(ffi).difference(webOnly);
    expect(
      extraOnWeb,
      isEmpty,
      reason: 'C symbols the web bridge calls but the FFI library never binds '
          '(the wasm build would need exports the native bridge lacks): $extraOnWeb',
    );
  });
}
