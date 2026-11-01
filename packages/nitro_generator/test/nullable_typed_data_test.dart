// Nullable TypedData: a @zeroCopy `Uint8List?` return and a nullable TypedData
// struct field must decode a native null pointer to Dart null, not crash.
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';
import 'spec_from_source.dart';

String gen(String body) => DartFfiGenerator.generate(
      SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
import 'dart:typed_data';
part 'n.g.dart';
$body
''', sourceUri: 'package:n/src/n.native.dart')
        ..assetPackage = 'n');

const _mod = '''
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class N extends HybridObject {
  @ZeroCopy() Uint8List? maybeGrab();
  @ZeroCopy() Uint8List alwaysGrab();
}
''';

void main() {
  group('nullable @zeroCopy return', () {
    final out = gen(_mod);

    test('is accepted by the validator', () {
      final spec = SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
import 'dart:typed_data';
part 'n.g.dart';
$_mod
''', sourceUri: 'package:n/src/n.native.dart')
        ..assetPackage = 'n';
      expect(SpecValidator.validate(spec).where((i) => i.severity == ValidationSeverity.error), isEmpty);
    });

    test('null pointer decodes to Dart null', () {
      expect(out, contains('if (res == nullptr) {'));
      expect(out, contains('return null;'));
    });

    test('a non-nullable @zeroCopy return still throws on an unexpected null', () {
      expect(out, contains("throw StateError('Native Uint8List return was null')"));
    });
  });

  group('nullable TypedData struct field', () {
    final out = gen('''
@HybridStruct()
class Frame {
  final Uint8List? data;
  final int width;
  const Frame({required this.data, required this.width});
}
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class N extends HybridObject {
  Frame echo(Frame f);
}
''');

    test('getter guards a null pointer instead of dereferencing it', () {
      expect(out, contains('get data => _native.ref.data.address == 0 ? null : _native.ref.data.asTypedList'));
    });
  });

  group('non-nullable TypedData field is unchanged', () {
    final out = gen('''
@HybridStruct()
class Frame {
  final Uint8List data;
  final int len;
  const Frame({required this.data, required this.len});
}
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class N extends HybridObject {
  Frame echo(Frame f);
}
''');

    test('getter has no null guard (no behaviour change)', () {
      expect(out, contains('get data => _native.ref.data.asTypedList'));
      expect(out, isNot(contains('data.address == 0 ? null')));
    });
  });
}
