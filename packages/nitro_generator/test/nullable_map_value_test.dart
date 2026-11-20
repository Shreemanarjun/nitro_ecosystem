// Nullable map VALUES (`Map<String, T?>`) ride the String-key wire's existing
// per-value type tag as tag 0. Every backend must agree on that byte: Dart
// writes it, Kotlin/Swift/C++/web read it, and the key stays present with a
// null value rather than being dropped.

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// A web-targeting spec splits the FFI code into a separate .ffi.g.dart
// library, so the Dart-side assertions use the non-web form.
BridgeSpec _spec({String valueType = 'int?', bool web = false}) => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  webImpl: web ? NativeImpl.wasm : null,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'echoMap',
      cSymbol: 'foo_echo_map',
      isAsync: false,
      returnType: BridgeType(name: 'Map<String, $valueType>', isRecord: true, isMap: true),
      params: [
        BridgeParam(name: 'value', type: BridgeType(name: 'Map<String, $valueType>', isRecord: true, isMap: true)),
      ],
    ),
  ],
);

void main() {
  group('Dart FFI codec', () {
    test('nullable and non-nullable helpers do not collide', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_nitroEncodeMapBinaryIntNullable'));
      expect(out, contains('_nitroDecodeMapBinaryIntNullable'));
      expect(out, contains('Map<String, int?>'));
    });

    test('encode writes tag 0 for null and the value tag otherwise', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, anyOf(contains('bb.addByte(0)'), contains('out[pos++] = 0;')));
      expect(out, anyOf(contains('bb.addByte(1)'), contains('out[pos++] = 1;')), reason: 'int values still tag 1');
    });

    test('decode reads the tag instead of skipping it, and keeps the key', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('result[key] = null'));
      // The non-nullable path skips the tag blindly; the nullable one must not.
      expect(out, isNot(contains('skip type tag (always 1=int64 for Map<String,int?>)')));
    });

    test('the non-nullable form is untouched', () {
      final out = DartFfiGenerator.generate(_spec(valueType: 'int'));
      expect(out, contains('skip type tag'));
      expect(out, isNot(contains('Nullable')));
      expect(out, allOf(isNot(contains('bb.addByte(0)')), isNot(contains('out[pos++] = 0;'))));
    });
  });

  group('Kotlin bridge', () {
    test('interface keeps the value nullable', () {
      final out = KotlinGenerator.generate(_spec());
      expect(out, contains('fun echoMap(value: Map<String, Long?>): Map<String, Long?>'));
    });

    test('decode maps tag 0 to a null entry, not a dropped key', () {
      final out = KotlinGenerator.generate(_spec());
      expect(out, contains('nitroDecodeMap(value) { r -> if (r.byte() == 0) null else r.int64() }'));
    });

    test('encode writes tag 0, and the value branch still resolves to int64', () {
      final out = KotlinGenerator.generate(_spec());
      expect(out, contains('if (v == null) { out.putByte(0); continue }'));
      expect(out, contains('nitroEncodeMap(_result, 1) { o, v -> o.putInt64(v) }'));
      expect(out, isNot(contains('putString(v.toString())')));
    });
  });

  group('Swift bridge', () {
    test('protocol keeps the value optional', () {
      final out = SwiftGenerator.generate(_spec());
      expect(out, contains('func echoMap(value: [String: Int64?]) -> [String: Int64?]'));
    });

    test('tag 0 is a nil value under its key, in both directions', () {
      final out = SwiftGenerator.generate(_spec());
      expect(out, contains('let valueMap: [String: Int64?] = value.map { _nitroDecodeNullableMap(\$0) { r in r.readInt() } } ?? [:]'));
      // A subscript assignment of nil would drop the key.
      expect(out, contains('out.updateValue(r.readNullTag() ? nil : read(r), forKey: key)'));
      expect(out, contains('_nitroEncodeNullableMap(result, 1) { w, v in w.writeInt(v) }'));
      expect(out, isNot(contains('NSNull')));
    });
  });

  group('web bridge', () {
    test('nullable helpers are distinct and read/write tag 0', () {
      final out = WebBridgeGenerator.generate(_spec(web: true));
      expect(out, contains('_nitroEncodeMapBytesStringIntNullable'));
      expect(out, contains('_nitroDecodeMapBytesStringIntNullable'));
      expect(out, contains('if (_v == null) { w.writeInt8(0); continue; }'));
      expect(out, contains('if (r.readInt8() == 0) { result[key] = null; continue; }'));
    });

    test('the value is bound to a local so Dart promotes it', () {
      // `e.value` is a public getter and never promotes after a null check.
      final out = WebBridgeGenerator.generate(_spec(web: true));
      expect(out, contains('final _v = e.value;'));
      expect(out, contains('w.writeInt(_v);'));
    });

    test('the call site passes the nullable helper, not the bare one', () {
      final out = WebBridgeGenerator.generate(_spec(web: true));
      expect(out, contains('_nitroEncodeMapBytesStringIntNullable(value)'));
    });
  });
}
