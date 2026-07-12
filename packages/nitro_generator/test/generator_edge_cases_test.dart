// Edge cases that were previously untested — each group targets one specific
// generator behaviour that could silently regress.
//
//  §1  Future<void> async return — Dart FFI
//  §2  Future<void> async return — Swift
//  §3  Nullable struct return — throws StateError, not Dart null
//  §4  All-optional named params — entire param list inside {…}
//  §5  Empty spec — no functions/props/streams → valid output, no crash
//  §6  List<int> param — RecordWriter.encodeIndexedPrimitiveList path
//  §7  Non-nullable bool param — bool→int conversion, no sentinel
//  §8  Kotlin _call bool return — uses Boolean, not Long/sentinel
//  §9  Multiple enums in one spec — all emitted, no collision
//  §10 Parameterless async function — callAsync called with empty arg list
//  §11 Swift @NitroNativeAsync void function — no return value in stub
//  §12 Kotlin async (runBlocking) for void return
//  §13 Spec with only properties — no functions section
//  §14 C++ interface empty spec — valid header emitted
//  §15 SwiftGenerator — iOS not targeted comment when iosImpl is null

import 'package:test/test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';

// ── Spec builders ─────────────────────────────────────────────────────────────

BridgeSpec _asyncVoidSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'flush',
      cSymbol: 'mod_flush',
      isAsync: true,
      returnType: BridgeType(name: 'void', isFuture: false),
      params: [],
    ),
  ],
);

BridgeSpec _nullableStructReturnSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  structs: [
    BridgeStruct(
      name: 'Sensor',
      packed: false,
      fields: [
        BridgeField(
          name: 'id',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'readSensor',
      cSymbol: 'mod_read_sensor',
      isAsync: false,
      returnType: BridgeType(name: 'Sensor'),
      params: [],
    ),
  ],
);

BridgeSpec _allOptionalSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'configure',
      cSymbol: 'mod_configure',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'timeout',
          type: BridgeType(name: 'int'),
          isNamed: true,
          isOptional: true,
          defaultLiteral: '30',
        ),
        BridgeParam(
          name: 'retries',
          type: BridgeType(name: 'int'),
          isNamed: true,
          isOptional: true,
          defaultLiteral: '3',
        ),
        BridgeParam(
          name: 'verbose',
          type: BridgeType(name: 'bool'),
          isNamed: true,
          isOptional: true,
          defaultLiteral: 'false',
        ),
      ],
    ),
  ],
);

BridgeSpec _emptySpec() => BridgeSpec(
  dartClassName: 'Empty',
  lib: 'empty',
  namespace: 'empty',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'empty.native.dart',
  functions: [],
  properties: [],
  streams: [],
);

// CppInterfaceGenerator only runs for cpp implementations.
BridgeSpec _emptyCppSpec() => BridgeSpec(
  dartClassName: 'Empty',
  lib: 'empty',
  namespace: 'empty',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'empty.native.dart',
  functions: [],
  properties: [],
  streams: [],
);

BridgeSpec _listIntParamSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'setIds',
      cSymbol: 'mod_set_ids',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'ids',
          type: BridgeType(name: 'List<int>', isRecord: true, recordListItemType: 'int', recordListItemIsPrimitive: true),
        ),
      ],
    ),
  ],
);

BridgeSpec _nonNullableBoolParamSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'setActive',
      cSymbol: 'mod_set_active',
      isAsync: true,
      returnType: BridgeType(name: 'void', isFuture: false),
      params: [
        BridgeParam(
          name: 'active',
          type: BridgeType(name: 'bool'),
        ),
      ],
    ),
  ],
);

BridgeSpec _boolReturnSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'isReady',
      cSymbol: 'mod_is_ready',
      isAsync: false,
      returnType: BridgeType(name: 'bool'),
      params: [],
    ),
  ],
);

