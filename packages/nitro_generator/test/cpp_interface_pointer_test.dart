// Tests for CppInterfaceGenerator Pointer<T> type mapping.
// Covers: Pointer<Void>, Pointer<EnumName>, Pointer<StructName>,
// Pointer<RecordName>, Pointer<int>, null pointerInnerType,
// multiple pointer params, pointer return type.
import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _ptrSpec({
  required String innerType,
  required String? pointerInnerType,
  String paramName = 'buf',
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
  List<BridgeRecordType> records = const [],
}) => BridgeSpec(
  dartClassName: 'PtrModule',
  lib: 'ptr_module',
  namespace: 'ptr_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'ptr_module.native.dart',
  enums: enums,
  structs: structs,
  recordTypes: records,
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'ptr_module_process',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: paramName,
          type: BridgeType(
            name: 'Pointer<$innerType>',
            isPointer: true,
            pointerInnerType: pointerInnerType,
          ),
        ),
      ],
    ),
  ],
);

BridgeSpec _ptrReturnSpec({
  required String innerType,
  required String? pointerInnerType,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
  List<BridgeRecordType> records = const [],
}) => BridgeSpec(
  dartClassName: 'PtrModule',
  lib: 'ptr_module',
  namespace: 'ptr_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'ptr_module.native.dart',
  enums: enums,
  structs: structs,
  recordTypes: records,
  functions: [
    BridgeFunction(
      dartName: 'getPtr',
      cSymbol: 'ptr_module_get_ptr',
      isAsync: false,
      returnType: BridgeType(
        name: 'Pointer<$innerType>',
        isPointer: true,
        pointerInnerType: pointerInnerType,
      ),
      params: [],
    ),
  ],
);

