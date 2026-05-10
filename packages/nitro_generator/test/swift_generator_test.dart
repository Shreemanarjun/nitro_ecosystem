import 'package:nitro_annotations/nitro_annotations.dart';
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
      // namespace = 'my_camera_module' → _my_camera_module_call_add
      expect(out, contains('@_cdecl("_my_camera_module_call_add")'));
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
            dartName: 'doWork',
            cSymbol: 'foo_do_work',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('DispatchSemaphore'));
      expect(out, contains('Task.detached'));
    });

    test('bool property getter returns Int8 with ternary', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'isActive',
            type: BridgeType(name: 'bool'),
            getSymbol: 'foo_get_is_active',
            setSymbol: 'foo_set_is_active',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('== true ? 1 : 0'));
    });

    test('enum stream emits rawValue', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        enums: [
          BridgeEnum(name: 'Status', values: ['idle', 'running'], startValue: 0),
        ],
        streams: [
          BridgeStream(
            dartName: 'statusStream',
            registerSymbol: 'foo_register_status_stream',
            releaseSymbol: 'foo_release_status_stream',
            itemType: BridgeType(name: 'Status'),
            backpressure: Backpressure.block,
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('item.rawValue'));
    });

    test('String param in native async converts UnsafePointer to String', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'saveFile',
            cSymbol: 'foo_save_file',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'path',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains(r'let pathStr = path.map { String(cString: $0) }'));
      expect(out, contains('path: pathStr'));
    });
  });
}
