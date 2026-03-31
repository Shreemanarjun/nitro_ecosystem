import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('SpecValidator', () {
    test('valid simple spec produces no issues', () {
      expect(SpecValidator.validate(simpleSpec()), isEmpty);
    });

    test('valid enum spec produces no issues', () {
      expect(SpecValidator.validate(enumSpec()), isEmpty);
    });

    test('valid struct stream spec produces no issues', () {
      expect(SpecValidator.validate(structStreamSpec()), isEmpty);
    });

    test('unknown return type emits UNKNOWN_RETURN_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bar',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'MyUnknownType'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'UNKNOWN_RETURN_TYPE' && i.isError),
        isTrue,
      );
    });

    test('unknown parameter type emits UNKNOWN_PARAM_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bar',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'x',
                type: BridgeType(name: 'UnknownStruct'),
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'UNKNOWN_PARAM_TYPE' && i.isError),
        isTrue,
      );
    });

    test('duplicate C symbols emit DUPLICATE_SYMBOL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'a',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
          BridgeFunction(
            dartName: 'b',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'DUPLICATE_SYMBOL' && i.isError),
        isTrue,
      );
    });

    test('sync struct return emits SYNC_STRUCT_RETURN warning (not error)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Result',
            packed: false,
            fields: [
              BridgeField(
                name: 'value',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'get',
            cSymbol: 'foo_get',
            isAsync: false,
            returnType: BridgeType(name: 'Result'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final w = issues.where((i) => i.code == 'SYNC_STRUCT_RETURN').toList();
      expect(w, hasLength(1));
      expect(w.first.isError, isFalse);
    });
  });

  group('SpecValidator (edge cases)', () {
    test('empty spec is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Noop',
        lib: 'noop',
        namespace: 'noop',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'noop.native.dart',
      );
      expect(SpecValidator.validate(spec), isEmpty);
    });

    test('nullable String? return type is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'get',
            cSymbol: 'foo_get',
            isAsync: false,
            returnType: BridgeType(name: 'String?'),
            params: [],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('Uint8List parameter is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'write',
            cSymbol: 'foo_write',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'data',
                type: BridgeType(name: 'Uint8List'),
              ),
            ],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('async void return is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fire',
            cSymbol: 'foo_fire',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('@HybridRecord return type produces no errors', () {
      expect(
        SpecValidator.validate(singleRecordSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test('List<@HybridRecord> return type produces no errors', () {
      expect(
        SpecValidator.validate(recordListSpec()).where((i) => i.isError),
        isEmpty,
      );
    });
  });

  group('SpecValidator (TypedData restrictions)', () {
    test('Uint8List return type emits INVALID_RETURN_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getData',
            cSymbol: 'foo_get_data',
            isAsync: false,
            returnType: BridgeType(name: 'Uint8List'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_RETURN_TYPE' && i.isError), isTrue);
    });

    test('Float32List return type emits INVALID_RETURN_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getSamples',
            cSymbol: 'foo_get_samples',
            isAsync: false,
            returnType: BridgeType(name: 'Float32List'),
            params: [],
          ),
        ],
      );
      expect(
        SpecValidator.validate(spec).any((i) => i.code == 'INVALID_RETURN_TYPE' && i.isError),
        isTrue,
      );
    });

    test('Uint8List property emits INVALID_PROPERTY_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'buffer',
            type: BridgeType(name: 'Uint8List'),
            getSymbol: 'foo_get_buffer',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_PROPERTY_TYPE' && i.isError), isTrue);
    });

    test('Uint8List parameter is valid (not flagged)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'write',
            cSymbol: 'foo_write',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [BridgeParam(name: 'data', type: BridgeType(name: 'Uint8List'))],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });
  });

  group('SpecValidator (property and stream types)', () {
    test('unknown property type emits UNKNOWN_PROPERTY_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'UnknownConfig'),
            getSymbol: 'foo_get_config',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'UNKNOWN_PROPERTY_TYPE' && i.isError), isTrue);
    });

    test('unknown stream item type emits UNKNOWN_STREAM_ITEM_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'foo_register_events_stream',
            releaseSymbol: 'foo_release_events_stream',
            itemType: BridgeType(name: 'UnknownEvent'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'UNKNOWN_STREAM_ITEM_TYPE' && i.isError), isTrue);
    });

    test('known struct as stream item type is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(name: 'Frame', packed: false, fields: [
            BridgeField(name: 'size', type: BridgeType(name: 'int')),
          ]),
        ],
        streams: [
          BridgeStream(
            dartName: 'frames',
            registerSymbol: 'foo_register_frames_stream',
            releaseSymbol: 'foo_release_frames_stream',
            itemType: BridgeType(name: 'Frame'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('duplicate stream register symbol emits DUPLICATE_SYMBOL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'tick',
            cSymbol: 'foo_register_ticks_stream', // collides with stream symbol
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'ticks',
            registerSymbol: 'foo_register_ticks_stream',
            releaseSymbol: 'foo_release_ticks_stream',
            itemType: BridgeType(name: 'double'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'DUPLICATE_SYMBOL' && i.isError), isTrue);
    });
  });

  group('SpecValidator (struct field restrictions)', () {
    test('zeroCopy on non-TypedData field emits INVALID_ZERO_COPY error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Bad',
            packed: false,
            fields: [
              BridgeField(
                name: 'count',
                type: BridgeType(name: 'int'),
                zeroCopy: true, // invalid: int is not TypedData
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_ZERO_COPY' && i.isError), isTrue);
    });

    test('zeroCopy on Uint8List field is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Frame',
            packed: false,
            fields: [
              BridgeField(
                name: 'data',
                type: BridgeType(name: 'Uint8List'),
                zeroCopy: true,
              ),
              BridgeField(name: 'length', type: BridgeType(name: 'int')),
            ],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });
  });

  group('SpecValidator (warnings)', () {
    test('sync @HybridRecord return emits SYNC_RECORD_RETURN warning (not error)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Config',
            fields: [
              BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getConfig',
            cSymbol: 'foo_get_config',
            isAsync: false,
            returnType: BridgeType(name: 'Config', isRecord: true),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final w = issues.where((i) => i.code == 'SYNC_RECORD_RETURN').toList();
      expect(w, hasLength(1));
      expect(w.first.isError, isFalse);
    });

    test('async @HybridRecord return does NOT emit SYNC_RECORD_RETURN', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Config',
            fields: [
              BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getConfig',
            cSymbol: 'foo_get_config',
            isAsync: true,
            returnType: BridgeType(name: 'Config', isRecord: true),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'SYNC_RECORD_RETURN'), isFalse);
    });
  });

  group('SpecValidator (error messages)', () {
    test('UNKNOWN_RETURN_TYPE error includes function name and type', () {
      final spec = BridgeSpec(
        dartClassName: 'MyMod',
        lib: 'my_mod',
        namespace: 'my_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'my_mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fetchBlob',
            cSymbol: 'my_mod_fetch_blob',
            isAsync: false,
            returnType: BridgeType(name: 'Blob'),
            params: [],
          ),
        ],
      );
      final issue = SpecValidator.validate(spec).firstWhere((i) => i.code == 'UNKNOWN_RETURN_TYPE');
      expect(issue.message, contains('fetchBlob'));
      expect(issue.message, contains('Blob'));
      expect(issue.hint, isNotNull);
    });

    test('UNKNOWN_PARAM_TYPE hint is non-null', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bar',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [BridgeParam(name: 'x', type: BridgeType(name: 'GhostType'))],
          ),
        ],
      );
      final issue = SpecValidator.validate(spec).firstWhere((i) => i.code == 'UNKNOWN_PARAM_TYPE');
      expect(issue.hint, isNotNull);
      expect(issue.hint, isNotEmpty);
    });

    test('multiple errors in same spec are all reported', () {
      final spec = BridgeSpec(
        dartClassName: 'MultiErr',
        lib: 'multi_err',
        namespace: 'multi_err',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'multi_err.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'a',
            cSymbol: 'multi_err_sym',
            isAsync: false,
            returnType: BridgeType(name: 'GhostA'),
            params: [BridgeParam(name: 'x', type: BridgeType(name: 'GhostB'))],
          ),
          BridgeFunction(
            dartName: 'b',
            cSymbol: 'multi_err_sym', // duplicate symbol
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final errors = SpecValidator.validate(spec).where((i) => i.isError).toList();
      // UNKNOWN_RETURN_TYPE, UNKNOWN_PARAM_TYPE, DUPLICATE_SYMBOL
      expect(errors.length, greaterThanOrEqualTo(3));
    });
  });
}
