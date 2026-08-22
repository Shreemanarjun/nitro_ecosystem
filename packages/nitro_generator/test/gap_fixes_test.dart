// Tests for generator gap fixes:
//   Gap  9 — Non-contiguous enum values (rawValues in BridgeEnum)
//   Gap 13 — @NitroVariant as callback parameter
//   Gap 17 — @NitroVariant as Stream<T> item type
//   Gap 18 — W007 validator warning for web target + streams/NativeAsync

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/enum_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Gap 9 helpers ────────────────────────────────────────────────────────────

BridgeSpec _nonContiguousEnumSpec() => BridgeSpec(
  dartClassName: 'Brightness',
  lib: 'brightness',
  namespace: 'brightness',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'brightness.native.dart',
  // Quality: low=0, medium=50, high=100 — non-contiguous OS values
  enums: [
    BridgeEnum(
      name: 'Quality',
      startValue: 0,
      values: ['low', 'medium', 'high'],
      rawValues: [0, 50, 100],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'setQuality',
      cSymbol: 'brightness_set_quality',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'q',
          type: BridgeType(name: 'Quality'),
        ),
      ],
    ),
  ],
);

// ── Gap 13 helpers ───────────────────────────────────────────────────────────

BridgeSpec _variantCallbackSpec() => BridgeSpec(
  dartClassName: 'Processor',
  lib: 'processor',
  namespace: 'processor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'processor.native.dart',
  variants: [
    BridgeVariant(
      name: 'Event',
      cases: [
        BridgeVariantCase(
          name: 'EventClick',
          label: 'click',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
        BridgeVariantCase(
          name: 'EventScroll',
          label: 'scroll',
          fields: [
            BridgeRecordField(name: 'delta', dartType: 'double', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'onEvent',
      cSymbol: 'processor_on_event',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'handler',
          type: BridgeType(
            name: 'void Function(Event)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'Event')],
          ),
        ),
      ],
    ),
  ],
);

BridgeSpec _nullableVariantCallbackSpec() => BridgeSpec(
  dartClassName: 'Processor',
  lib: 'processor',
  namespace: 'processor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'processor.native.dart',
  variants: [
    BridgeVariant(
      name: 'Event',
      cases: [
        BridgeVariantCase(
          name: 'EventTap',
          label: 'tap',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'onOptEvent',
      cSymbol: 'processor_on_opt_event',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'handler',
          type: BridgeType(
            name: 'void Function(Event?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'Event?')],
          ),
        ),
      ],
    ),
  ],
);

// ── Gap 17 helpers ───────────────────────────────────────────────────────────

BridgeSpec _variantStreamSpec() => BridgeSpec(
  dartClassName: 'Events',
  lib: 'events',
  namespace: 'events',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'events.native.dart',
  variants: [
    BridgeVariant(
      name: 'UIEvent',
      cases: [
        BridgeVariantCase(
          name: 'UIEventTap',
          label: 'tap',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
        BridgeVariantCase(
          name: 'UIEventSwipe',
          label: 'swipe',
          fields: [
            BridgeRecordField(name: 'dir', dartType: 'String', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'uiEvents',
      registerSymbol: 'events_register_ui_events_stream',
      releaseSymbol: 'events_release_ui_events_stream',
      itemType: BridgeType(name: 'UIEvent'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

BridgeSpec _nullableVariantStreamSpec() => BridgeSpec(
  dartClassName: 'Events',
  lib: 'events',
  namespace: 'events',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'events.native.dart',
  variants: [
    BridgeVariant(
      name: 'UIEvent',
      cases: [
        BridgeVariantCase(
          name: 'UIEventTap',
          label: 'tap',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'uiEvents',
      registerSymbol: 'events_register_ui_events_stream',
      releaseSymbol: 'events_release_ui_events_stream',
      itemType: BridgeType(name: 'UIEvent', isNullable: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── Gap 18 helpers ───────────────────────────────────────────────────────────

BridgeSpec _webStreamSpec() => BridgeSpec(
  dartClassName: 'WebCounter',
  lib: 'web_counter',
  namespace: 'web_counter',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  webImpl: NativeImpl.wasm,
  sourceUri: 'web_counter.native.dart',
  streams: [
    BridgeStream(
      dartName: 'ticks',
      registerSymbol: 'web_counter_register_ticks_stream',
      releaseSymbol: 'web_counter_release_ticks_stream',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

BridgeSpec _webNativeAsyncSpec() => BridgeSpec(
  dartClassName: 'WebIO',
  lib: 'web_io',
  namespace: 'web_io',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  webImpl: NativeImpl.wasm,
  sourceUri: 'web_io.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'readAsync',
      cSymbol: 'web_io_read_async',
      isAsync: true,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int', isFuture: true),
      params: [],
    ),
  ],
);

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── Gap 9: Non-contiguous enum values ──────────────────────────────────────

  group('Gap 9 — Non-contiguous enum rawValues', () {
    group('BridgeEnum.nativeValueAt()', () {
      test('with rawValues returns explicit native values', () {
        final e = BridgeEnum(
          name: 'Quality',
          startValue: 0,
          values: ['low', 'medium', 'high'],
          rawValues: [0, 50, 100],
        );
        expect(e.nativeValueAt(0), 0);
        expect(e.nativeValueAt(1), 50);
        expect(e.nativeValueAt(2), 100);
      });

      test('without rawValues falls back to startValue+index', () {
        final e = BridgeEnum(
          name: 'Status',
          startValue: 10,
          values: ['a', 'b', 'c'],
        );
        expect(e.nativeValueAt(0), 10);
        expect(e.nativeValueAt(1), 11);
        expect(e.nativeValueAt(2), 12);
      });

      test('rawValues.length != values.length throws assertion', () {
        expect(
          () => BridgeEnum(
            name: 'Bad',
            startValue: 0,
            values: ['a', 'b'],
            rawValues: [0, 5, 10], // length mismatch
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('Dart extension generation — non-contiguous', () {
      test('nativeValue getter uses switch expression (not index + start)', () {
        final code = EnumGenerator.generateDartExtensions(_nonContiguousEnumSpec());
        expect(code, contains('case Quality.low: return 0;'));
        expect(code, contains('case Quality.medium: return 50;'));
        expect(code, contains('case Quality.high: return 100;'));
        expect(code, isNot(contains('index + ')));
      });

      test('toQuality() uses switch with explicit values', () {
        final code = EnumGenerator.generateDartExtensions(_nonContiguousEnumSpec());
        expect(code, contains('case 0: return Quality.low;'));
        expect(code, contains('case 50: return Quality.medium;'));
        expect(code, contains('case 100: return Quality.high;'));
      });

      test('toQuality() throws ArgumentError for unknown native value', () {
        final code = EnumGenerator.generateDartExtensions(_nonContiguousEnumSpec());
        expect(code, contains("ArgumentError('Unknown Quality native value"));
      });
    });

    group('Kotlin enum generation — non-contiguous', () {
      test('Kotlin enum uses explicit native values', () {
        final code = KotlinGenerator.generate(_nonContiguousEnumSpec());
        expect(code, contains('LOW(0)'));
        expect(code, contains('MEDIUM(50)'));
        expect(code, contains('HIGH(100)'));
      });
    });

    group('Swift enum generation — non-contiguous', () {
      test('Swift enum uses explicit raw values', () {
        final code = SwiftGenerator.generate(_nonContiguousEnumSpec());
        expect(code, contains('case low = 0'));
        expect(code, contains('case medium = 50'));
        expect(code, contains('case high = 100'));
      });
    });

    group('C header generation — non-contiguous', () {
      test('C typedef enum uses explicit values (generation does not throw)', () {
        // C enum values appear in CppHeaderGenerator output; verify no exception
        expect(() => DartFfiGenerator.generate(_nonContiguousEnumSpec()), returnsNormally);
      });
    });
  });

  // ── Gap 13: @NitroVariant as callback parameter ───────────────────────────

  group('Gap 13 — @NitroVariant callback parameter', () {
    group('SpecValidator', () {
      test('@NitroVariant callback param produces no validation errors', () {
        final issues = SpecValidator.validate(_variantCallbackSpec());
        expect(issues.where((i) => i.isError), isEmpty, reason: '@NitroVariant is now a supported callback parameter type');
      });

      test('nullable @NitroVariant callback param is also valid', () {
        final issues = SpecValidator.validate(_nullableVariantCallbackSpec());
        expect(issues.where((i) => i.isError), isEmpty);
      });
    });

    group('Dart FFI — @NitroVariant callback decode', () {
      test('Pointer<Uint8> FFI type for variant callback param', () {
        final code = DartFfiGenerator.generate(_variantCallbackSpec());
        expect(code, contains('Pointer<Uint8>'), reason: 'variant params arrive as [4B len][tag][fields] binary blob');
      });

      test('EventVariantExt.fromNative() decode for non-nullable variant param', () {
        final code = DartFfiGenerator.generate(_variantCallbackSpec());
        expect(code, contains('EventVariantExt.fromNative(arg0)'));
        expect(code, contains('_nitroFree(arg0)'));
      });

      test('nullable variant param checks nullptr before decoding', () {
        final code = DartFfiGenerator.generate(_nullableVariantCallbackSpec());
        expect(code, contains('arg0 == nullptr ? null'));
        expect(code, contains('EventVariantExt.fromNative(arg0)'));
      });
    });
  });

  // ── Gap 17: @NitroVariant as Stream<T> item ───────────────────────────────

  group('Gap 17 — @NitroVariant as Stream item type', () {
    group('SpecValidator', () {
      test('@NitroVariant stream item passes E011 (known type)', () {
        final issues = SpecValidator.validate(_variantStreamSpec());
        expect(issues.any((i) => i.code == 'E011'), isFalse);
      });

      test('nullable @NitroVariant stream item also passes validation', () {
        final issues = SpecValidator.validate(_nullableVariantStreamSpec());
        expect(issues.any((i) => i.code == 'E011'), isFalse);
      });
    });

    group('Dart FFI — @NitroVariant stream unpack', () {
      test('emits Pointer<Uint8>.fromAddress for variant stream', () {
        final code = DartFfiGenerator.generate(_variantStreamSpec());
        expect(code, contains('Pointer<Uint8>.fromAddress(message as int)'));
      });

      test('emits UIEventVariantExt.fromNative decode', () {
        final code = DartFfiGenerator.generate(_variantStreamSpec());
        expect(code, contains('UIEventVariantExt.fromNative(rawPtr)'));
        expect(code, contains('_nitroFree(rawPtr)'));
      });

      test('emits try/finally to free allocation', () {
        final code = DartFfiGenerator.generate(_variantStreamSpec());
        expect(code, contains('try {'));
        expect(code, contains('} finally {'));
      });

      test('nullable variant stream handles null message', () {
        final code = DartFfiGenerator.generate(_nullableVariantStreamSpec());
        expect(code, contains('if (message == null)'));
        expect(code, contains('return null'));
      });

      test('non-nullable variant stream throws on null message', () {
        final code = DartFfiGenerator.generate(_variantStreamSpec());
        expect(code, contains("StateError('Received null event on non-nullable stream uiEvents')"));
      });

      test('stream return type is Stream<UIEvent>', () {
        final code = DartFfiGenerator.generate(_variantStreamSpec());
        expect(code, contains('Stream<UIEvent>'));
      });
    });
  });

  // ── Gap 18 (retired in 0.7.0) → web capability checks ─────────────────────
  //
  // Streams and @NitroNativeAsync are fully supported on web since the 0.7.0
  // WASM bridge; W007 no longer exists. The remaining web-specific checks:
  // W008 (@nitroAsync runs inline on the main thread) and W009 (@zeroCopy is
  // one bulk copy on web).

  group('web capability checks (0.7.0)', () {
    test('streams on web no longer warn (W007 retired)', () {
      final issues = SpecValidator.validate(_webStreamSpec());
      expect(issues.any((i) => i.code == 'W007'), isFalse, reason: 'streams are fully supported on web since 0.7.0');
    });

    test('@NitroNativeAsync on web no longer warns (W007 retired)', () {
      final issues = SpecValidator.validate(_webNativeAsyncSpec());
      expect(issues.any((i) => i.code == 'W007'), isFalse);
    });

    test('@nitroAsync on web emits W008 (runs on the main thread)', () {
      final spec = BridgeSpec(
        dartClassName: 'WebAsync',
        lib: 'web_async',
        namespace: 'web_async',
        webImpl: NativeImpl.wasm,
        sourceUri: 'web_async.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'crunch',
            cSymbol: 'web_async_crunch',
            isAsync: true,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final w008 = issues.where((i) => i.code == 'W008').toList();
      expect(w008, hasLength(1));
      expect(w008.single.isError, isFalse);
      expect(w008.single.message, contains('main thread'));
      expect(w008.single.hint, contains('@nitroNativeAsync'));
    });

    test('no W008 for @nitroAsync without a web target', () {
      final spec = BridgeSpec(
        dartClassName: 'NativeAsync2',
        lib: 'native_async2',
        namespace: 'native_async2',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'native_async2.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'crunch',
            cSymbol: 'native_async2_crunch',
            isAsync: true,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'W008'), isFalse);
    });

    test('@zeroCopy on web emits W009 (snapshot semantics)', () {
      final spec = BridgeSpec(
        dartClassName: 'WebZero',
        lib: 'web_zero',
        namespace: 'web_zero',
        webImpl: NativeImpl.wasm,
        sourceUri: 'web_zero.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'grab',
            cSymbol: 'web_zero_grab',
            isAsync: false,
            zeroCopyReturn: true,
            returnType: BridgeType(name: 'Uint8List'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.where((i) => i.code == 'W009'), hasLength(1));
    });

    test('struct with String / TypedData / nested-struct fields passes (all pointer slots)', () {
      final spec = BridgeSpec(
        dartClassName: 'WebStruct',
        lib: 'web_struct',
        namespace: 'web_struct',
        webImpl: NativeImpl.wasm,
        sourceUri: 'web_struct.native.dart',
        structs: [
          BridgeStruct(name: 'Inner', packed: false, fields: [BridgeField(name: 'n', type: BridgeType(name: 'int'))]),
          BridgeStruct(
            name: 'Tagged',
            packed: true,
            fields: [
              BridgeField(name: 'id', type: BridgeType(name: 'int')),
              BridgeField(name: 'label', type: BridgeType(name: 'String')),
              BridgeField(name: 'bytes', type: BridgeType(name: 'Uint8List')),
              BridgeField(name: 'inner', type: BridgeType(name: 'Inner')),
            ],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.code == 'E017'), isEmpty);
    });

    test('struct with a field kind that has no wasm32 layout is still E017', () {
      final spec = BridgeSpec(
        dartClassName: 'WebStruct',
        lib: 'web_struct',
        namespace: 'web_struct',
        webImpl: NativeImpl.wasm,
        sourceUri: 'web_struct.native.dart',
        structs: [
          BridgeStruct(
            name: 'Tagged',
            packed: true,
            fields: [
              BridgeField(name: 'id', type: BridgeType(name: 'int')),
              BridgeField(name: 'blob', type: BridgeType(name: 'Map<String, int>')),
            ],
          ),
        ],
      );
      final e017 = SpecValidator.validate(spec).where((i) => i.code == 'E017').toList();
      expect(e017, hasLength(1));
      expect(e017.single.isError, isTrue);
      expect(e017.single.message, contains('blob'));
      expect(e017.single.hint, contains('@HybridRecord'));
    });

    test('prim-only struct on web passes (no E017)', () {
      final spec = BridgeSpec(
        dartClassName: 'WebPoint',
        lib: 'web_point',
        namespace: 'web_point',
        webImpl: NativeImpl.wasm,
        sourceUri: 'web_point.native.dart',
        structs: [
          BridgeStruct(
            name: 'Pt',
            packed: true,
            fields: [
              BridgeField(name: 'x', type: BridgeType(name: 'double')),
              BridgeField(name: 'y', type: BridgeType(name: 'double')),
            ],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E017'), isFalse);
    });
  });

}
