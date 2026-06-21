/// S8 out-param ABI tests — generator output correctness + edge cases.
///
/// S8 eliminates the two-call `get_error()` / `clear_error()` pattern from
/// every synchronous bridge call. Each generated C function receives a
/// `NitroError*` out-parameter and writes error info directly into it.
/// Dart pre-allocates ONE slot per module instance and passes it to every
/// sync call — zero heap allocation per call in normal operation.

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
      params: [BridgeParam(name: 'channel', type: BridgeType(name: 'int'))],
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
        BridgeParam(name: 'a', type: BridgeType(name: 'double')),
        BridgeParam(name: 'b', type: BridgeType(name: 'double')),
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
        BridgeField(name: 'id', type: BridgeType(name: 'String')),
        BridgeField(name: 'level', type: BridgeType(name: 'double')),
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
      expect(out, contains('NITRO_EXPORT double sensor_read(int64_t channel, NitroError* _nitro_err);'));
    });

    test('sync void function (no params): NitroError* is the only param', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT void sensor_reset(NitroError* _nitro_err);'));
    });

    test('@NitroNativeAsync function does NOT receive NitroError* — uses dart_port', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('sensor_capture(int64_t dart_port)'));
      expect(out, isNot(contains('sensor_capture(int64_t dart_port, NitroError*')));
    });

    test('property getter: NitroError* appended', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT int64_t sensor_get_rate(NitroError* _nitro_err);'));
    });

    test('property setter: NitroError* appended after value param', () {
      final out = CppHeaderGenerator.generate(_syncSpec());
      expect(out, contains('NITRO_EXPORT void sensor_set_rate(int64_t value, NitroError* _nitro_err);'));
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
    test('_nitroErr pre-allocated slot in class field', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('final Pointer<NitroErrorFfi> _nitroErr = calloc<NitroErrorFfi>();'));
    });

    test('dispose() frees _nitroErr slot', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('calloc.free(_nitroErr);'));
    });

    test('sync returning function: FFI type includes Pointer<NitroErrorFfi>', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('Double Function(Int64, Pointer<NitroErrorFfi>)'));
    });

    test('sync void function: FFI type includes only Pointer<NitroErrorFfi>', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // Void Function(Pointer<NitroErrorFfi>) but NOT Void Function() alone
      expect(out, contains('Void Function(Pointer<NitroErrorFfi>)'));
    });

    test('sync call site appends _nitroErr as last arg', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('_readPtr(channel, _nitroErr)'));
    });

    test('void sync call site passes _nitroErr', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('_resetPtr(_nitroErr)'));
    });

    test('error check uses throwIfOutParamError (not assert-gated checkError)', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('NitroRuntime.throwIfOutParamError(_nitroErr)'));
      expect(out, isNot(contains('NitroRuntime.checkError(_getErrorPtr')));
    });

    test('@NitroNativeAsync function body does NOT use _nitroErr in the native call', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      // Locate the capturePtr call and verify it uses dart_port, not _nitroErr
      final idx = out.indexOf('_capturePtr(');
      if (idx == -1) {
        // NativeAsync uses a different call pattern (via callAsync/openNativeAsync)
        expect(out, contains('sensor_capture'));
      } else {
        final callSite = out.substring(idx, idx + 100);
        expect(callSite, isNot(contains('_nitroErr')));
      }
    });

    test('property getter FFI type includes Pointer<NitroErrorFfi>', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('Pointer<NitroErrorFfi>) _getRatePtr'));
    });

    test('property getter call passes _nitroErr', () {
      final out = DartFfiGenerator.generate(_syncSpec());
      expect(out, contains('_getRatePtr(_nitroErr)'));
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
              BridgeField(name: 'value', type: BridgeType(name: 'double')),
              BridgeField(name: 'ts', type: BridgeType(name: 'int')),
              BridgeField(name: 'valid', type: BridgeType(name: 'bool')),
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
            fields: [BridgeField(name: 'value', type: BridgeType(name: 'String?'))],
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
              BridgeField(name: 'id', type: BridgeType(name: 'String')),
              BridgeField(name: 'name', type: BridgeType(name: 'String')),
              BridgeField(name: 'address', type: BridgeType(name: 'String')),
              BridgeField(name: 'pages', type: BridgeType(name: 'int')),
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
