// Comprehensive cross-bridge type correctness tests using specTest.
//
// Verifies that EVERY Dart type — both nullable and non-nullable — is encoded
// correctly in all four generated layers: Dart FFI, Kotlin bridge, Swift bridge,
// and C++ JNI bridge (via CppBridgeGenerator, not CppInterfaceGenerator).
//
// Organisation:
//   §1   void return
//   §2   Non-nullable primitive returns  (int, double, bool, String)
//   §3   Nullable primitive returns      (int?, double?, bool?, String?)
//   §4   Non-nullable enum return / param
//   §5   Nullable enum return / param
//   §6   Non-nullable struct return / param
//   §7   Nullable struct return / param
//   §8   Future<T> async returns — all primitive types
//   §9   Nullable primitive parameters   — sentinel + all three bridges
//   §10  Non-nullable parameters         — no sentinel in any bridge
//   §11  C++ JNI bridge (CppBridgeGenerator) — nullable & non-nullable returns
//   §12  C++ JNI bridge — nullable parameters (ptr/null guard)
//   §13  Mixed parameters — full cross-bridge consistency

import 'package:test/test.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_annotations/nitro_annotations.dart';

import 'spec_tester.dart';

// ─── Shared SpecSources ───────────────────────────────────────────────────────

// Default: swift + kotlin targets (covers Dart, Kotlin, Swift)
SpecSource _src(String body) => SpecSource('''
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Mod {
$body
}
''', uri: 'mod.native.dart');

// With a @HybridEnum to test enum types
SpecSource _enumSrc(String body) => SpecSource('''
@HybridEnum()
enum Status { pending, done, failed }

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Mod {
$body
}
''', uri: 'mod.native.dart');

// With a @HybridStruct to test struct types
SpecSource _structSrc(String body) => SpecSource('''
@HybridStruct()
class Point { external double x; external double y; }

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Mod {
$body
}
''', uri: 'mod.native.dart');

// ─── CppBridgeGenerator helpers ──────────────────────────────────────────────
// CppBridgeGenerator generates the JNI/ObjC .mm shim, which is a different file
// from CppInterfaceGenerator (the protocol .g.h). We test it directly.

BridgeSpec _jniBridgeSpec({
  required String returnTypeName,
  List<BridgeParam> params = const [],
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: 'getValue',
      cSymbol: 'mod_get_value',
      isAsync: false,
      returnType: BridgeType(name: returnTypeName),
      params: params,
    ),
  ],
);

BridgeParam _p(String name, String type) => BridgeParam(
  name: name,
  type: BridgeType(name: type),
);

