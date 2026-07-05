/// Tests for L5 — nullable list items: List<@HybridEnum?> and List<@NitroVariant?>.
///
/// Wire format for nullable enum list:
///   [4B payload_len][4B count][for each: 1B hasValue][8B nativeValue (only if hasValue)]
/// Wire format for nullable variant list:
///   [4B payload_len][4B count][for each: 1B hasValue][tag+fields (only if hasValue)]
library;

import 'package:nitro_annotations/nitro_annotations.dart' show NativeImpl;
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Shared test fixtures ───────────────────────────────────────────────────────

BridgeEnum _brightnessEnum() => BridgeEnum(
  name: 'BrightnessLevel',
  startValue: 0,
  values: ['low', 'medium', 'high'],
  rawValues: [0, 50, 100],
);

BridgeVariant _gestureVariant() => BridgeVariant(
  name: 'GestureEvent',
  cases: [
    BridgeVariantCase(
      name: 'GestureTap',
      label: 'tap',
      fields: [
        BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
    BridgeVariantCase(
      name: 'GestureSwipe',
      label: 'swipe',
      fields: [
        BridgeRecordField(name: 'velocity', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
);

// Spec with nullable enum list param and return
BridgeSpec _nullableEnumListSpec() => BridgeSpec(
  dartClassName: 'ThemeManager',
  lib: 'theme_manager',
  namespace: 'theme_manager',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'theme_manager.native.dart',
  enums: [_brightnessEnum()],
  functions: [
    BridgeFunction(
      dartName: 'filterBrightness',
      cSymbol: 'theme_manager_filter_brightness',
      isAsync: false,
      returnType: BridgeType(
        name: 'List<BrightnessLevel?>',
        isRecord: true,
        isEnumList: true,
        recordListItemType: 'BrightnessLevel',
        recordListItemIsNullable: true,
      ),
      params: [
        BridgeParam(
          name: 'levels',
          type: BridgeType(
            name: 'List<BrightnessLevel?>',
            isRecord: true,
            isEnumList: true,
            recordListItemType: 'BrightnessLevel',
            recordListItemIsNullable: true,
          ),
        ),
      ],
    ),
  ],
);

// Spec with nullable variant list param and return
BridgeSpec _nullableVariantListSpec() => BridgeSpec(
  dartClassName: 'GestureHub',
  lib: 'gesture_hub',
  namespace: 'gesture_hub',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'gesture_hub.native.dart',
  variants: [_gestureVariant()],
  functions: [
    BridgeFunction(
      dartName: 'filterGestures',
      cSymbol: 'gesture_hub_filter_gestures',
      isAsync: false,
      returnType: BridgeType(
        name: 'List<GestureEvent?>',
        isRecord: true,
        isVariantList: true,
        recordListItemType: 'GestureEvent',
        recordListItemIsNullable: true,
      ),
      params: [
        BridgeParam(
          name: 'events',
          type: BridgeType(
            name: 'List<GestureEvent?>',
            isRecord: true,
            isVariantList: true,
            recordListItemType: 'GestureEvent',
            recordListItemIsNullable: true,
          ),
        ),
      ],
    ),
  ],
);

void main() {
  // ── §25: L5 — List<@HybridEnum?> nullable items ──────────────────────────

  group('§25: L5 — List<@HybridEnum?> nullable items', () {
    late String dartCode;
    late String kotlinCode;
    late String swiftCode;

    setUpAll(() {
      final spec = _nullableEnumListSpec();
      dartCode = DartFfiGenerator.generate(spec);
      kotlinCode = KotlinGenerator.generate(spec);
      swiftCode = SwiftGenerator.generate(spec);
    });

    test('Spec validates without errors', () {
      expect(SpecValidator.validate(_nullableEnumListSpec()).where((i) => i.isError), isEmpty);
    });

    group('Dart FFI', () {
      test('param decode uses decodeNullableList for List<BrightnessLevel?>', () {
        expect(dartCode, contains('RecordReader.decodeNullableList'));
        expect(dartCode, contains('r.readInt().toBrightnessLevel()'));
      });

      test('return encode uses encodeNullableList for List<BrightnessLevel?>', () {
        expect(dartCode, contains('RecordWriter.encodeNullableList'));
        expect(dartCode, contains('w.writeInt(e.nativeValue)'));
      });

      test('function signature accepts and returns List<BrightnessLevel?>', () {
        expect(dartCode, contains('List<BrightnessLevel?> filterBrightness('));
      });
    });

    group('Kotlin', () {
      test('Kotlin interface return type is List<BrightnessLevel?>', () {
        expect(kotlinCode, contains('fun filterBrightness('));
        expect(kotlinCode, contains(': List<BrightnessLevel?>'));
      });

      test('Kotlin param decode reads 1B hasValue before 8B nativeValue', () {
        expect(kotlinCode, contains('get().toInt() != 0'));
        expect(kotlinCode, contains('BrightnessLevel.fromNative(levelsBuf.getLong())'));
      });

      test('Kotlin return encode writes 1B hasValue flag per item', () {
        expect(kotlinCode, contains('9 * count // 1B hasValue + 8B value per item'));
        expect(kotlinCode, contains('buf.put(if (item != null) 1 else 0)'));
      });

      test('Kotlin return encode writes nativeValue only if non-null', () {
        expect(kotlinCode, contains('if (item != null) buf.putLong(item.nativeValue)'));
      });
    });

    group('Swift', () {
      test('Swift param decode uses decodeNullableList', () {
        expect(swiftCode, contains('NitroRecordReader.decodeNullableList'));
      });

      test('Swift return encode uses encodeNullableList', () {
        expect(swiftCode, contains('NitroRecordWriter.encodeNullableList'));
      });
    });
  });

  // ── §26: L5 edge — List<@NitroVariant?> nullable items ───────────────────

  group('§26: L5 edge — List<@NitroVariant?> nullable items', () {
    late String dartCode;
    late String kotlinCode;
    late String swiftCode;

    setUpAll(() {
      final spec = _nullableVariantListSpec();
      dartCode = DartFfiGenerator.generate(spec);
      kotlinCode = KotlinGenerator.generate(spec);
      swiftCode = SwiftGenerator.generate(spec);
    });

    test('Spec validates without errors', () {
      expect(SpecValidator.validate(_nullableVariantListSpec()).where((i) => i.isError), isEmpty);
    });

    group('Dart FFI', () {
      test('param decode uses decodeNullableList for List<GestureEvent?>', () {
        expect(dartCode, contains('RecordReader.decodeNullableList'));
        expect(dartCode, contains('GestureEventVariantExt.fromReader(r)'));
      });

      test('return encode uses encodeNullableList for List<GestureEvent?>', () {
        expect(dartCode, contains('RecordWriter.encodeNullableList'));
        expect(dartCode, contains('v.writeFields(w)'));
      });

      test('function signature accepts and returns List<GestureEvent?>', () {
        expect(dartCode, contains('List<GestureEvent?> filterGestures('));
      });
    });

    group('Kotlin', () {
      test('Kotlin interface return type is List<GestureEvent?>', () {
        expect(kotlinCode, contains('fun filterGestures('));
        expect(kotlinCode, contains(': List<GestureEvent?>'));
      });

      test('Kotlin param decode reads 1B hasValue via readBool()', () {
        expect(kotlinCode, contains('eventsRdr.readBool()'));
        expect(kotlinCode, contains('GestureEvent.fromReader(eventsRdr)'));
      });

      test('Kotlin return encode wraps null item as byteArrayOf(0)', () {
        expect(kotlinCode, contains("if (item == null) byteArrayOf(0)"));
      });

      test('Kotlin return encode prepends 1 byte before non-null variant bytes', () {
        expect(kotlinCode, contains("byteArrayOf(1) + _iw.toByteArray()"));
      });
    });

    group('Swift', () {
      test('Swift param decode uses decodeNullableList for variant', () {
        expect(swiftCode, contains('NitroRecordReader.decodeNullableList'));
        expect(swiftCode, contains('GestureEvent.fromReader(r)'));
      });

      test('Swift return encode uses encodeNullableList for variant', () {
        expect(swiftCode, contains('NitroRecordWriter.encodeNullableList'));
        expect(swiftCode, contains('e.writeFields(to: w)'));
      });
    });
  });

  // ── §27: L5 contrast — non-nullable lists unchanged ──────────────────────

  group('§27: L5 contrast — non-nullable list items use original encoding', () {
    late String dartCode;
    late String kotlinCode;

    setUpAll(() {
      final spec = BridgeSpec(
        dartClassName: 'BrightnessService',
        lib: 'brightness_service',
        namespace: 'brightness_service',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'brightness_service.native.dart',
        enums: [_brightnessEnum()],
        functions: [
          BridgeFunction(
            dartName: 'getLevels',
            cSymbol: 'brightness_service_get_levels',
            isAsync: false,
            returnType: BridgeType(
              name: 'List<BrightnessLevel>',
              isRecord: true,
              isEnumList: true,
              recordListItemType: 'BrightnessLevel',
              // recordListItemIsNullable defaults to false
            ),
            params: [],
          ),
        ],
      );
      dartCode = DartFfiGenerator.generate(spec);
      kotlinCode = KotlinGenerator.generate(spec);
    });

    test('non-nullable uses decodeList (not decodeNullableList)', () {
      expect(dartCode, contains('RecordReader.decodeList'));
      expect(dartCode, isNot(contains('RecordReader.decodeNullableList')));
    });

    test('non-nullable uses encodeList (not encodeNullableList) in encode path', () {
      // The param path in Dart would use encodeList
      expect(dartCode, isNot(contains('RecordWriter.encodeNullableList')));
    });

    test('non-nullable Kotlin uses 8B per item (no hasValue byte)', () {
      expect(kotlinCode, contains('4 + 8 * count'));
      expect(kotlinCode, isNot(contains('9 * count')));
    });

    test('non-nullable Kotlin forEach uses it.nativeValue directly', () {
      expect(kotlinCode, contains('result.forEach { buf.putLong(it.nativeValue) }'));
    });
  });
}
