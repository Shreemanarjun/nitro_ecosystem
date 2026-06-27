// Tests for @NitroAsync(timeout: N) support in KotlinGenerator.
// Issue #10: Add timeout parameter to @NitroAsync annotation.

import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _asyncTimeoutSpec({int? timeout}) => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fetchData',
      cSymbol: 'foo_fetch_data',
      isAsync: true,
      asyncTimeout: timeout,
      returnType: BridgeType(name: 'String'),
      params: [],
    ),
  ],
);

BridgeSpec _asyncNoTimeoutSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fetchData',
      cSymbol: 'foo_fetch_data',
      isAsync: true,
      asyncTimeout: null,
      returnType: BridgeType(name: 'String'),
      params: [],
    ),
  ],
);

void main() {
  group('KotlinGenerator — @NitroAsync timeout (#10)', () {
    test('without timeout: uses plain runBlocking', () {
      final out = KotlinGenerator.generate(_asyncNoTimeoutSpec());
      expect(out, contains('runBlocking { impl.fetchData() }'));
    });

    test('without timeout: does NOT emit withTimeout', () {
      final out = KotlinGenerator.generate(_asyncNoTimeoutSpec());
      expect(out, isNot(contains('withTimeout')));
    });

    test('with timeout: emits withTimeout import', () {
      final out = KotlinGenerator.generate(_asyncTimeoutSpec(timeout: 5000));
      expect(out, contains('import kotlinx.coroutines.withTimeout'));
    });

    test('with timeout: wraps coroutine in withTimeout', () {
      final out = KotlinGenerator.generate(_asyncTimeoutSpec(timeout: 5000));
      expect(out, contains('withTimeout(5000L)'));
    });

    test('with timeout: includes the method call inside withTimeout', () {
      final out = KotlinGenerator.generate(_asyncTimeoutSpec(timeout: 5000));
      expect(out, contains('withTimeout(5000L) { impl.fetchData() }'));
    });

    test('with timeout: still uses runBlocking wrapping withTimeout', () {
      final out = KotlinGenerator.generate(_asyncTimeoutSpec(timeout: 5000));
      expect(out, contains('runBlocking { withTimeout(5000L)'));
    });

    test('with timeout 1000ms: uses correct timeout value', () {
      final out = KotlinGenerator.generate(_asyncTimeoutSpec(timeout: 1000));
      expect(out, contains('withTimeout(1000L)'));
    });

    test('without timeout: no withTimeout import', () {
      final out = KotlinGenerator.generate(_asyncNoTimeoutSpec());
      expect(out, isNot(contains('import kotlinx.coroutines.withTimeout')));
    });

    test('BridgeFunction: asyncTimeout field defaults to null', () {
      final func = BridgeFunction(
        dartName: 'test',
        cSymbol: 'test_sym',
        isAsync: true,
        returnType: BridgeType(name: 'void'),
        params: [],
      );
      expect(func.asyncTimeout, isNull);
    });

    test('BridgeFunction: asyncTimeout field can be set', () {
      final func = BridgeFunction(
        dartName: 'test',
        cSymbol: 'test_sym',
        isAsync: true,
        asyncTimeout: 3000,
        returnType: BridgeType(name: 'void'),
        params: [],
      );
      expect(func.asyncTimeout, equals(3000));
    });
  });
}
