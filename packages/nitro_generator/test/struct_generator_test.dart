import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('StructGenerator', () {
    test('packed struct emits @Packed(1) in Dart', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        structs: [
          BridgeStruct(
            name: 'Tight',
            packed: true,
            fields: [
              BridgeField(name: 'val', type: BridgeType(name: 'int')),
            ],
          ),
        ],
      );
      final out = StructGenerator.generateDartExtensions(spec);
      expect(out, contains('@Packed(1)'));
    });

    test('toDart() converts bool field via != 0', () {
      final out = StructGenerator.generateDartExtensions(richSpec());
      expect(out, contains('valid != 0'));
    });

    test('toNative() bool field uses ? 1 : 0', () {
      final out = StructGenerator.generateDartExtensions(richSpec());
      expect(out, contains('valid ? 1 : 0'));
    });

    test('C struct typedef emitted', () {
      final out = StructGenerator.generateCStructs(richSpec());
      expect(out, contains('typedef struct {'));
      expect(out, contains('} Reading;'));
    });

    test('Kotlin data class emitted', () {
      final out = StructGenerator.generateKotlin(richSpec());
      expect(out, contains('data class Reading('));
    });

    test('Swift struct public fields emitted', () {
      final out = StructGenerator.generateSwift(richSpec());
      expect(out, contains('public struct Reading'));
      expect(out, contains('public var value: Double'));
    });
  });
}
