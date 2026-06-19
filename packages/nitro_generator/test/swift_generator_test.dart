import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
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
      expect(out, contains('let pathStr = path != nil ? String(cString: path!) : ""'));
      expect(out, contains('path: pathStr'));
    });

    group('nullable return types — sync @_cdecl stubs', () {
      BridgeSpec nullableSpec(String returnTypeName, {List<BridgeEnum> enums = const []}) => BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: enums,
        functions: [
          BridgeFunction(
            dartName: 'getValue',
            cSymbol: 'mod_get_value',
            isAsync: false,
            returnType: BridgeType(name: returnTypeName, isNullable: true),
            params: [],
          ),
        ],
      );

      test('nullable int? return unwraps with ?? 0', () {
        final out = SwiftGenerator.generate(nullableSpec('int'));
        expect(out, contains('return impl.getValue() ?? 0'));
        expect(out, isNot(contains('return impl.getValue()\n')));
      });

      test('nullable double? return unwraps with ?? 0.0', () {
        final out = SwiftGenerator.generate(nullableSpec('double'));
        expect(out, contains('return impl.getValue() ?? 0.0'));
      });

      test('nullable bool? return uses ternary with false default', () {
        final out = SwiftGenerator.generate(nullableSpec('bool'));
        // bool? → Int8 via _toCDeclReturnType (strips ?); nullable chaining already safe
        expect(out, contains('?? false'));
        expect(out, contains('? 1 : 0'));
      });

      test('nullable String? return uses strdup with empty string default', () {
        final out = SwiftGenerator.generate(nullableSpec('String'));
        expect(out, contains('return strdup('));
        expect(out, contains('?? ""'));
      });

      test('nullable enum? return uses optional chaining with rawValue ?? 0', () {
        final out = SwiftGenerator.generate(
          nullableSpec(
            'Status',
            enums: [
              BridgeEnum(name: 'Status', values: ['idle', 'active'], startValue: 0),
            ],
          ),
        );
        expect(out, contains('return impl.getValue()?.rawValue ?? 0'));
        expect(out, isNot(contains('return impl.getValue().rawValue')));
      });

      test('non-nullable int return has no ?? fallback', () {
        final spec = BridgeSpec(
          dartClassName: 'Mod',
          lib: 'mod',
          namespace: 'mod',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'mod.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'getCount',
              cSymbol: 'mod_get_count',
              isAsync: false,
              returnType: BridgeType(name: 'int'),
              params: [],
            ),
          ],
        );
        final out = SwiftGenerator.generate(spec);
        expect(out, contains('return impl.getCount()'));
        expect(out, isNot(contains('return impl.getCount() ?? ')));
      });

      test('nullable struct? return uses double-guard and bare struct name in pointer', () {
        final spec = BridgeSpec(
          dartClassName: 'Mod',
          lib: 'mod',
          namespace: 'mod',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'mod.native.dart',
          structs: [
            BridgeStruct(
              name: 'Point',
              packed: false,
              fields: [
                BridgeField(
                  name: 'x',
                  type: BridgeType(name: 'double'),
                ),
                BridgeField(
                  name: 'y',
                  type: BridgeType(name: 'double'),
                ),
              ],
            ),
          ],
          functions: [
            BridgeFunction(
              dartName: 'getPoint',
              cSymbol: 'mod_get_point',
              isAsync: false,
              returnType: BridgeType(name: 'Point', isNullable: true),
              params: [],
            ),
          ],
        );
        final out = SwiftGenerator.generate(spec);
        // Must unwrap both impl and the optional result in one guard.
        expect(out, contains('guard let impl = ModRegistry.impl, let result = impl.getPoint() else { return nil }'));
        // Pointer type must use C-ABI shadow '_PointC', not 'Point?' or bare 'Point'.
        expect(out, contains('UnsafeMutablePointer<_PointC>.allocate(capacity: 1)'));
        expect(out, isNot(contains('UnsafeMutablePointer<Point?>')));
        expect(out, isNot(contains('UnsafeMutablePointer<Point>.allocate')));
        // Must still return a raw pointer, not the struct directly.
        expect(out, contains('return UnsafeMutableRawPointer(ptr)'));
      });

      test('non-nullable struct return uses single impl? guard', () {
        final spec = BridgeSpec(
          dartClassName: 'Mod',
          lib: 'mod',
          namespace: 'mod',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'mod.native.dart',
          structs: [
            BridgeStruct(
              name: 'Point',
              packed: false,
              fields: [
                BridgeField(
                  name: 'x',
                  type: BridgeType(name: 'double'),
                ),
                BridgeField(
                  name: 'y',
                  type: BridgeType(name: 'double'),
                ),
              ],
            ),
          ],
          functions: [
            BridgeFunction(
              dartName: 'getPoint',
              cSymbol: 'mod_get_point',
              isAsync: false,
              returnType: BridgeType(name: 'Point'),
              params: [],
            ),
          ],
        );
        final out = SwiftGenerator.generate(spec);
        expect(out, contains('guard let result = ModRegistry.impl?.getPoint()'));
        expect(out, isNot(contains('guard let impl = ModRegistry.impl, let result')));
      });

      test('nullable record? return uses explicit impl guard then optional toNative', () {
        final spec = BridgeSpec(
          dartClassName: 'Mod',
          lib: 'mod',
          namespace: 'mod',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'mod.native.dart',
          recordTypes: [
            BridgeRecordType(
              name: 'Reading',
              fields: [
                BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
              ],
            ),
          ],
          functions: [
            BridgeFunction(
              dartName: 'getReading',
              cSymbol: 'mod_get_reading',
              isAsync: false,
              returnType: BridgeType(name: 'Reading', isNullable: true, isRecord: true),
              params: [],
            ),
          ],
        );
        final out = SwiftGenerator.generate(spec);
        // Must guard on impl first to avoid Struct?? double-optional.
        expect(out, contains('guard let impl = ModRegistry.impl else { return nil }'));
        expect(out, contains('return impl.getReading()?.toNative()'));
        // Must not use double-optional chaining pattern.
        expect(out, isNot(contains('Registry.impl?.getReading()?.toNative()')));
      });

      test('non-nullable record return uses single optional-chained toNative', () {
        final spec = BridgeSpec(
          dartClassName: 'Mod',
          lib: 'mod',
          namespace: 'mod',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'mod.native.dart',
          recordTypes: [
            BridgeRecordType(
              name: 'Reading',
              fields: [
                BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
              ],
            ),
          ],
          functions: [
            BridgeFunction(
              dartName: 'getReading',
              cSymbol: 'mod_get_reading',
              isAsync: false,
              returnType: BridgeType(name: 'Reading', isRecord: true),
              params: [],
            ),
          ],
        );
        final out = SwiftGenerator.generate(spec);
        expect(out, contains('return ModRegistry.impl?.getReading()?.toNative()'));
        expect(out, isNot(contains('guard let impl = ModRegistry.impl else { return nil }\n    return impl.getReading()')));
      });
    });
  });
}