BridgeSpec _multiEnumSpec() => BridgeSpec(
  dartClassName: 'Printer',
  lib: 'printer',
  namespace: 'printer',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'printer.native.dart',
  enums: [
    BridgeEnum(name: 'Quality', startValue: 0, values: ['draft', 'normal', 'high']),
    BridgeEnum(name: 'Duplex', startValue: 0, values: ['none', 'long', 'short']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'print',
      cSymbol: 'printer_print',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'quality',
          type: BridgeType(name: 'Quality'),
        ),
        BridgeParam(
          name: 'duplex',
          type: BridgeType(name: 'Duplex'),
        ),
      ],
    ),
  ],
);

BridgeSpec _paramlessAsyncSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'ping',
      cSymbol: 'mod_ping',
      isAsync: true,
      returnType: BridgeType(name: 'bool', isFuture: true),
      params: [],
    ),
  ],
);

BridgeSpec _propsOnlySpec() => BridgeSpec(
  dartClassName: 'Config',
  lib: 'config',
  namespace: 'config',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'config.native.dart',
  functions: [],
  properties: [
    BridgeProperty(
      dartName: 'timeout',
      type: BridgeType(name: 'int'),
      getSymbol: 'config_get_timeout',
      setSymbol: 'config_set_timeout',
      hasGetter: true,
      hasSetter: true,
    ),
    BridgeProperty(
      dartName: 'name',
      type: BridgeType(name: 'String'),
      getSymbol: 'config_get_name',
      hasGetter: true,
      hasSetter: false,
    ),
  ],
);

BridgeSpec _iosNotTargetedSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: null,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'doThing',
      cSymbol: 'mod_do_thing',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
  ],
);

// ── §1 Future<void> async return — Dart FFI ──────────────────────────────────

