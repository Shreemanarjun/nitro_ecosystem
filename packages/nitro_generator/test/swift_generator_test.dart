import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _recordSwiftSpec() => BridgeSpec(
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
        BridgeRecordField(name: 'v', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'get',
      cSymbol: 'mod_get',
      isAsync: false,
      returnType: BridgeType(name: 'Reading', isRecord: true),
      params: [],
    ),
  ],
);

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

    test('documents native implementation thread-safety contract', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('Nitro may call this implementation from any native thread.'));
      expect(
        out,
        contains('Keep mutable state thread-safe or marshal work onto your own queue/actor.'),
      );
      expect(out, isNot(contains('DispatchQueue.main.sync')));
      expect(out, isNot(contains('NSLock')));
    });

    test('sync function in protocol', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('func add(a: Double, b: Double) -> Double'));
    });

    test('zero-copy TypedData return emits three-word native envelope helper', () {
      final out = SwiftGenerator.generate(
        BridgeSpec(
          dartClassName: 'Dsp',
          lib: 'dsp',
          namespace: 'dsp',
          iosImpl: NativeImpl.swift,
          sourceUri: 'dsp.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'snapshot',
              cSymbol: 'dsp_snapshot',
              isAsync: false,
              returnType: BridgeType(name: 'Uint8List'),
              zeroCopyReturn: true,
              params: [],
            ),
          ],
        ),
      );

      expect(out, contains('private func _nitroMakeZeroCopyTypedDataReturn(_ bytes: UnsafeRawBufferPointer)'));
      expect(out, contains('let headerSize = MemoryLayout<Int64>.size * 3'));
      expect(out, contains('raw.advanced(by: MemoryLayout<Int64>.size).storeBytes'));
      expect(out, contains('return r.withUnsafeBytes { _nitroMakeZeroCopyTypedDataReturn(\$0) }'));
      expect(out, contains('func snapshot() -> Data'));
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

    test('stream callback returns Bool and cancels when Dart port is dead', () {
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
      expect(out, contains('_ emitCb: @convention(c) (Int64, Int64) -> Bool'));
      expect(out, contains('if !emitCb(dartPort, item.rawValue) {'));
      expect(out, contains('FooRegistry._statusStreamCancellables.removeValue(forKey: dartPort)?.cancel()'));
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
      expect(out, contains('let pathStr = _nitroStringFromCString(path)'));
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

      test('nullable bool? return uses guard-let and returns -1 for nil', () {
        final out = SwiftGenerator.generate(nullableSpec('bool'));
        // nullable bool: -1 = null, 0 = false, 1 = true
        expect(out, contains('guard let result = impl.getValue() else { return -1 }'));
        expect(out, contains('return result ? 1 : 0'));
      });

      test('nullable String? return returns nil for null (not empty string)', () {
        final out = SwiftGenerator.generate(nullableSpec('String'));
        // Correct: nil result → return nil (nullptr to Dart), not empty string.
        expect(out, contains('guard let _s ='));
        expect(out, contains('return _nitroStringToCString(_s)'));
        expect(out, isNot(contains('?? ""')));
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

      test('non-nullable record return uses explicit impl guard then toNative', () {
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
        expect(out, contains('guard let impl = ModRegistry.impl else { return nil }'));
        expect(out, contains('return impl.getReading().toNative().map { UnsafeMutableRawPointer(\$0) }'));
      });
    });

    // ── Nullable bool parameter encoding ─────────────────────────────────────

    group('nullable bool parameter — @_cdecl stub', () {
      BridgeSpec boolParamSpec({bool nullable = false}) => BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'run',
            cSymbol: 'mod_run',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'flag',
                type: BridgeType(name: nullable ? 'bool?' : 'bool'),
              ),
            ],
          ),
        ],
      );

      test('non-nullable bool param uses Int8', () {
        final out = SwiftGenerator.generate(boolParamSpec(nullable: false));
        expect(out, contains('_ flag: Int8'));
        expect(out, isNot(contains('_ flag: Int32')));
        expect(out, contains('flag: flag != 0'));
      });

      test('nullable bool? param uses UnsafeMutablePointer<UInt8>? for raw byte pointer', () {
        final out = SwiftGenerator.generate(boolParamSpec(nullable: true));
        // C bridge sends const uint8_t* (raw byte pointer, byte[0]=hasValue, byte[1]=value).
        expect(out, contains('_ flag: UnsafeMutablePointer<UInt8>?'));
        expect(out, isNot(contains('_ flag: Int32')));
        expect(out, isNot(contains('_ flag: Int8')));
        // Call arg decodes via subscript byte access ([0]=hasValue, [1]=value).
        expect(out, contains('[0] != 0'));
        expect(out, isNot(contains('withMemoryRebound')));
      });
    });

    // ── Async nullable return sentinels ───────────────────────────────────────

    group('async nullable return sentinels', () {
      BridgeSpec asyncNullableSpec(String returnType) => BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getValue',
            cSymbol: 'mod_get_value',
            isAsync: true,
            returnType: BridgeType(name: returnType, isNullable: true, isFuture: true),
            params: [],
          ),
        ],
      );

      test('async nullable int? returns -1 for nil (Dart sentinel)', () {
        final out = SwiftGenerator.generate(asyncNullableSpec('int'));
        expect(out, contains('return result ?? Int64.min'));
        expect(out, isNot(contains('return result ?? 0\n')));
      });

      test('async nullable double? returns Double.nan for nil (Dart sentinel)', () {
        final out = SwiftGenerator.generate(asyncNullableSpec('double'));
        expect(out, contains('return result ?? Double.nan'));
        expect(out, isNot(contains('return result ?? 0.0')));
      });

      test('async nullable bool? returns -1 for nil and 1/0 for true/false', () {
        final out = SwiftGenerator.generate(asyncNullableSpec('bool'));
        expect(out, contains('guard let b = result else { return -1 }'));
        expect(out, contains('return b ? 1 : 0'));
        // Must not fall back to false-default path.
        expect(out, isNot(contains('result ?? false')));
      });
    });

    // ── List param decoding (indexed format) ──────────────────────────────────

    group('list param decoding uses decodeIndexedList', () {
      BridgeSpec listParamSpec(String listType, {List<BridgeRecordType> recordTypes = const []}) => BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: recordTypes,
        functions: [
          BridgeFunction(
            dartName: 'process',
            cSymbol: 'mod_process',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'items',
                type: BridgeType(name: listType, isRecord: listType.startsWith('List<')),
              ),
            ],
          ),
        ],
      );

      test('List<int> param uses decodeIndexedList to skip offset table', () {
        final out = SwiftGenerator.generate(listParamSpec('List<int>'));
        expect(out, contains('NitroRecordReader.decodeIndexedList'));
        expect(out, isNot(contains('NitroRecordReader.decodeList')));
      });

      test('List<double> param uses decodeIndexedList', () {
        final out = SwiftGenerator.generate(listParamSpec('List<double>'));
        expect(out, contains('NitroRecordReader.decodeIndexedList'));
      });

      test('List<String> param uses decodeIndexedList', () {
        final out = SwiftGenerator.generate(listParamSpec('List<String>'));
        expect(out, contains('NitroRecordReader.decodeIndexedList'));
      });

      test('List<@HybridRecord> param uses decodeIndexedList', () {
        final out = SwiftGenerator.generate(
          listParamSpec(
            'List<Config>',
            recordTypes: [
              BridgeRecordType(
                name: 'Config',
                fields: [
                  BridgeRecordField(name: 'value', dartType: 'int', kind: RecordFieldKind.primitive),
                ],
              ),
            ],
          ),
        );
        expect(out, contains('NitroRecordReader.decodeIndexedList'));
      });
    });

    // ── NitroRecordReader boilerplate includes decodeIndexedList ─────────────

    test('generated Swift bridge includes decodeIndexedList in NitroRecordReader', () {
      // Any spec with a record type triggers boilerplate emission.
      // decodeIndexedList is emitted in the NitroRecordReader boilerplate from record_generator.
      // Check via CppBridgeGenerator which embeds the Swift boilerplate in the Apple section.
      // For SwiftGenerator, the boilerplate is emitted by RecordGenerator.generateSwift.
      final out = SwiftGenerator.generate(_recordSwiftSpec());
      expect(out, contains('decodeIndexedList'));
      expect(out, contains('r.pos += Int(count) * 8'));
    });

    test('NitroRecordReader avoids aligned load(as:) for packed payload scalars', () {
      final out = SwiftGenerator.generate(_recordSwiftSpec());
      final readerStart = out.indexOf('public class NitroRecordReader');
      expect(readerStart, isNonNegative);
      final reader = out.substring(readerStart);

      expect(reader, contains('memcpy(&v, bytes.advanced(by: pos), 8)'));
      expect(reader, contains('memcpy(&v, bytes.advanced(by: pos), 4)'));
      expect(reader, isNot(contains('.load(as: Int64.self)')));
      expect(reader, isNot(contains('.load(as: Int32.self)')));
      expect(reader, isNot(contains('.load(as: UInt64.self)')));
    });
  });
}
