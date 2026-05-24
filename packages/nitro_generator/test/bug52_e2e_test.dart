// End-to-end verification that Bug 5.2 (enum default param) works through
// the spec_from_source parser → dart_ffi_generator pipeline.
import 'package:test/test.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'spec_tester.dart';

void main() {
  group('Bug 5.2 — enum default param end-to-end via spec_from_source', () {
    final src = SpecSource('''
@HybridEnum()
enum PrintQuality { low, normal, high }

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Printer {
  Future<void> printText(String text, {PrintQuality quality = PrintQuality.normal});
}
''', uri: 'printer.native.dart');

    test('defaultLiteral is extracted as PrintQuality.normal', () {
      final spec = src.spec;
      final param = spec.functions.first.params.firstWhere((p) => p.name == 'quality');
      expect(param.defaultLiteral, equals('PrintQuality.normal'), reason: 'spec_from_source must extract defaultLiteral from enum default');
      expect(param.isNamed, isTrue);
      expect(param.isOptional, isTrue);
    });

    test('Dart FFI generator emits {PrintQuality quality = PrintQuality.normal}', () {
      final out = DartFfiGenerator.generate(src.spec);
      expect(out, contains('{PrintQuality quality = PrintQuality.normal}'));
    });

    test('Dart FFI generator does NOT emit required for enum default param', () {
      final out = DartFfiGenerator.generate(src.spec);
      expect(out, isNot(contains('required PrintQuality quality')));
    });

    test('Dart FFI generator converts enum to nativeValue in FFI call', () {
      final out = DartFfiGenerator.generate(src.spec);
      expect(out, contains('quality.nativeValue'));
    });

    test('nullable enum? param with no default emits {PrintQuality? quality}', () {
      final nullableSrc = SpecSource('''
@HybridEnum()
enum PrintQuality { low, normal, high }

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Printer {
  void send({PrintQuality? quality});
}
''', uri: 'printer.native.dart');
      final out = DartFfiGenerator.generate(nullableSrc.spec);
      expect(out, contains('{PrintQuality? quality'));
      expect(out, isNot(contains('required PrintQuality? quality')));
    });

    test('mixed: positional String + named enum default', () {
      final mixedSrc = SpecSource('''
@HybridEnum()
enum PrintQuality { low, normal, high }

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Printer {
  void printText(String text, {PrintQuality quality = PrintQuality.normal, int? copies});
}
''', uri: 'printer.native.dart');
      final out = DartFfiGenerator.generate(mixedSrc.spec);
      expect(out, contains('String text'));
      expect(out, contains('PrintQuality quality = PrintQuality.normal'));
      expect(out, contains('int? copies'));
    });
  });
}