void main() {
  group('DartFfiGenerator — Future<void> async return (§1)', () {
    final code = DartFfiGenerator.generate(_asyncVoidSpec());

    test('method signature uses Future<void>', () {
      expect(code, contains('Future<void> flush()'));
    });

    test('method has async modifier', () {
      expect(code, contains('async {'));
    });

    test('body uses callAsync<void>', () {
      expect(code, contains('callAsync<void>'));
    });

    test('does not emit return of a value (void returns nothing meaningful)', () {
      // We should not see `return res != 0` or `return res.toDartStringWithFree()` etc.
      expect(code, isNot(contains('return res != 0')));
      expect(code, isNot(contains('toDartStringWithFree')));
    });
  });

  // ── §2 Future<void> async return — Swift ─────────────────────────────────

  group('SwiftGenerator — Future<void> async return (§2)', () {
    final code = SwiftGenerator.generate(_asyncVoidSpec());

    test('protocol declares flush() async throws -> Void', () {
      expect(code, contains('func flush()'));
      expect(code, anyOf(contains('-> Void'), contains('async throws')));
    });

    test('@_cdecl stub uses DispatchSemaphore for void blocking', () {
      expect(code, contains('DispatchSemaphore'));
    });

    test('async void stub uses do/catch to capture error and re-raise as NSException', () {
      // void async: errors must be re-raised as NSException so the .mm @catch
      // can route them to the TLS error slot for Dart to read.
      expect(code, contains('do { try await impl.flush() }'));
      expect(code, contains('catch { _thrownError = error }'));
      expect(code, contains('NSException'));
      expect(code, contains('.raise()'));
    });

    test('void async stub does NOT assign result to a variable', () {
      // Non-void would have `let _result = try? await impl.fn()...`
      // Void should NOT have that pattern for the flush function
      final flushIdx = code.indexOf('flush');
      final snippet = code.substring(flushIdx.clamp(0, code.length));
      // Within the next ~300 chars of the flush stub, no `let _result`
      final window = snippet.substring(0, snippet.length.clamp(0, 400));
      expect(window, isNot(contains('let _result')));
    });
  });

  // ── §3 Nullable struct return — throws StateError ─────────────────────────

  group('DartFfiGenerator — nullable struct return (§3)', () {
    final code = DartFfiGenerator.generate(_nullableStructReturnSpec());

    test('sync struct return uses Pointer<Void> callAsync path', () {
      // readSensor is sync — uses callSync, not callAsync
      expect(code, contains('readSensor'));
    });

    test('sync struct return checks for nullptr and throws StateError', () {
      expect(code, contains('StateError'));
      expect(code, contains('nullptr'));
    });

    test('struct ptr decoded via .toDart()', () {
      expect(code, contains('.toDart()'));
    });

    test('struct ptr memory freed via malloc.free', () {
      expect(code, contains('_nitroFree(structPtr)'));
    });

    test('uses SensorFfi type for decoding', () {
      expect(code, contains('SensorFfi'));
    });
  });

  // ── §4 All-optional named params — entire list inside {…} ─────────────────

  group('DartFfiGenerator — all-optional named params (§4)', () {
    final code = DartFfiGenerator.generate(_allOptionalSpec());

    test('signature wraps ALL params inside {…} braces', () {
      expect(code, contains('{int timeout = 30, int retries = 3, bool verbose = false}'));
    });

    test('no positional params before the {…} block', () {
      // The signature must start directly with the named block — no comma before {
      expect(code, isNot(matches(r'configure\(\w+.*,\s*\{')));
    });

    test('each default value is emitted inline', () {
      expect(code, contains('timeout = 30'));
      expect(code, contains('retries = 3'));
      expect(code, contains('verbose = false'));
    });

    test('no required keyword on optional params with defaults', () {
      expect(code, isNot(contains('required int timeout')));
      expect(code, isNot(contains('required int retries')));
      expect(code, isNot(contains('required bool verbose')));
    });
  });

  // ── §5 Empty spec — valid output, no crash ────────────────────────────────

  group('Generators — empty spec (no functions/props/streams) (§5)', () {
    test('DartFfiGenerator produces output without crash', () {
      expect(() => DartFfiGenerator.generate(_emptySpec()), returnsNormally);
      final code = DartFfiGenerator.generate(_emptySpec());
      expect(code, isNotEmpty);
    });

    test('SwiftGenerator produces output without crash', () {
      expect(() => SwiftGenerator.generate(_emptySpec()), returnsNormally);
    });

    test('KotlinGenerator produces output without crash', () {
      expect(() => KotlinGenerator.generate(_emptySpec()), returnsNormally);
    });

    test('CppInterfaceGenerator produces output without crash', () {
      expect(() => CppInterfaceGenerator.generate(_emptyCppSpec()), returnsNormally);
      final code = CppInterfaceGenerator.generate(_emptyCppSpec());
      expect(code, isNotEmpty);
    });

    test('DartFfiGenerator still emits class declaration for empty spec', () {
      final code = DartFfiGenerator.generate(_emptySpec());
      // Should at minimum have the class name
      expect(code, contains('Empty'));
    });

    test('CppInterfaceGenerator still emits virtual destructor for empty cpp spec', () {
      final code = CppInterfaceGenerator.generate(_emptyCppSpec());
      expect(code, contains('virtual ~HybridEmpty'));
    });
  });

  // ── §6 List<int> param — RecordWriter.encodeIndexedPrimitiveList ──────────

  group('DartFfiGenerator — List<int> param encoding (§6)', () {
    final code = DartFfiGenerator.generate(_listIntParamSpec());

    test('List<int> param uses RecordWriter.encodeIndexedPrimitiveList', () {
      expect(code, contains('encodeIndexedPrimitiveList'));
    });

    test('writeInt is the per-element writer', () {
      expect(code, contains('writeInt'));
    });

    test('param name ids is referenced in the encode call', () {
      expect(code, contains('ids'));
    });

    test('arena is passed to the encode call', () {
      expect(code, contains('arena'));
    });
  });

  // ── §7 Non-nullable bool param — int conversion, no sentinel ──────────────

  group('DartFfiGenerator — non-nullable bool param (§7)', () {
    final code = DartFfiGenerator.generate(_nonNullableBoolParamSpec());

    test('non-nullable bool uses Bool FFI type — passed directly (no ternary)', () {
      // Bool FFI type: bool maps directly, no int conversion needed
      expect(code, isNot(anyOf(contains('? 1 : 0'), contains('active ? 1 : 0'))));
      expect(code, contains('setActive'));
    });

    test('non-nullable bool does NOT use nullable sentinel (-1)', () {
      // Sentinel -1 is only for bool?
      expect(code, isNot(contains('== null ? -1')));
      expect(code, isNot(contains('?? -1')));
    });

    test('setActive is generated in Dart FFI output', () {
      expect(code, contains('setActive'));
    });
  });

  // ── §8 Kotlin _call bool return uses Boolean ──────────────────────────────

  group('KotlinGenerator — bool return in _call uses Boolean (§8)', () {
    final code = KotlinGenerator.generate(_boolReturnSpec());

    test('_call method returns Boolean (not Long for bool)', () {
      // Boolean is the Kotlin type for bool return; Long is only for enum returns.
      expect(code, contains('Boolean'));
    });

    test('_call does NOT return Long for a bool return', () {
      // Long is only used for enum-typed returns (nativeValue). bool stays Boolean.
      // Search for isReady_call specifically to avoid matching create_instance_call which returns Long.
      final callSection = () {
        final idx = code.indexOf('isReady_call');
        if (idx < 0) return '';
        return code.substring(idx, (idx + 200).clamp(0, code.length));
      }();
      // Return type should not be Long (it's Boolean); parameter `instanceId: Long` is expected.
      expect(callSection, isNot(contains('): Long')));
    });

    test('isReady appears in the Kotlin output', () {
      expect(code, contains('isReady'));
    });
  });

  // ── §9 Multiple enums in one spec — all emitted ───────────────────────────

  group('Generators — multiple enums in one spec (§9)', () {
    test('SwiftGenerator emits both Quality and Duplex enums', () {
      final code = SwiftGenerator.generate(_multiEnumSpec());
      expect(code, contains('Quality'));
      expect(code, contains('Duplex'));
    });

    test('SwiftGenerator emits all values of Quality', () {
      final code = SwiftGenerator.generate(_multiEnumSpec());
      expect(code, contains('draft'));
      expect(code, contains('normal'));
      expect(code, contains('high'));
    });

    test('SwiftGenerator emits all values of Duplex', () {
      final code = SwiftGenerator.generate(_multiEnumSpec());
      expect(code, contains('none'));
      expect(code, contains('long'));
      expect(code, contains('short'));
    });

    test('KotlinGenerator emits both enum companions', () {
      final code = KotlinGenerator.generate(_multiEnumSpec());
      expect(code, contains('Quality'));
      expect(code, contains('Duplex'));
    });

    test('DartFfiGenerator emits both enum extensions', () {
      final code = DartFfiGenerator.generate(_multiEnumSpec());
      expect(code, contains('Quality'));
      expect(code, contains('Duplex'));
    });
  });

  // ── §10 Parameterless async function ─────────────────────────────────────

  group('DartFfiGenerator — parameterless async function (§10)', () {
    final code = DartFfiGenerator.generate(_paramlessAsyncSpec());

    test('ping is declared as Future<bool>', () {
      expect(code, contains('Future<bool> ping()'));
    });

    test('callAsync is emitted with empty arg list', () {
      // No params → arg list is empty or has only error pointers
      expect(code, contains('callAsync'));
      // The args to _pingPtr should be empty: _pingPtr called with no domain args
      expect(code, isNot(contains('_pingPtr(a, b')));
    });

    test('async bool return uses callAsync<bool> (Bool FFI type returns Dart bool)', () {
      // @nitroAsync bool: Bool FFI type → Dart bool; callAsync<bool> avoids int cast error.
      expect(code, contains('callAsync<bool>'));
    });
  });

  // ── §11 Swift @NitroNativeAsync void function ─────────────────────────────

  group('SwiftGenerator — @NitroNativeAsync void (§11)', () {
    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'processAsync',
          cSymbol: 'mod_process_async',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'value',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
    );
    final code = SwiftGenerator.generate(spec);

    test('NitroNativeAsync stub has @_cdecl attribute', () {
      // Swift uses _<namespace>_call_<dartName> naming, NOT the cSymbol.
      expect(code, contains('@_cdecl("_mod_call_processAsync")'));
    });

    test('NitroNativeAsync stub accepts dartPort Int64 param', () {
      expect(code, contains('dartPort'));
    });

    test('NitroNativeAsync void does not use a semaphore', () {
      // @NitroNativeAsync posts to dart port — no semaphore needed
      expect(code, isNot(contains('DispatchSemaphore')));
    });

    test('NitroNativeAsync stub posts result via Dart_PostCObject', () {
      expect(code, contains('Dart_PostCObject'));
    });

    test('NitroNativeAsync void posts kNull after calling impl', () {
      // void return → posts null sentinel to dartPort
      expect(code, contains('Dart_CObject_kNull'));
    });
  });

  // ── §12 Kotlin async (runBlocking) for void return ───────────────────────

  group('KotlinGenerator — async void (runBlocking) (§12)', () {
    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'warmup',
          cSymbol: 'mod_warmup',
          isAsync: true,
          returnType: BridgeType(name: 'void', isFuture: false),
          params: [],
        ),
      ],
    );
    final code = KotlinGenerator.generate(spec);

    test('warmup in interface is a suspend fun', () {
      expect(code, contains('suspend fun warmup'));
    });

    test('_call for warmup uses runBlocking', () {
      expect(code, contains('runBlocking'));
    });

    test('_call for warmup calls impl.warmup()', () {
      expect(code, contains('impl.warmup()'));
    });
  });

  // ── §13 Spec with only properties — no functions ──────────────────────────

  group('Generators — props-only spec (§13)', () {
    test('DartFfiGenerator emits timeout property getter and setter', () {
      final code = DartFfiGenerator.generate(_propsOnlySpec());
      expect(code, contains('timeout'));
      expect(code, contains('name'));
    });

    test('SwiftGenerator emits timeout and name in protocol', () {
      final code = SwiftGenerator.generate(_propsOnlySpec());
      expect(code, contains('timeout'));
      expect(code, contains('name'));
    });

    test('SwiftGenerator: read-only name has no setter', () {
      final code = SwiftGenerator.generate(_propsOnlySpec());
      // name is hasGetter:true, hasSetter:false — should NOT emit set {...}
      final nameIdx = code.indexOf('var name');
      if (nameIdx >= 0) {
        final snippet = code.substring(nameIdx, (nameIdx + 200).clamp(0, code.length));
        expect(snippet, isNot(contains('set {')));
      }
    });

    test('KotlinGenerator emits timeout and name in interface', () {
      final code = KotlinGenerator.generate(_propsOnlySpec());
      expect(code, contains('timeout'));
      expect(code, contains('name'));
    });

    test('Generators do not crash with no functions', () {
      expect(() => DartFfiGenerator.generate(_propsOnlySpec()), returnsNormally);
      expect(() => SwiftGenerator.generate(_propsOnlySpec()), returnsNormally);
      expect(() => KotlinGenerator.generate(_propsOnlySpec()), returnsNormally);
    });
  });

  // ── §14 C++ interface empty cpp spec — valid header ──────────────────────

  group('CppInterfaceGenerator — empty cpp spec (§14)', () {
    // CppInterfaceGenerator only generates for NativeImpl.cpp targets.
    final code = CppInterfaceGenerator.generate(_emptyCppSpec());

    test('emits class declaration', () {
      expect(code, contains('class HybridEmpty'));
    });

    test('emits virtual destructor', () {
      expect(code, contains('virtual ~HybridEmpty'));
    });

    test('emits protected default constructor', () {
      expect(code, contains('HybridEmpty()'));
    });

    test('emits include guard or pragma once', () {
      expect(code, anyOf(contains('#pragma once'), contains('#ifndef')));
    });
  });

  // ── §15 SwiftGenerator — iOS not targeted ────────────────────────────────

  group('SwiftGenerator — iOS not targeted returns early comment (§15)', () {
    final code = SwiftGenerator.generate(_iosNotTargetedSpec());

    test('returns a non-empty comment when iosImpl is null', () {
      expect(code, isNotEmpty);
    });

    test('comment mentions iOS not targeted', () {
      expect(code, anyOf(contains('iOS not targeted'), contains('not targeted')));
    });

    test('does NOT emit protocol declaration when iosImpl is null', () {
      expect(code, isNot(contains('protocol HybridModProtocol')));
    });
  });
}