void main() {
  group('CppInterfaceGenerator — Pointer<T> param mapping', () {
    test('Pointer<Void> param → void*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'Void', pointerInnerType: 'Void'),
      );
      expect(out, contains('virtual void process(void* buf) = 0;'));
    });

    test('Pointer<void> (lowercase) param → void*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'void', pointerInnerType: 'void'),
      );
      expect(out, contains('virtual void process(void* buf) = 0;'));
    });

    test('Pointer with null pointerInnerType → void*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'Unknown', pointerInnerType: null),
      );
      expect(out, contains('virtual void process(void* buf) = 0;'));
    });

    test('Pointer<Uint8> param → void* (Uint8 is FFI type, not C primitive)', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'Uint8', pointerInnerType: 'Uint8'),
      );
      // Uint8 is a Dart FFI type — _primitiveType returns void*, so Pointer<Uint8> → void*
      expect(out, contains('virtual void process(void* buf) = 0;'));
    });

    test('Pointer<int> param → int64_t*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'int', pointerInnerType: 'int'),
      );
      expect(out, contains('virtual void process(int64_t* buf) = 0;'));
    });

    test('Pointer<double> param → double*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'double', pointerInnerType: 'double'),
      );
      expect(out, contains('virtual void process(double* buf) = 0;'));
    });

    test('Pointer<EnumName> param → EnumName*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(
          innerType: 'SensorMode',
          pointerInnerType: 'SensorMode',
          enums: [
            BridgeEnum(name: 'SensorMode', startValue: 0, values: ['off', 'on']),
          ],
        ),
      );
      expect(out, contains('virtual void process(SensorMode* buf) = 0;'));
    });

    test('Pointer<StructName> param → StructName*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(
          innerType: 'Frame',
          pointerInnerType: 'Frame',
          structs: [
            BridgeStruct(
              name: 'Frame',
              packed: true,
              fields: [
                BridgeField(
                  name: 'w',
                  type: BridgeType(name: 'int'),
                ),
              ],
            ),
          ],
        ),
      );
      expect(out, contains('virtual void process(Frame* buf) = 0;'));
    });

    test('Pointer<RecordName> param → NitroCppBuffer*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(
          innerType: 'Stats',
          pointerInnerType: 'Stats',
          records: [
            BridgeRecordType(
              name: 'Stats',
              fields: [BridgeRecordField(name: 'count', dartType: 'int', kind: RecordFieldKind.primitive)],
            ),
          ],
        ),
      );
      expect(out, contains('virtual void process(NitroCppBuffer* buf) = 0;'));
    });

    test('Pointer<String> param → std::string*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'String', pointerInnerType: 'String'),
      );
      expect(out, contains('virtual void process(std::string* buf) = 0;'));
    });

    test('nullable inner type Uint8? strips ? → void* (Uint8 is FFI type)', () {
      final out = CppInterfaceGenerator.generate(
        _ptrSpec(innerType: 'Uint8', pointerInnerType: 'Uint8?'),
      );
      expect(out, contains('virtual void process(void* buf) = 0;'));
    });
  });

  group('CppInterfaceGenerator — Pointer<T> return type mapping', () {
    test('Pointer<Void> return → void*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrReturnSpec(innerType: 'Void', pointerInnerType: 'Void'),
      );
      expect(out, contains('virtual void* getPtr() = 0;'));
    });

    test('Pointer with null pointerInnerType return → void*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrReturnSpec(innerType: 'Unknown', pointerInnerType: null),
      );
      expect(out, contains('virtual void* getPtr() = 0;'));
    });

    test('Pointer<int> return → int64_t*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrReturnSpec(innerType: 'int', pointerInnerType: 'int'),
      );
      expect(out, contains('virtual int64_t* getPtr() = 0;'));
    });

    test('Pointer<EnumName> return → EnumName*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrReturnSpec(
          innerType: 'Color',
          pointerInnerType: 'Color',
          enums: [
            BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'blue']),
          ],
        ),
      );
      expect(out, contains('virtual Color* getPtr() = 0;'));
    });

    test('Pointer<StructName> return → StructName*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrReturnSpec(
          innerType: 'Point',
          pointerInnerType: 'Point',
          structs: [
            BridgeStruct(
              name: 'Point',
              packed: true,
              fields: [
                BridgeField(
                  name: 'x',
                  type: BridgeType(name: 'double'),
                ),
              ],
            ),
          ],
        ),
      );
      expect(out, contains('virtual Point* getPtr() = 0;'));
    });

    test('Pointer<RecordName> return → NitroCppBuffer*', () {
      final out = CppInterfaceGenerator.generate(
        _ptrReturnSpec(
          innerType: 'Meta',
          pointerInnerType: 'Meta',
          records: [
            BridgeRecordType(
              name: 'Meta',
              fields: [BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive)],
            ),
          ],
        ),
      );
      expect(out, contains('virtual NitroCppBuffer* getPtr() = 0;'));
    });
  });

  group('CppInterfaceGenerator — multiple Pointer params', () {
    test('two Pointer params with different inner types', () {
      final spec = BridgeSpec(
        dartClassName: 'MultiPtr',
        lib: 'multi_ptr',
        namespace: 'multi_ptr',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'multi_ptr.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'copy',
            cSymbol: 'multi_ptr_copy',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'src',
                type: BridgeType(
                  name: 'Pointer<Uint8>',
                  isPointer: true,
                  pointerInnerType: 'Uint8',
                ),
              ),
              BridgeParam(
                name: 'dst',
                type: BridgeType(
                  name: 'Pointer<Void>',
                  isPointer: true,
                  pointerInnerType: 'Void',
                ),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      // Uint8 is a Dart FFI type → void*; Void → void*
      expect(out, contains('virtual void copy(void* src, void* dst) = 0;'));
    });

    test('Pointer param mixed with regular params', () {
      final spec = BridgeSpec(
        dartClassName: 'MixedPtr',
        lib: 'mixed_ptr',
        namespace: 'mixed_ptr',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mixed_ptr.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'send',
            cSymbol: 'mixed_ptr_send',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [
              BridgeParam(
                name: 'data',
                type: BridgeType(
                  name: 'Pointer<Uint8>',
                  isPointer: true,
                  pointerInnerType: 'Uint8',
                ),
              ),
              BridgeParam(
                name: 'length',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      // Uint8 is a Dart FFI type (not C uint8_t) → void*; int → int64_t
      expect(out, contains('virtual int64_t send(void* data, int64_t length) = 0;'));
    });
  });

  group('CppInterfaceGenerator — not-applicable guard', () {
    test('non-cpp spec returns not-applicable comment', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('Not applicable'));
    });
  });
}