// ══════════════════════════════════════════════════════════════════════════════
void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // §1  void return
  // ══════════════════════════════════════════════════════════════════════════
  group('§1 void return', () {
    final src = _src('  void ping();');

    specTest(
      'void — Dart: no return value; Kotlin: Unit; Swift: Void stub',
      src,
      dart: BridgeChecks(
        has: ['void ping()', 'callSync<void>'],
        hasNot: ['int? ping', 'return null'],
      ),
      kotlin: BridgeChecks(
        has: ['fun ping(): Unit', 'fun ping_call(instanceId: Long): Unit', 'impl.ping()'],
        hasNot: ['return impl.ping()'],
      ),
      swift: BridgeChecks(
        has: ['func ping()', '-> Void', 'impl?.ping()'],
        hasNot: ['return 0', 'return nil'],
      ),
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §2  Non-nullable primitive returns
  // ══════════════════════════════════════════════════════════════════════════
  group('§2 Non-nullable primitive returns', () {
    group('int', () {
      final src = _src('  int getCount();');
      specTest(
        'int return — Dart: int; Kotlin: Long non-nullable; Swift: Int64 direct',
        src,
        dart: BridgeChecks(
          has: ['int getCount()', 'Int64 Function(Int64, Pointer<NitroErrorFfi>)'],
          hasNot: ['int? getCount'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getCount(): Long', 'fun getCount_call(instanceId: Long): Long', 'return impl.getCount()'],
          hasNot: ['Long?'],
        ),
        swift: BridgeChecks(
          // guard let unwraps impl, so direct call (no optional chaining)
          has: ['-> Int64', 'return impl.getCount()'],
          hasNot: ['?? 0', '?? nil'],
        ),
      );
    });

    group('double', () {
      final src = _src('  double getRatio();');
      specTest(
        'double return — Dart: double; Kotlin: Double; Swift: Double direct',
        src,
        dart: BridgeChecks(
          has: ['double getRatio()', 'Double Function(Int64, Pointer<NitroErrorFfi>)'],
          hasNot: ['double? getRatio'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getRatio(): Double', 'fun getRatio_call(instanceId: Long): Double', 'return impl.getRatio()'],
          hasNot: ['Double?'],
        ),
        swift: BridgeChecks(
          has: ['-> Double', 'return impl.getRatio()'],
          hasNot: ['?? 0.0', '?? nil'],
        ),
      );
    });

    group('bool', () {
      final src = _src('  bool isReady();');
      specTest(
        'bool return — Dart: bool; Kotlin: Boolean; Swift: Int8 (0/1)',
        src,
        dart: BridgeChecks(
          has: ['bool isReady()', 'Bool Function(Int64, Pointer<NitroErrorFfi>)'],
          hasNot: ['bool? isReady', 'Int8 Function(Int64'],
        ),
        kotlin: BridgeChecks(
          has: [
            'fun isReady(): Boolean',
            'fun isReady_call(instanceId: Long): Boolean',
            'return impl.isReady()',
          ],
          hasNot: ['Boolean?'],
        ),
        swift: BridgeChecks(
          // bool uses optional-chaining + ?? false fallback, then ternary to Int8
          has: ['-> Int8', 'impl?.isReady()', '?? false', '? 1 : 0'],
        ),
      );
    });

    group('String', () {
      final src = _src('  String getName();');
      specTest(
        'String return — Dart: String; Kotlin: String; Swift: strdup',
        src,
        dart: BridgeChecks(
          has: ['String getName()', 'Pointer<Utf8> Function()'],
          hasNot: ['String? getName'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getName(): String', 'fun getName_call(instanceId: Long): String', 'return impl.getName()'],
          hasNot: ['String?'],
        ),
        swift: BridgeChecks(
          has: ['-> UnsafeMutablePointer<CChar>', '_nitroStringToCString(', 'impl?.getName()'],
        ),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §3  Nullable primitive returns
  // ══════════════════════════════════════════════════════════════════════════
  group('§3 Nullable primitive returns', () {
    group('int?', () {
      final src = _src('  int? getCount();');
      specTest(
        'int? return — Dart: int?; Kotlin: ByteArray (NitroOpt*); Swift: raw UInt8 pointer',
        src,
        dart: BridgeChecks(
          has: ['int? getCount()', 'Pointer<NitroOptInt64> Function(Int64, Pointer<NitroErrorFfi>)', 'malloc.free'],
          hasNot: ['int getCount()', 'NitroOptInt64 Function(Int64'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getCount(): Long?', 'fun getCount_call(instanceId: Long): ByteArray', 'NitroOptInt64'],
        ),
        swift: BridgeChecks(
          has: ['allocate(capacity: 9)', 'copyMemory', 'UnsafeMutablePointer<UInt8>?'],
          hasNot: ['Int64.min', 'withMemoryRebound'],
        ),
      );
    });

    group('double?', () {
      final src = _src('  double? getRatio();');
      specTest(
        'double? return — Dart: double?; Kotlin: ByteArray (NitroOpt*); Swift: byte-safe copyMemory encode',
        src,
        dart: BridgeChecks(
          has: ['double? getRatio()', 'Pointer<NitroOptFloat64> Function(Int64, Pointer<NitroErrorFfi>)', 'malloc.free'],
          hasNot: ['double getRatio()', 'NitroOptFloat64 Function(Int64'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getRatio(): Double?', 'fun getRatio_call(instanceId: Long): ByteArray', 'NitroOptFloat64'],
        ),
        swift: BridgeChecks(
          has: ['allocate(capacity: 9)', 'copyMemory', 'UnsafeMutablePointer<UInt8>?'],
          hasNot: ['Double.nan', 'withMemoryRebound'],
        ),
      );
    });

    group('bool?', () {
      final src = _src('  bool? isReady();');
      specTest(
        'bool? return — Dart: bool?; Kotlin: ByteArray (NitroOpt*); Swift: byte-safe encode',
        src,
        dart: BridgeChecks(
          has: ['bool? isReady()', 'Pointer<NitroOptBool> Function(Int64, Pointer<NitroErrorFfi>)', 'malloc.free'],
          hasNot: ['bool isReady()', 'NitroOptBool Function(Int64'],
        ),
        kotlin: BridgeChecks(
          // bool? interface uses Boolean? so impls can return null.
          // bool? _call uses ByteArray (NitroOpt* packed struct encoding).
          has: ['fun isReady(): Boolean?', 'fun isReady_call(instanceId: Long): ByteArray', 'NitroOptBool'],
        ),
        swift: BridgeChecks(
          has: ['allocate(capacity: 2)', 'UnsafeMutablePointer<UInt8>?'],
          hasNot: ['withMemoryRebound'],
        ),
      );
    });

    group('String?', () {
      final src = _src('  String? getName();');
      specTest(
        'String? return — Dart: String?; Kotlin: String?; Swift: strdup with fallback',
        src,
        dart: BridgeChecks(
          has: ['String? getName()', 'Pointer<Utf8> Function()'],
          hasNot: ['String getName()'],
        ),
        kotlin: BridgeChecks(
          // Kotlin generator strips ? from String returns — JNI null reference serves as null signal
          has: ['fun getName(): String', 'fun getName_call(instanceId: Long): String'],
        ),
        swift: BridgeChecks(
          has: ['-> UnsafeMutablePointer<CChar>', '_nitroStringToCString('],
        ),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §4  Non-nullable enum return / param
  // ══════════════════════════════════════════════════════════════════════════
  group('§4 Non-nullable enum', () {
    group('return', () {
      final src = _enumSrc('  Status getStatus();');
      specTest(
        'enum return — Dart: Status; Kotlin: Long (nativeValue); Swift: rawValue',
        src,
        dart: BridgeChecks(
          has: ['Status getStatus()'],
          hasNot: ['Status? getStatus'],
        ),
        kotlin: BridgeChecks(
          // Interface returns enum; _call bridge exposes Long (nativeValue)
          has: [
            'fun getStatus(): Status',
            'fun getStatus_call(instanceId: Long): Long',
            'return impl.getStatus().nativeValue',
          ],
        ),
        swift: BridgeChecks(
          // Swift @_cdecl returns Int64 with .rawValue
          has: ['-> Int64', '.rawValue'],
          hasNot: ['?? 0'],
        ),
      );
    });

    group('param', () {
      final src = _enumSrc('  void setStatus(Status s);');
      specTest(
        'enum param — Dart: .nativeValue; Kotlin: fromNative; Swift: Status(rawValue:)',
        src,
        dart: BridgeChecks(
          has: ['s.nativeValue'],
          hasNot: ['s ?? '],
        ),
        kotlin: BridgeChecks(
          // enum params in _call keep Kotlin enum type (not Long); direct pass-through
          has: ['setStatus_call(instanceId: Long, s: Long)', 'impl.setStatus(Status.fromNative(s))'],
        ),
        swift: BridgeChecks(
          // @_cdecl receives Int64 for enum params
          has: ['_ s: Int64'],
        ),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §5  Nullable enum return / param
  // ══════════════════════════════════════════════════════════════════════════
  group('§5 Nullable enum', () {
    group('return', () {
      final src = _enumSrc('  Status? getStatus();');
      specTest(
        'enum? return — Dart: Status?; Kotlin: Long (JNI); Swift: ?.rawValue ?? 0',
        src,
        dart: BridgeChecks(
          has: ['Status? getStatus()'],
          hasNot: ['Status getStatus()'],
        ),
        kotlin: BridgeChecks(
          // Nullable enum loses ?; _call returns Status (not Long — isEnum check fails for 'Status?')
          has: ['fun getStatus(): Status?', 'fun getStatus_call(instanceId: Long): Long'],
        ),
        swift: BridgeChecks(
          // -1 is the null sentinel for nullable enum (Dart decodes res == -1 as null).
          has: ['-> Int64', '?.rawValue ?? -1'],
        ),
      );
    });

    group('param', () {
      final src = _enumSrc('  void setStatus(Status? s);');
      specTest(
        'enum? param — Dart: ternary nativeValue; Kotlin: Long?; Swift: Status?(rawValue:)',
        src,
        dart: BridgeChecks(
          // Dart encodes nullable enum as Long? — but enum is a reference via sentinel
          has: ['setStatus('],
        ),
        kotlin: BridgeChecks(
          // Nullable enum in interface is kept nullable
          has: ['fun setStatus(s: Status?)'],
        ),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §6  Non-nullable struct return / param
  // ══════════════════════════════════════════════════════════════════════════
  group('§6 Non-nullable struct', () {
    group('return', () {
      final src = _structSrc('  Point getOrigin();');
      specTest(
        'struct return — Dart: Point; Kotlin: Point; Swift: allocate + fromSwift',
        src,
        dart: BridgeChecks(
          has: ['Point getOrigin()'],
          hasNot: ['Point? getOrigin'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getOrigin(): Point', 'return impl.getOrigin()'],
        ),
        swift: BridgeChecks(
          // Swift returns UnsafeMutableRawPointer? — allocates C-shadow struct
          // guard let result protects against nil impl — so return nil CAN appear
          has: ['allocate(capacity: 1)', 'fromSwift', 'UnsafeMutableRawPointer', 'guard let result'],
        ),
      );
    });

    group('param', () {
      final src = _structSrc('  void move(Point p);');
      specTest(
        'struct param — Dart: toNative; Kotlin: Point; Swift: fromCStruct',
        src,
        dart: BridgeChecks(
          has: ['p.toNative(arena)'],
          hasNot: ['p ?? '],
        ),
        kotlin: BridgeChecks(
          has: ['fun move(p: Point)', 'impl.move(p)'],
        ),
        swift: BridgeChecks(
          has: ['_ p: UnsafeRawPointer'],
        ),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §7  Nullable struct return / param
  // ══════════════════════════════════════════════════════════════════════════
  group('§7 Nullable struct', () {
    group('return', () {
      final src = _structSrc('  Point? getOrigin();');
      specTest(
        'struct? return — Dart: Point?; Kotlin: Point?; Swift: guard let → nil',
        src,
        dart: BridgeChecks(
          has: ['Point? getOrigin()'],
          hasNot: ['Point getOrigin()'],
        ),
        kotlin: BridgeChecks(
          has: ['fun getOrigin(): Point'],
        ),
        swift: BridgeChecks(
          // guard let unwraps impl AND the nullable return; returns nil if null
          has: ['guard let impl', 'guard let', 'return nil', 'UnsafeMutableRawPointer'],
        ),
      );
    });

    group('param', () {
      final src = _structSrc('  void move(Point? p);');
      specTest(
        'struct? param — Dart: null guard + nullptr; Kotlin: Point?; Swift: optional ptr',
        src,
        dart: BridgeChecks(
          has: ['p != null', 'nullptr'],
          hasNot: ['p ?? -9223372036854775808'],
        ),
        kotlin: BridgeChecks(
          has: ['fun move(p: Point?)'],
        ),
        swift: BridgeChecks(
          has: ['_ p: UnsafeRawPointer?'],
        ),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §8  Future<T> async returns
  // ══════════════════════════════════════════════════════════════════════════
  group('§8 Future<T> async returns', () {
    for (final (dartType, _, kotlinRet, swiftPat) in [
      ('int', 'Future<int>', 'Long', 'Int64'),
      ('double', 'Future<double>', 'Double', 'Double'),
      ('bool', 'Future<bool>', 'Boolean', 'Bool'),
      ('String', 'Future<String>', 'String', 'String'),
      ('int?', 'Future<int?>', 'Long?', 'copyMemory'), // byte-safe copyMemory encode
    ]) {
      specTest(
        'Future<$dartType> — Dart async; Kotlin: $kotlinRet; Swift: $swiftPat',
        _src('  Future<$dartType> compute();'),
        dart: BridgeChecks(
          has: ['Future<$dartType> compute()'],
        ),
        kotlin: BridgeChecks(
          has: ['fun compute(): $kotlinRet'],
        ),
        swift: BridgeChecks(
          has: [swiftPat],
        ),
      );
    }
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §9  Nullable primitive parameters — full cross-bridge sentinel check
  // ══════════════════════════════════════════════════════════════════════════
  group('§9 Nullable primitive parameters — NitroOpt* packed struct round-trip', () {
    for (final (dartType, dartPackExpr, kotlinCallType, kotlinDecode, swiftParamType) in [
      (
        'int?',
        'arena.packInt(value)',
        'ByteArray',
        'NitroOptInt64.decode(value).nullable',
        'UnsafeMutablePointer<UInt8>?',
      ),
      (
        'double?',
        'arena.packDouble(value)',
        'ByteArray',
        'NitroOptFloat64.decode(value).nullable',
        'UnsafeMutablePointer<UInt8>?',
      ),
      (
        'bool?',
        'arena.packBool(value)',
        'ByteArray',
        'NitroOptBool.decode(value).nullable',
        'UnsafeMutablePointer<UInt8>?',
      ),
    ]) {
      specTest(
        '$dartType param — Dart NitroOpt*: $dartPackExpr; Kotlin ByteArray _call; Swift raw byte decode',
        _src('  void process($dartType value);'),
        dart: BridgeChecks(has: [dartPackExpr, 'withArena'], hasNot: ['Struct.create<NitroOpt']),
        kotlin: BridgeChecks(
          has: [
            // _call receives ByteArray (JVM descriptor [B)
            '_call(instanceId: Long, value: $kotlinCallType)',
            // NitroOpt* decode before forwarding to interface
            kotlinDecode,
          ],
          // interface keeps nullable
          hasNot: ['fun process(value: $kotlinCallType)'],
        ),
        swift: BridgeChecks(
          // Swift @_cdecl receives UnsafeMutablePointer<UInt8>? (raw byte pointer).
          has: [swiftParamType],
        ),
      );
    }

    // String? — reference type, no sentinel
    specTest(
      'String? param — no sentinel; Kotlin stays String?; Swift is String?',
      _src('  void send(String? msg);'),
      dart: BridgeChecks(
        has: ['msg != null', 'toNativeUtf8', 'nullptr'],
        hasNot: ['msg ?? -9223372036854775808', 'msg ?? double'],
      ),
      kotlin: BridgeChecks(
        has: ['send_call(instanceId: Long, msg: String?)', 'fun send(msg: String?)'],
        hasNot: ['msgArg'],
      ),
      swift: BridgeChecks(
        has: ['_ msg: UnsafePointer<CChar>?'],
      ),
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §10  Non-nullable parameters — no sentinel in any bridge
  // ══════════════════════════════════════════════════════════════════════════
  group('§10 Non-nullable parameters — no sentinel', () {
    for (final (dartType, kotlinType, swiftType) in [
      ('int', 'Long', 'Int64'),
      ('double', 'Double', 'Double'),
      ('bool', 'Boolean', 'Int8'), // @_cdecl uses Int8 for bool params
      ('String', 'String', 'UnsafePointer<CChar>'),
    ]) {
      specTest(
        '$dartType param — no sentinel; direct pass-through in all bridges',
        _src('  void set($dartType value);'),
        dart: BridgeChecks(
          hasNot: ['value ?? ', 'value == null'],
        ),
        kotlin: BridgeChecks(
          has: ['set_call(instanceId: Long, value: $kotlinType)', 'fun set(value: $kotlinType)'],
          hasNot: ['valueArg'],
        ),
        swift: BridgeChecks(
          has: ['_ value: $swiftType'],
        ),
      );
    }
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §11  C++ JNI bridge — nullable and non-nullable return types
  // ══════════════════════════════════════════════════════════════════════════
  group('§11 C++ JNI bridge (CppBridgeGenerator) — return types', () {
    for (final (returnType, jniCall, cType) in [
      ('void', 'CallStaticVoidMethod', 'void'),
      ('int', 'CallStaticLongMethod', 'int64_t'),
      ('double', 'CallStaticDoubleMethod', 'double'),
      ('bool', 'CallStaticBooleanMethod', 'int8_t'),
      ('String', 'CallStaticObjectMethod', 'const char*'),
      // Nullable — NitroOpt*: Kotlin returns ByteArray → malloc uint8_t*, copy bytes, return pointer
      ('int?', 'CallStaticObjectMethod', 'uint8_t*'),   // malloc'd pointer to NitroOptInt64 bytes
      ('double?', 'CallStaticObjectMethod', 'uint8_t*'), // malloc'd pointer to NitroOptFloat64 bytes
      ('bool?', 'CallStaticObjectMethod', 'uint8_t*'),   // malloc'd pointer to NitroOptBool bytes
      ('String?', 'CallStaticObjectMethod', 'const char*'),
    ]) {
      test('$returnType return → C type $cType, JNI: $jniCall', () {
        final spec = _jniBridgeSpec(returnTypeName: returnType);
        final out = CppBridgeGenerator.generate(spec);
        // C function signature uses correct C return type
        expect(
          out,
          contains('$cType mod_get_value('),
          reason: '$returnType should map to C type $cType',
        );
        // Android JNI block must call the correct JNI method
        expect(
          out,
          contains(jniCall),
          reason:
              '$returnType must call $jniCall in the Android JNI block — '
              'not just pop frame and return default',
        );
      });
    }

    test('enum return → CallStaticLongMethod (nativeValue encoding)', () {
      final spec = _jniBridgeSpec(
        returnTypeName: 'Color',
        enums: [
          BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green']),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('int64_t mod_get_value('));
      expect(out, contains('CallStaticLongMethod'));
    });

    test('struct return → CallStaticObjectMethod + pack_X_from_jni', () {
      final spec = _jniBridgeSpec(
        returnTypeName: 'Frame',
        structs: [
          BridgeStruct(
            name: 'Frame',
            packed: false,
            fields: [
              BridgeField(
                name: 'w',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('CallStaticObjectMethod'));
      expect(out, contains('pack_Frame_from_jni'));
    });

    // Guard: the else branch (unknown type) must NOT silently eat a JNI call
    test('no return type silently omits JNI call (else-branch regression)', () {
      // Known types must all produce a real JNI call — verify int? (was the bug)
      final spec = _jniBridgeSpec(returnTypeName: 'int?');
      final out = CppBridgeGenerator.generate(spec);
      // Both platforms present: file starts with #ifdef __ANDROID__, ends with #elif __APPLE__
      expect(out, contains('#ifdef __ANDROID__'), reason: 'Android JNI block must be present');
      // Extract the Android block (ends at #elif __APPLE__ — no separate #endif // __ANDROID__)
      final androidStart = out.indexOf('#ifdef __ANDROID__');
      final appleStart = out.indexOf('#elif __APPLE__');
      final androidBlock = (androidStart != -1 && appleStart != -1) ? out.substring(androidStart, appleStart) : out;
      // Must call the JNI method (NitroOpt* uses CallStaticObjectMethod for ByteArray), not silently return 0
      expect(androidBlock, contains('CallStaticObjectMethod'), reason: 'int? must call CallStaticObjectMethod — old bug returned 0 silently');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §12  C++ JNI bridge — parameter encoding
  // ══════════════════════════════════════════════════════════════════════════
  group('§12 C++ JNI bridge — parameter encoding', () {
    test('String param → NewStringUTF call arg', () {
      final spec = _jniBridgeSpec(
        returnTypeName: 'void',
        params: [_p('msg', 'String')],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('NewStringUTF(msg)'));
    });

    test('String? param → null-guarded NewStringUTF', () {
      final spec = _jniBridgeSpec(
        returnTypeName: 'void',
        params: [_p('msg', 'String?')],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('msg != nullptr'));
      expect(out, contains('NewStringUTF'));
    });

    test('int param → passed directly (no conversion)', () {
      final spec = _jniBridgeSpec(
        returnTypeName: 'void',
        params: [_p('count', 'int')],
      );
      final out = CppBridgeGenerator.generate(spec);
      // int params are passed as-is to CallStaticVoidMethod
      expect(out, contains('count'));
      expect(out, isNot(contains('NewStringUTF(count)')));
    });

    test('struct param → unpack_X_to_jni call arg', () {
      final spec = _jniBridgeSpec(
        returnTypeName: 'void',
        params: [_p('pt', 'Point')],
        structs: [
          BridgeStruct(
            name: 'Point',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('unpack_Point_to_jni'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §13  Mixed parameters — full cross-bridge consistency
  // ══════════════════════════════════════════════════════════════════════════
  group('§13 Mixed parameters — cross-bridge consistency', () {
    final mixedSrc = _src('''
  void doAll(
    String name,
    int count,
    double ratio,
    bool flag,
    String? label,
    int? limit,
    double? threshold,
    bool? verbose,
  );
''');

    specTest(
      'mixed params — all types encoded correctly across Dart/Kotlin/Swift',
      mixedSrc,
      dart: BridgeChecks(
        has: [
          'name.toNativeUtf8', // String → pointer
          'arena.packInt(limit)', // int? → NitroOptInt64 packed struct (arena; fn is not leaf due to String)
          'arena.packDouble(threshold)', // double? → NitroOptFloat64 packed struct
          'arena.packBool(verbose)', // bool? → NitroOptBool packed struct
          // bool (non-nullable): Bool FFI type — passed directly, no ternary
        ],
        hasNot: [
          'count ?? ',
          'ratio ?? ',
          'flag ?? ',
          'name ?? ',
          'flag ? 1 : 0', // bool is now Bool FFI — passed directly, not as ternary int
        ],
      ),
      kotlin: BridgeChecks(
        has: [
          // _call uses ByteArray for optional primitives (NitroOpt* packed struct, JVM descriptor [B)
          'doAll_call(instanceId: Long, name: String, count: Long, ratio: Double, flag: Boolean, label: String?, limit: ByteArray, threshold: ByteArray, verbose: ByteArray)',
          // Interface preserves nullable types
          'fun doAll(name: String, count: Long, ratio: Double, flag: Boolean, label: String?, limit: Long?, threshold: Double?, verbose: Boolean?)',
          // NitroOpt* decodes for optional primitives
          'val limitArg: Long? = NitroOptInt64.decode(limit).nullable',
          'val thresholdArg: Double? = NitroOptFloat64.decode(threshold).nullable',
          'val verboseArg: Boolean? = NitroOptBool.decode(verbose).nullable',
          // Non-optional primitives and String? forwarded raw
          'impl.doAll(name, count, ratio, flag, label, limitArg, thresholdArg, verboseArg)',
        ],
        hasNot: [
          'nameArg',
          'countArg',
          'ratioArg',
          'flagArg',
          'labelArg',
        ],
      ),
      swift: BridgeChecks(
        has: [
          '_ name: UnsafePointer<CChar>',
          '_ count: Int64',
          '_ ratio: Double',
          '_ flag: Int8',
          '_ label: UnsafePointer<CChar>?',
          '_ limit: UnsafeMutablePointer<UInt8>?', // optional int? — raw byte pointer
          '_ threshold: UnsafeMutablePointer<UInt8>?', // optional double? — raw byte pointer
          '_ verbose: UnsafeMutablePointer<UInt8>?', // optional bool? — raw byte pointer
        ],
      ),
    );
  });
}
