// S8 out-param ABI tests — generator output correctness + edge cases.
//
// S8 eliminates the two-call `get_error()` / `clear_error()` pattern from
// every synchronous bridge call. Each generated C function receives a
// `NitroError*` out-parameter and writes error info directly into it.
// Dart pre-allocates ONE slot per module instance and passes it to every
// sync call — zero heap allocation per call in normal operation.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _syncSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'read',
      cSymbol: 'sensor_read',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'channel',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'reset',
      cSymbol: 'sensor_reset',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'capture',
      cSymbol: 'sensor_capture',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Uint8List'),
      params: [],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'rate',
      type: BridgeType(name: 'int'),
      getSymbol: 'sensor_get_rate',
      setSymbol: 'sensor_set_rate',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
);

BridgeSpec _cppSyncSpec() => BridgeSpec(
  dartClassName: 'Math',
  lib: 'math',
  namespace: 'math',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'math.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'math_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'reset',
      cSymbol: 'math_reset',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
  ],
);

BridgeSpec _structWithStringField() => BridgeSpec(
  dartClassName: 'Device',
  lib: 'device',
  namespace: 'device',
  iosImpl: NativeImpl.swift,
  sourceUri: 'device.native.dart',
  structs: [
    BridgeStruct(
      name: 'DeviceInfo',
      packed: false,
      fields: [
        BridgeField(
          name: 'id',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'level',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
  functions: [],
);

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  // ── C header declarations ─────────────────────────────────────────────────
  group('S8 — C header NitroError* out-param', () {
    test('sync function with params: NitroError* appended', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT double sensor_read(int64_t instanceId, int64_t channel, NitroError* _nitro_err);'));
    });

    test('sync void function (no params): NitroError* is the only param', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT void sensor_reset(int64_t instanceId, NitroError* _nitro_err);'));
    });

    test('@NitroNativeAsync function DOES receive a fresh-per-call NitroError*, before dart_port', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      // Unlike sync's one instance-owned slot, native-async calls aren't
      // serialized (multiple can be in flight concurrently on the same
      // instance), so it gets a NitroError* too — Dart allocates a fresh
      // struct per call instead of reusing an instance field. See
      // NitroRuntime.throwIfOutParamErrorAndFree.
      expect(out, contains('sensor_capture(int64_t instanceId, NitroError* _nitro_err, int64_t dart_port)'));
    });

    test('property getter: NitroError* appended', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT int64_t sensor_get_rate(int64_t instanceId, NitroError* _nitro_err);'));
    });

    test('property setter: NitroError* appended after value param', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT void sensor_set_rate(int64_t instanceId, int64_t value, NitroError* _nitro_err);'));
    });

    test('infrastructure functions remain (void) — ABI version, checksum', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('sensor_nitro_abi_version(void)'));
      expect(out, contains('sensor_nitro_bridge_checksum(void)'));
      expect(out, isNot(contains('sensor_nitro_abi_version(NitroError*')));
    });
  });

  // ── C++ bridge (direct NativeImpl.cpp path) ───────────────────────────────
  group('S8 — C++ bridge direct path correctness', () {
    test('_nitro_out_err helper is emitted in bridge file', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      expect(out, contains('static void _nitro_out_err(NitroError* e,'));
      expect(out, contains('e->hasError = 1;'));
    });

    test('slot is reset at start of each function: if (_nitro_err) { _nitro_err->hasError = 0; }', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      // Verify the reset pattern appears for each method (add + reset = 2)
      final count = 'if (_nitro_err) { _nitro_err->hasError = 0; }'.allMatches(out).length;
      expect(count, greaterThanOrEqualTo(2));
    });

    test('catch block uses _nitro_out_err instead of nitro_report_error', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      expect(out, contains('_nitro_out_err(_nitro_err, "CppException", e.what())'));
      expect(out, isNot(contains('nitro_report_error("CppException"')));
    });

    test('unknown exception catch uses _nitro_out_err', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      expect(out, contains('_nitro_out_err(_nitro_err, "CppException", "Unknown C++ exception")'));
    });

    test('NotInitialized guard uses _nitro_out_err', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      expect(out, contains('_nitro_out_err(_nitro_err, "NotInitialized"'));
    });

    test('TLS get_error / clear_error still exported for backward compat (async path)', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      expect(out, contains('math_get_error()'));
      expect(out, contains('math_clear_error()'));
    });

    test('_nitro_out_err handles null _nitro_err gracefully (if (!e) return)', () {
      final out = CppBridgeGenerator.generate(_cppSyncSpec());
      expect(out, contains('if (!e) return;'));
    });
  });

  // ── Dart FFI generator ────────────────────────────────────────────────────
  group('S8 — Dart FFI generator out-param wiring', () {
    test('_nitroErr pre-allocated slot in class field is ZEROED (calloc)', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // calloc, NOT malloc: "C overwrites the slot" is exactly the assumption
      // that broke — a bridge path that forgets the S8 write leaves Dart
      // reading garbage hasError + wild char* fields → segfault (seen on the
      // Windows/Linux mixed-spec desktop bridge). Zeroed memory means a
      // forgotten write degrades to "no error", never a crash.
      expect(out, contains('final Pointer<NitroErrorFfi> _nitroErr = calloc<NitroErrorFfi>();'));
      expect(out, isNot(contains('_nitroErr = malloc<NitroErrorFfi>()')));
    });

    test('dispose() frees _nitroErr slot', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('calloc.free(_nitroErr);'));
    });

    test('dispose() guards against double-free with isDisposed check', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // Ensure the generated dispose() has an early-return guard so calling
      // dispose() twice does not double-free _nitroErr (malloc crash on macOS).
      expect(out, contains('if (isDisposed) return;'));
    });

    test('sync returning function: FFI type includes Pointer<NitroErrorFfi>', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('Double Function(Int64, Int64, Pointer<NitroErrorFfi>)'));
    });

    test('sync void function: FFI type includes only Pointer<NitroErrorFfi>', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // Void Function(Int64, Pointer<NitroErrorFfi>) but NOT Void Function() alone
      expect(out, contains('Void Function(Int64, Pointer<NitroErrorFfi>)'));
    });

    test('sync call site appends _nitroErr as last arg', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('_readPtr(_instanceId, channel, _nitroErr)'));
    });

    test('void sync call site passes _nitroErr', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('_resetPtr(_instanceId, _nitroErr)'));
    });

    test('error check uses throwIfOutParamError (not assert-gated checkError)', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('NitroRuntime.throwIfOutParamError(_nitroErr, nativeFree: _nitroFree)'));
      expect(out, isNot(contains('NitroRuntime.checkError(_getErrorPtr')));
    });

    test('@NitroNativeAsync function body DOES use a fresh-per-call _nitroErr in the native call', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // Unlike sync's instance-owned _nitroErr field, native-async allocates
      // a fresh calloc'd slot right before the call (calls aren't serialized,
      // so they can't share one instance-owned slot) and checks+frees it
      // inside the wrapped unpack closure, before decoding raw.
      expect(out, contains('final _nitroErr = calloc<NitroErrorFfi>();'));
      expect(out, contains('_capturePtr(_instanceId, _nitroErr, port)'));
      expect(out, contains('NitroRuntime.throwIfOutParamErrorAndFree(_nitroErr, nativeFree: _nitroFree);'));
    });

    test('property getter FFI type includes Pointer<NitroErrorFfi>', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('int, Pointer<NitroErrorFfi>) _getRatePtr'));
    });

    test('property getter call passes _nitroErr', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('_getRatePtr(_instanceId, _nitroErr)'));
    });

    test('property setter call passes value AND _nitroErr', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // setter: _setRatePtr(value, _nitroErr)  or _setRatePtr(value ? 1 : 0, _nitroErr)
      expect(out, contains('_setRatePtr('));
      final setterIdx = out.indexOf('_setRatePtr(');
      final setterCall = out.substring(setterIdx, setterIdx + 60);
      expect(setterCall, contains('_nitroErr'));
    });
  });

  // ── D4: @HybridStruct String field validator warning ─────────────────────
  group('D4 — @HybridStruct String field advisory', () {
    test('struct with String field emits STRUCT_STRING_FIELD warning', () {
      final issues = SpecValidator.validate(_structWithStringField());
      final ws = issues.where((i) => i.code == 'STRUCT_STRING_FIELD').toList();
      expect(ws, isNotEmpty);
      expect(ws.first.severity, ValidationSeverity.warning);
      expect(ws.first.message, contains('DeviceInfo'));
      expect(ws.first.message, contains('id'));
    });

    test('struct with only numeric fields: no STRUCT_STRING_FIELD warning', () {
      final spec = BridgeSpec(
        dartClassName: 'Sensor',
        lib: 'sensor',
        namespace: 'sensor',
        iosImpl: NativeImpl.swift,
        sourceUri: 'sensor.native.dart',
        structs: [
          BridgeStruct(
            name: 'Reading',
            packed: false,
            fields: [
              BridgeField(
                name: 'value',
                type: BridgeType(name: 'double'),
              ),
              BridgeField(
                name: 'ts',
                type: BridgeType(name: 'int'),
              ),
              BridgeField(
                name: 'valid',
                type: BridgeType(name: 'bool'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ws = SpecValidator.validate(spec).where((i) => i.code == 'STRUCT_STRING_FIELD');
      expect(ws, isEmpty);
    });

    test('warning hint recommends @HybridRecord for string-heavy structs', () {
      final issues = SpecValidator.validate(_structWithStringField());
      final w = issues.firstWhere((i) => i.code == 'STRUCT_STRING_FIELD');
      expect(w.hint, contains('@HybridRecord'));
    });

    test('nullable String? field also triggers warning', () {
      final spec = BridgeSpec(
        dartClassName: 'Net',
        lib: 'net',
        namespace: 'net',
        iosImpl: NativeImpl.swift,
        sourceUri: 'net.native.dart',
        structs: [
          BridgeStruct(
            name: 'Header',
            packed: false,
            fields: [
              BridgeField(
                name: 'value',
                type: BridgeType(name: 'String?'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ws = SpecValidator.validate(spec).where((i) => i.code == 'STRUCT_STRING_FIELD');
      expect(ws, isNotEmpty);
    });

    test('struct with multiple String fields: all field names in warning message', () {
      final spec = BridgeSpec(
        dartClassName: 'Printer',
        lib: 'printer',
        namespace: 'printer',
        iosImpl: NativeImpl.swift,
        sourceUri: 'printer.native.dart',
        structs: [
          BridgeStruct(
            name: 'PrinterInfo',
            packed: false,
            fields: [
              BridgeField(
                name: 'id',
                type: BridgeType(name: 'String'),
              ),
              BridgeField(
                name: 'name',
                type: BridgeType(name: 'String'),
              ),
              BridgeField(
                name: 'address',
                type: BridgeType(name: 'String'),
              ),
              BridgeField(
                name: 'pages',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ws = SpecValidator.validate(spec).where((i) => i.code == 'STRUCT_STRING_FIELD').toList();
      expect(ws.length, 1); // one warning per struct, listing all fields
      expect(ws.first.message, contains('id'));
      expect(ws.first.message, contains('name'));
      expect(ws.first.message, contains('address'));
      // 'pages' is int — not in warning
      expect(ws.first.message, isNot(contains('pages')));
    });

    test('warning is advisory (warning severity, not error)', () {
      final issues = SpecValidator.validate(_structWithStringField());
      final ws = issues.where((i) => i.code == 'STRUCT_STRING_FIELD');
      for (final w in ws) {
        expect(w.isError, isFalse);
      }
    });
  });
}
