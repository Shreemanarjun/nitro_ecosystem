// Tests for all new validator rules added in the nitro-generator improvements:
//   E003 — nested Map<String, Map<...>>
//   E004 — Stream<T> as a property type
//   E005 — Backpressure.batch with non-numeric item type
//   E006 — batchMaxSize <= 0
//   W005 — Map<String, @HybridRecord> in stream item type (Android not type-safe)
//   W006 — Map<String, @HybridRecord> return type (Android not type-safe)
//   Improved E001 hint for non-String Map keys (includes integer encoding hint)
//   Improved INVALID_ZERO_COPY_RETURN hint when combined with @NitroNativeAsync

import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ────────────────────────────────────────────────────────────────────

BridgeSpec _fn({
  required String returnTypeName,
  bool isMap = false,
  bool isRecord = false,
  bool zeroCopyReturn = false,
  bool isNativeAsync = false,
  List<BridgeParam> params = const [],
}) {
  return BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'mod.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'fn',
        cSymbol: 'mod_fn',
        isAsync: false,
        isNativeAsync: isNativeAsync,
        returnType: BridgeType(name: returnTypeName, isMap: isMap, isRecord: isRecord),
        zeroCopyReturn: zeroCopyReturn,
        params: params,
      ),
    ],
  );
}

BridgeSpec _prop({required String typeName, bool isStream = false}) {
  return BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'mod.native.dart',
    properties: [
      BridgeProperty(
        dartName: 'val',
        getSymbol: 'mod_get_val',
        setSymbol: 'mod_set_val',
        type: BridgeType(name: typeName, isStream: isStream),
        hasGetter: true,
        hasSetter: false,
      ),
    ],
  );
}

BridgeSpec _stream({
  required String itemTypeName,
  Backpressure backpressure = Backpressure.dropLatest,
  int batchMaxSize = 64,
  bool isMap = false,
  bool isRecord = false,
}) {
  return BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'mod.native.dart',
    streams: [
      BridgeStream(
        dartName: 'items',
        registerSymbol: 'mod_register_items_stream',
        releaseSymbol: 'mod_release_items_stream',
        isMethodStyle: false,
        isAnnotated: true,
        backpressure: backpressure,
        batchMaxSize: batchMaxSize,
        itemType: BridgeType(name: itemTypeName, isMap: isMap, isRecord: isRecord),
      ),
    ],
  );
}

// ── E003: Nested Map ────────────────────────────────────────────────────────────

