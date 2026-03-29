import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('SwiftGenerator', () {
    test('emits import Foundation and Combine', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('import Foundation'));
      expect(out, contains('import Combine'));
    });

    test('emits protocol with correct name', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('public protocol HybridMyCameraProtocol'));
    });

    test('sync function in protocol', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('func add(a: Double, b: Double) -> Double'));
    });

    test('async function uses async throws in protocol', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('async throws'));
    });

    test('stream uses AnyPublisher in protocol', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('AnyPublisher<Double, Never>'));
    });

    test('property with getter+setter uses get set syntax', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('{ get set }'));
    });

    test('property read-only uses get syntax', () {
      final out = SwiftGenerator.generate(enumSpec());
      expect(out, contains('{ get }'));
    });

    test('registry class emitted', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('class MyCameraRegistry'));
    });

    test('_call_ stub uses @_cdecl attribute', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('@_cdecl("_call_add")'));
    });

    test('registry class has no @objc or NSObject', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, isNot(contains('@objc')));
    });

    test('bool return type uses Int8 in @_cdecl stub', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('-> Int8'));
      expect(out, contains('? 1 : 0'));
    });

    test('async struct return uses DispatchSemaphore + Task.detached', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('DispatchSemaphore(value: 0)'));
      expect(out, contains('Task.detached'));
    });

    test('async void return uses DispatchSemaphore pattern', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'doAsync',
            cSymbol: 'foo_do_async',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('DispatchSemaphore(value: 0)'));
    });

    test('async String return uses strdup + empty string fallback', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('var result = ""'));
      expect(out, contains('return strdup(result)'));
    });

    test('String param in @_cdecl uses UnsafePointer<CChar>?', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('_ name: UnsafePointer<CChar>?'));
    });

    test('String param conversion emitted before call', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('let nameStr = name.map { String(cString: \$0) } ?? ""'));
    });

    test('sync String return uses strdup', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('return strdup('));
    });

    test('registry stores stream cancellables', () {
      final out = SwiftGenerator.generate(richSpec());
      expect(out, contains('_ticksCancellables'));
    });
  });

  group('Swift/DX Regression Tests', () {
    test('SwiftGenerator protocol uses Enum name for return type', () {
      final spec = BridgeSpec(
        dartClassName: 'T',
        lib: 't',
        namespace: 't',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        functions: [
          BridgeFunction(
            dartName: 'getStatus',
            cSymbol: 't_get_status',
            isAsync: false,
            returnType: BridgeType(name: 'MyEnum'),
            params: [],
          ),
        ],
        enums: [
          BridgeEnum(name: 'MyEnum', values: ['idle', 'busy'], startValue: 0),
        ],
        sourceUri: 't.native.dart',
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('func getStatus() -> MyEnum'));
    });

    test('SwiftGenerator property setter handles Enum rawValue', () {
      final spec = BridgeSpec(
        dartClassName: 'T',
        lib: 't',
        namespace: 't',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        properties: [
          BridgeProperty(
            dartName: 'status',
            getSymbol: 't_get_status',
            setSymbol: 't_set_status',
            type: BridgeType(name: 'MyEnum'),
            hasGetter: true,
            hasSetter: true,
          ),
        ],
        enums: [
          BridgeEnum(name: 'MyEnum', values: ['idle', 'busy'], startValue: 0),
        ],
        sourceUri: 't.native.dart',
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('if let actualValue = MyEnum(rawValue: value)'));
    });
  });
}