void main() {
  group('E003 — nested Map<String, Map<...>>', () {
    test('return type Map<String, Map<String, int>> emits E003 error', () {
      final spec = _fn(
        returnTypeName: 'Map<String, Map<String, int>>',
        isMap: true,
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E003' && i.isError), isTrue,
          reason: 'Nested Map return type must be rejected');
    });

    test('return type Map<String, int> (flat) does NOT emit E003', () {
      final spec = _fn(returnTypeName: 'Map<String, int>', isMap: true, isRecord: true);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E003'), isFalse,
          reason: 'Flat Map<String, V> is valid and must not trigger E003');
    });

    test('parameter Map<String, Map<String, String>> emits E003 error', () {
      final spec = _fn(
        returnTypeName: 'void',
        params: [
          BridgeParam(
            name: 'data',
            type: BridgeType(name: 'Map<String, Map<String, String>>', isMap: true, isRecord: true),
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E003' && i.isError), isTrue,
          reason: 'Nested Map parameter must be rejected');
    });

    test('E003 hint mentions @HybridRecord wrapper as fix', () {
      final spec = _fn(returnTypeName: 'Map<String, Map<String, int>>', isMap: true);
      final issues = SpecValidator.validate(spec);
      final e003 = issues.firstWhere((i) => i.code == 'E003');
      expect(e003.hint, contains('@HybridRecord'));
    });

    test('deeply nested Map<String, Map<String, Map<...>>> also emits E003', () {
      final spec = _fn(returnTypeName: 'Map<String, Map<String, Map<String, bool>>>', isMap: true);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E003' && i.isError), isTrue);
    });
  });

  // ── E004: Stream<T> as property type ─────────────────────────────────────────

  group('E004 — Stream<T> as property type', () {
    test('property type Stream<int> emits E004 error', () {
      final spec = _prop(typeName: 'Stream<int>', isStream: true);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E004' && i.isError), isTrue,
          reason: 'Stream-typed property must be rejected');
    });

    test('property type int (non-stream) does NOT emit E004', () {
      final spec = _prop(typeName: 'int');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E004'), isFalse);
    });

    test('property type String does NOT emit E004', () {
      final spec = _prop(typeName: 'String');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E004'), isFalse);
    });

    test('E004 hint tells user to declare a getter directly on the abstract class', () {
      final spec = _prop(typeName: 'Stream<int>', isStream: true);
      final issues = SpecValidator.validate(spec);
      final e4 = issues.firstWhere((i) => i.code == 'E004');
      expect(e4.hint, contains('getter'));
    });
  });

  // ── E005: Backpressure.batch with non-numeric types ───────────────────────────

  group('E005 — Backpressure.batch only for int/double/bool', () {
    test('batch int stream is valid (no E005)', () {
      final spec = _stream(itemTypeName: 'int', backpressure: Backpressure.batch);
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E005'), isFalse);
    });

    test('batch double stream is valid (no E005)', () {
      final spec = _stream(itemTypeName: 'double', backpressure: Backpressure.batch);
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E005'), isFalse);
    });

    test('batch bool stream is valid (no E005)', () {
      final spec = _stream(itemTypeName: 'bool', backpressure: Backpressure.batch);
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E005'), isFalse);
    });

    test('batch String stream emits E005 error', () {
      final spec = _stream(itemTypeName: 'String', backpressure: Backpressure.batch);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E005' && i.isError), isTrue,
          reason: 'Backpressure.batch on String streams must be rejected — batch protocol uses Int64 array');
    });

    test('batch @HybridRecord stream emits E005 error', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: [BridgeRecordType(name: 'Event', fields: [])],
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'mod_register_events_stream',
            releaseSymbol: 'mod_release_events_stream',
            isMethodStyle: false,
            isAnnotated: true,
            backpressure: Backpressure.batch,
            batchMaxSize: 64,
            itemType: BridgeType(name: 'Event', isRecord: true),
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E005' && i.isError), isTrue,
          reason: 'Backpressure.batch on @HybridRecord streams must be rejected');
    });

    test('batch enum stream emits E005 error', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['a', 'b'])],
        streams: [
          BridgeStream(
            dartName: 'statuses',
            registerSymbol: 'mod_register_statuses_stream',
            releaseSymbol: 'mod_release_statuses_stream',
            isMethodStyle: false,
            isAnnotated: true,
            backpressure: Backpressure.batch,
            batchMaxSize: 64,
            itemType: BridgeType(name: 'Status'),
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E005' && i.isError), isTrue,
          reason: 'Backpressure.batch on enum streams must be rejected');
    });

    test('E005 hint mentions dropLatest / dropOldest as alternatives', () {
      final spec = _stream(itemTypeName: 'String', backpressure: Backpressure.batch);
      final issues = SpecValidator.validate(spec);
      final e5 = issues.firstWhere((i) => i.code == 'E005');
      expect(e5.hint, contains('dropLatest'));
    });

    test('dropLatest String stream is valid (no E005)', () {
      final spec = _stream(itemTypeName: 'String', backpressure: Backpressure.dropLatest);
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E005'), isFalse);
    });

    test('block double stream is valid (no E005)', () {
      final spec = _stream(itemTypeName: 'double', backpressure: Backpressure.block);
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E005'), isFalse);
    });
  });

  // ── E006: batchMaxSize <= 0 ───────────────────────────────────────────────────

  group('E006 — batchMaxSize must be positive', () {
    test('batchMaxSize = 0 emits E006 error', () {
      final spec = _stream(
        itemTypeName: 'int',
        backpressure: Backpressure.batch,
        batchMaxSize: 0,
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E006' && i.isError), isTrue,
          reason: 'batchMaxSize = 0 would cause the flush to fire on every item, not a batch');
    });

    test('batchMaxSize = -1 emits E006 error', () {
      final spec = _stream(
        itemTypeName: 'int',
        backpressure: Backpressure.batch,
        batchMaxSize: -1,
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E006' && i.isError), isTrue);
    });

    test('batchMaxSize = 1 is valid (no E006) — flushes after every single item', () {
      final spec = _stream(
        itemTypeName: 'int',
        backpressure: Backpressure.batch,
        batchMaxSize: 1,
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E006'), isFalse);
    });

    test('batchMaxSize = 64 is valid (no E006)', () {
      final spec = _stream(
        itemTypeName: 'int',
        backpressure: Backpressure.batch,
        batchMaxSize: 64,
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E006'), isFalse);
    });

    test('E006 is only emitted when backpressure is batch', () {
      // batchMaxSize field exists on non-batch streams but should not be validated there.
      final spec = _stream(
        itemTypeName: 'int',
        backpressure: Backpressure.dropLatest,
        batchMaxSize: 0,
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E006'), isFalse,
          reason: 'batchMaxSize is only relevant for Backpressure.batch');
    });
  });

  // ── E001 improved hint ────────────────────────────────────────────────────────

  group('E001 improved hint — non-String Map keys', () {
    test('Map<int, V> return emits E001 with integer-encoding hint', () {
      final spec = _fn(returnTypeName: 'Map<int, String>');
      final issues = SpecValidator.validate(spec);
      final e1 = issues.firstWhere((i) => i.code == 'E001', orElse: () => throw 'no E001');
      expect(e1.hint, contains('toString()'),
          reason: 'Hint should suggest encoding int key as String');
    });

    test('Map<int, V> parameter emits E001 with integer-encoding hint', () {
      final spec = _fn(
        returnTypeName: 'void',
        params: [
          BridgeParam(
            name: 'data',
            type: BridgeType(name: 'Map<int, double>'),
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final e1 = issues.firstWhere((i) => i.code == 'E001', orElse: () => throw 'no E001');
      expect(e1.hint, contains('toString()'));
    });

    test('Map<String, V> does NOT emit E001', () {
      final spec = _fn(returnTypeName: 'Map<String, int>', isMap: true, isRecord: true);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E001'), isFalse);
    });
  });

  // ── INVALID_ZERO_COPY_RETURN improved hint ────────────────────────────────────

  group('INVALID_ZERO_COPY_RETURN — improved hint for @zeroCopy + @NitroNativeAsync', () {
    test('zeroCopy + isNativeAsync emits INVALID_ZERO_COPY_RETURN with workaround hint', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getBuffer',
            cSymbol: 'mod_get_buffer',
            isAsync: false,
            isNativeAsync: true,
            zeroCopyReturn: true,
            returnType: BridgeType(name: 'Uint8List'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final issue = issues.firstWhere(
        (i) => i.code == 'INVALID_ZERO_COPY_RETURN' && i.isError,
        orElse: () => throw 'expected INVALID_ZERO_COPY_RETURN error',
      );
      // The improved hint should mention the workaround pattern.
      expect(issue.hint, contains('synchronous'));
      expect(issue.hint, contains('@nitroAsync'));
    });

    test('hint mentions one-copy safe alternative', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getBuffer',
            cSymbol: 'mod_get_buffer',
            isAsync: false,
            isNativeAsync: true,
            zeroCopyReturn: true,
            returnType: BridgeType(name: 'Uint8List'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final issue = issues.firstWhere((i) => i.code == 'INVALID_ZERO_COPY_RETURN' && i.isError);
      expect(issue.hint, contains('Uint8List'));
    });
  });

  // ── Swift batch item → no force-cast ─────────────────────────────────────────

  group('Swift generator batch stream — no force-cast for int', () {
    test('int batch stream does not emit "item as! Int64" force-cast', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        streams: [
          BridgeStream(
            dartName: 'values',
            registerSymbol: 'mod_register_values_stream',
            releaseSymbol: 'mod_release_values_stream',
            isMethodStyle: false,
            isAnnotated: true,
            backpressure: Backpressure.batch,
            batchMaxSize: 16,
            itemType: BridgeType(name: 'int'),
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // item is already Int64 from AnyPublisher<Int64, Never>; no force-cast needed.
      expect(out, isNot(contains('item as! Int64')),
          reason: 'Force-cast "as! Int64" generates a Swift compiler warning; use direct append instead');
      expect(out, contains('_buf.append(item)'));
    });

    test('double batch stream still uses bitPattern conversion', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        streams: [
          BridgeStream(
            dartName: 'values',
            registerSymbol: 'mod_register_values_stream',
            releaseSymbol: 'mod_release_values_stream',
            isMethodStyle: false,
            isAnnotated: true,
            backpressure: Backpressure.batch,
            batchMaxSize: 16,
            itemType: BridgeType(name: 'double'),
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('Int64(bitPattern: item.bitPattern)'));
    });

    test('bool batch stream uses ternary encoding', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        streams: [
          BridgeStream(
            dartName: 'flags',
            registerSymbol: 'mod_register_flags_stream',
            releaseSymbol: 'mod_release_flags_stream',
            isMethodStyle: false,
            isAnnotated: true,
            backpressure: Backpressure.batch,
            batchMaxSize: 16,
            itemType: BridgeType(name: 'bool'),
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('item ? 1 : 0'));
    });
  });

  // ── Swift callback String return type ────────────────────────────────────────

  group('Swift callback String return type — bidirectional', () {
    test('callback returning String: C ptr return type is UnsafeMutablePointer<CChar>?', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'transform',
            cSymbol: 'mod_transform',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'fn',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'String',
                  functionParams: [BridgeType(name: 'int')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // Return type in @convention(c) must be UnsafeMutablePointer<CChar>? (malloc'd C string).
      expect(out, contains('@convention(c) (Int64) -> UnsafeMutablePointer<CChar>?'));
    });

    test('callback returning String: wrapper converts C malloc ptr to Swift String', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'transform',
            cSymbol: 'mod_transform',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'fn',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'String',
                  functionParams: [BridgeType(name: 'int')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // Wrapper calls C ptr; C returns malloc'd char*; wrapper converts to Swift String + frees.
      expect(out, contains('String(cString:'));
      expect(out, contains('free('));
    });

    test('callback returning double: wrapper decodes Int64 bit pattern to Double', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'compute',
            cSymbol: 'mod_compute',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'fn',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'double',
                  functionParams: [BridgeType(name: 'int')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // C returns Int64 bit-pattern; wrapper re-interprets as Double.
      expect(out, contains('Double(bitPattern: UInt64(bitPattern:'));
    });

    test('callback returning bool: wrapper converts Int8 != 0 to Bool', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'check',
            cSymbol: 'mod_check',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'fn',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'bool',
                  functionParams: [BridgeType(name: 'int')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('!= 0'));
    });
  });

  // ── String callback param — lifetime safety ───────────────────────────────────

  group('Swift String callback param — conversion and edge cases', () {
    test('String param uses (arg as NSString).utf8String for C ABI conversion', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'log',
            cSymbol: 'mod_log',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'handler',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'void',
                  functionParams: [BridgeType(name: 'String')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // The wrapper receives a Swift String from the impl and converts to const char*.
      expect(out, contains('(arg0 as NSString).utf8String'));
      // Must NOT use String(cString:) here — that would be for the other direction.
      expect(out, isNot(contains('String(cString: arg0)')));
    });

    test('String param in @convention(c) uses UnsafePointer<CChar>?', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'log',
            cSymbol: 'mod_log',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'handler',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'void',
                  functionParams: [BridgeType(name: 'String')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('@convention(c) (UnsafePointer<CChar>?) -> Void'));
    });

    test('String param does not use Int64 in @convention(c)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'log',
            cSymbol: 'mod_log',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'handler',
                type: BridgeType(
                  name: 'Function',
                  isFunction: true,
                  functionReturnType: 'void',
                  functionParams: [BridgeType(name: 'String')],
                ),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // String must NOT use the integer-register path; it needs a pointer register.
      expect(out, isNot(contains('@convention(c) (Int64) -> Void')));
    });
  });

  // ── E007: Map<String, @HybridEnum> ─────────────────────────────────────────

  group('E007 — Map<String, @HybridEnum> return/param', () {
    BridgeSpec _mapEnumFn({bool isReturn = true}) {
      final enumSpec = BridgeEnum(name: 'State', startValue: 0, values: ['ok', 'err']);
      final mapType = BridgeType(name: 'Map<String, State>', isMap: true, isRecord: true);
      return BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [enumSpec],
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            returnType: isReturn ? mapType : BridgeType(name: 'void'),
            params: isReturn ? [] : [BridgeParam(name: 'p', type: mapType)],
            isAsync: false,
            isNativeAsync: false,
          ),
        ],
      );
    }

    test('Map<String, @HybridEnum> return type emits E007', () {
      final issues = SpecValidator.validate(_mapEnumFn(isReturn: true));
      expect(issues.any((i) => i.code == 'E007' && i.isError), isTrue,
          reason: 'Map<String, @HybridEnum> return must be rejected with E007');
    });

    test('Map<String, @HybridEnum> parameter type emits E007', () {
      final issues = SpecValidator.validate(_mapEnumFn(isReturn: false));
      expect(issues.any((i) => i.code == 'E007' && i.isError), isTrue,
          reason: 'Map<String, @HybridEnum> param must be rejected with E007');
    });

    test('Map<String, int> does NOT emit E007', () {
      final spec = _fn(returnTypeName: 'Map<String, int>', isMap: true, isRecord: true);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E007'), isFalse,
          reason: 'Map<String, int> is a valid type');
    });
  });

  // ── E008: Map<String, @HybridStruct> ───────────────────────────────────────

  group('E008 — Map<String, @HybridStruct> return/param', () {
    BridgeSpec _mapStructFn({bool isReturn = true}) {
      final structSpec = BridgeStruct(name: 'Point', packed: false, fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double'), isNamed: true),
        BridgeField(name: 'y', type: BridgeType(name: 'double'), isNamed: true),
      ]);
      final mapType = BridgeType(name: 'Map<String, Point>', isMap: true, isRecord: true);
      return BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        structs: [structSpec],
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            returnType: isReturn ? mapType : BridgeType(name: 'void'),
            params: isReturn ? [] : [BridgeParam(name: 'p', type: mapType)],
            isAsync: false,
            isNativeAsync: false,
          ),
        ],
      );
    }

    test('Map<String, @HybridStruct> return type emits E008', () {
      final issues = SpecValidator.validate(_mapStructFn(isReturn: true));
      expect(issues.any((i) => i.code == 'E008' && i.isError), isTrue,
          reason: 'Map<String, @HybridStruct> return must be rejected with E008');
    });

    test('Map<String, @HybridStruct> parameter type emits E008', () {
      final issues = SpecValidator.validate(_mapStructFn(isReturn: false));
      expect(issues.any((i) => i.code == 'E008' && i.isError), isTrue,
          reason: 'Map<String, @HybridStruct> param must be rejected with E008');
    });

    test('Map<String, String> does NOT emit E008', () {
      final spec = _fn(returnTypeName: 'Map<String, String>', isMap: true, isRecord: true);
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E008'), isFalse,
          reason: 'Map<String, String> is a valid type');
    });
  });

  // ── E009: Nullable stream items ─────────────────────────────────────────────

  group('E009 — nullable stream item type', () {
    test('Stream<int?> emits E009', () {
      final spec = _stream(itemTypeName: 'int?');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E009' && i.isError), isTrue,
          reason: 'Nullable stream item type must be rejected with E009');
    });

    test('Stream<String?> emits E009', () {
      final spec = _stream(itemTypeName: 'String?');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E009' && i.isError), isTrue,
          reason: 'Nullable string stream item must be rejected');
    });

    test('Stream<double?> emits E009', () {
      final spec = _stream(itemTypeName: 'double?');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E009' && i.isError), isTrue,
          reason: 'Nullable double stream item must be rejected');
    });

    test('Stream<int> (non-nullable) does NOT emit E009', () {
      final spec = _stream(itemTypeName: 'int');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E009'), isFalse,
          reason: 'Non-nullable int stream is valid');
    });

    test('Stream<String> (non-nullable) does NOT emit E009', () {
      final spec = _stream(itemTypeName: 'String');
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'E009'), isFalse,
          reason: 'Non-nullable string stream is valid');
    });
  });

  // ── Stream<String> Swift generation ────────────────────────────────────────

  group('Stream<String> — Swift generator emits kString path', () {
    test('non-batch String stream uses withCString closure in sink', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        streams: [
          BridgeStream(
            dartName: 'messages',
            registerSymbol: 'mod_register_messages_stream',
            releaseSymbol: 'mod_release_messages_stream',
            isMethodStyle: true,
            isAnnotated: true,
            backpressure: Backpressure.dropLatest,
            batchMaxSize: 64,
            itemType: BridgeType(name: 'String'),
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('withCString'),
          reason: 'String stream items must use withCString closure');
      expect(out, contains('UnsafeMutablePointer(mutating: ptr)'),
          reason: 'C string pointer must be passed to emitCb');
      expect(out, isNot(contains('emitCb(dartPort, item)')),
          reason: 'Swift String cannot be directly passed as UnsafeMutablePointer<Int8>');
    });
  });
}
