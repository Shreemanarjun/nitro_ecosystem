// Tests for nested @HybridStruct field code generation.
//
// When a struct field's type is itself a @HybridStruct the generator must:
//   Dart FFI    — field type  : Pointer<NestedFfi>  (not Pointer<Void>)
//   toDart()    — conversion  : nested.ref.toDart() (not raw pointer)
//   toNative()  — conversion  : nested.toNative(arena)
//   freeFields()— cleanup     : frees the nested pointer
//   Proxy super — default val : NestedType(x: 0.0, …) (not null)
//   Proxy getter— read        : _native.ref.nested.ref.toDart()
//   C typedef   — field type  : NestedType*          (not void*)
//   Kotlin      — field type  : NestedType            (not Any?)
//   Swift       — field type  : NestedType            (not Any?)

import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  // ── Dart FFI Struct (PackageDimensionsFfi) ─────────────────────────────────
  group('Dart FFI Struct — nested field types', () {
    late String out;

    setUp(() => out = StructGenerator.generateDartExtensions(nestedStructSpec()));

    test('nested struct field uses Pointer<NestedFfi> not Pointer<Void>', () {
      expect(out, contains('external Pointer<Vector3Ffi> center;'));
      expect(out, contains('external Pointer<QuaternionFfi> rotation;'));
      expect(out, isNot(contains('external Pointer<Void> center')));
      expect(out, isNot(contains('external Pointer<Void> rotation')));
    });

    test('flat leaf struct fields still use primitive types', () {
      // Vector3Ffi / QuaternionFfi should use @Double() + double, not pointers
      expect(out, contains('external double x;'));
      expect(out, contains('external double y;'));
      expect(out, contains('external double z;'));
      expect(out, contains('external double w;'));
    });

    // ── toDart() ──────────────────────────────────────────────────────────────
    test('toDart() converts nested struct field via .ref.toDart()', () {
      expect(out, contains('center: center.ref.toDart()'));
      expect(out, contains('rotation: rotation.ref.toDart()'));
    });

    test('toDart() still converts primitive fields directly', () {
      expect(out, contains('length: length'));
      expect(out, contains('confidence: confidence'));
    });

    // ── toNative() ────────────────────────────────────────────────────────────
    test('toNative() assigns nested struct via .toNative(arena)', () {
      expect(out, contains('ptr.ref.center = center.toNative(arena)'));
      expect(out, contains('ptr.ref.rotation = rotation.toNative(arena)'));
    });

    test('toNative() still assigns primitive fields directly', () {
      expect(out, contains('ptr.ref.length = length'));
      expect(out, contains('ptr.ref.confidence = confidence'));
    });

    // ── freeFields() ─────────────────────────────────────────────────────────
    test('freeFields() emits null-check + freeFields + malloc.free for nested pointer', () {
      expect(out, contains('if (center != nullptr) {'));
      expect(out, contains('center.ref.freeFields();'));
      expect(out, contains('malloc.free(center);'));
      expect(out, contains('if (rotation != nullptr) {'));
      expect(out, contains('rotation.ref.freeFields();'));
      expect(out, contains('malloc.free(rotation);'));
    });

    test('freeFields() on leaf struct (no pointer fields) is empty', () {
      // Vector3 has only double fields — freeFields body should be empty
      final v3Start = out.indexOf('extension Vector3FfiExt on Vector3Ffi {');
      final v3End = out.indexOf('extension Vector3FfiExt', v3Start + 1);
      final v3Block = out.substring(v3Start, v3End == -1 ? null : v3End);
      // The freeFields method should contain no malloc.free calls
      final freeStart = v3Block.indexOf('void freeFields()');
      final freeEnd = v3Block.indexOf('}', freeStart + 1);
      final freeBody = v3Block.substring(freeStart, freeEnd + 1);
      expect(freeBody, isNot(contains('malloc.free')));
    });
  });

  // ── Dart Native Proxies ────────────────────────────────────────────────────
  group('Dart Native Proxy — nested field super() and getters', () {
    late String out;

    setUp(() => out = StructGenerator.generateDartProxies(nestedStructSpec()));

    test('proxy super() uses zero-value constructor for nested struct (not null)', () {
      expect(out, contains('center: Vector3(x: 0.0, y: 0.0, z: 0.0)'));
      expect(out, contains('rotation: Quaternion(x: 0.0, y: 0.0, z: 0.0, w: 0.0)'));
      expect(out, isNot(contains('center: null')));
      expect(out, isNot(contains('rotation: null')));
    });

    test('proxy super() still uses numeric zero for primitive fields', () {
      expect(out, contains('length: 0.0'));
      expect(out, contains('confidence: 0.0'));
    });

    test('proxy lazy getter reads nested struct via .ref.toDart()', () {
      expect(out, contains('get center => _native.ref.center.ref.toDart()'));
      expect(out, contains('get rotation => _native.ref.rotation.ref.toDart()'));
    });

    test('proxy lazy getter for primitive field reads directly', () {
      expect(out, contains('get length => _native.ref.length'));
    });
  });

  // ── C struct typedef ───────────────────────────────────────────────────────
  group('C struct typedef — nested field uses struct pointer', () {
    late String out;

    setUp(() => out = StructGenerator.generateCStructs(nestedStructSpec()));

    test('nested struct field generates TypeName* not void*', () {
      expect(out, contains('Vector3* center'));
      expect(out, contains('Quaternion* rotation'));
      expect(out, isNot(contains('void* center')));
      expect(out, isNot(contains('void* rotation')));
    });

    test('flat struct still uses primitive C types', () {
      expect(out, contains('double x;'));
      expect(out, contains('double y;'));
      expect(out, contains('double z;'));
    });
  });

  // ── Kotlin ────────────────────────────────────────────────────────────────
  group('Kotlin — nested struct uses type name not Any?', () {
    late String out;

    setUp(() => out = StructGenerator.generateKotlin(nestedStructSpec()));

    test('nested struct field uses Kotlin type name', () {
      expect(out, contains('val center: Vector3'));
      expect(out, contains('val rotation: Quaternion'));
      expect(out, isNot(contains('val center: Any?')));
      expect(out, isNot(contains('val rotation: Any?')));
    });

    test('primitive fields still map to Kotlin primitives', () {
      expect(out, contains('val length: Double'));
      expect(out, contains('val confidence: Double'));
    });
  });

  // ── Swift ─────────────────────────────────────────────────────────────────
  group('Swift — nested struct uses type name not Any?', () {
    late String out;

    setUp(() => out = StructGenerator.generateSwift(nestedStructSpec()));

    test('nested struct field uses Swift type name', () {
      expect(out, contains('var center: Vector3'));
      expect(out, contains('var rotation: Quaternion'));
      expect(out, isNot(contains('var center: Any?')));
      expect(out, isNot(contains('var rotation: Any?')));
    });

    test('primitive fields still map to Swift primitives', () {
      expect(out, contains('var length: Double'));
      expect(out, contains('var confidence: Double'));
    });
  });

  // ── Deep nesting A → B → C ────────────────────────────────────────────────
  group('Deep nesting (Root → Mid → Leaf)', () {
    test('Mid.leaf field maps to Pointer<LeafFfi> in FFI Struct', () {
      final out = StructGenerator.generateDartExtensions(deeplyNestedStructSpec());
      expect(out, contains('external Pointer<LeafFfi> leaf;'));
      expect(out, isNot(contains('external Pointer<Void> leaf')));
    });

    test('Root.mid field maps to Pointer<MidFfi> in FFI Struct', () {
      final out = StructGenerator.generateDartExtensions(deeplyNestedStructSpec());
      expect(out, contains('external Pointer<MidFfi> mid;'));
      expect(out, isNot(contains('external Pointer<Void> mid')));
    });

    test('proxy super() for Mid uses Leaf zero-value constructor', () {
      final out = StructGenerator.generateDartProxies(deeplyNestedStructSpec());
      expect(out, contains('leaf: Leaf(val: 0.0)'));
    });

    test('proxy super() for Root uses Mid zero-value constructor', () {
      final out = StructGenerator.generateDartProxies(deeplyNestedStructSpec());
      // Mid contains a Leaf nested struct and an int field
      expect(out, contains('mid: Mid(leaf: Leaf(val: 0.0), count: 0)'));
    });

    test('C struct uses recursive struct pointer types', () {
      final out = StructGenerator.generateCStructs(deeplyNestedStructSpec());
      expect(out, contains('Leaf* leaf'));
      expect(out, contains('Mid* mid'));
    });
  });

  // ── No nested structs — regression (existing behaviour unchanged) ──────────
  group('No nested structs — regression', () {
    test('flat struct fields unchanged: Pointer<Void> not emitted', () {
      // richSpec() has Reading{double value, bool valid} — no nested structs.
      final out = StructGenerator.generateDartExtensions(richSpec());
      expect(out, isNot(contains('Pointer<Void>')));
    });

    test('flat struct proxy super() still uses primitive defaults', () {
      final out = StructGenerator.generateDartProxies(richSpec());
      expect(out, contains('value: 0.0'));
      expect(out, contains('valid: false'));
    });

    test('empty struct list returns empty string', () {
      final spec = BridgeSpec(
        dartClassName: 'Empty',
        lib: 'empty',
        namespace: 'empty',
        iosImpl: NativeImpl.swift,
        sourceUri: 'empty.native.dart',
      );
      expect(StructGenerator.generateDartExtensions(spec), isEmpty);
      expect(StructGenerator.generateDartProxies(spec), isEmpty);
      expect(StructGenerator.generateCStructs(spec), isEmpty);
      expect(StructGenerator.generateKotlin(spec), isEmpty);
      expect(StructGenerator.generateSwift(spec), isEmpty);
    });
  });

  // ── Mixed field types — struct field alongside string/bool/enum/typed-data ─
  group('Mixed field types in struct', () {
    BridgeSpec mixedSpec() => BridgeSpec(
      dartClassName: 'Mixed',
      lib: 'mixed',
      namespace: 'mixed',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mixed.native.dart',
      enums: [
        BridgeEnum(name: 'Status', startValue: 0, values: ['ok', 'err']),
      ],
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
        BridgeStruct(
          name: 'Annotation',
          packed: false,
          fields: [
            BridgeField(
              name: 'label',
              type: BridgeType(name: 'String'),
            ),
            BridgeField(
              name: 'confidence',
              type: BridgeType(name: 'double'),
            ),
            BridgeField(
              name: 'active',
              type: BridgeType(name: 'bool'),
            ),
            BridgeField(
              name: 'status',
              type: BridgeType(name: 'Status'),
            ),
            BridgeField(
              name: 'origin',
              type: BridgeType(name: 'Point'),
            ),
          ],
        ),
      ],
      functions: [],
    );

    test('string field still uses Pointer<Utf8> not Pointer<NestedFfi>', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('external Pointer<Utf8> label;'));
    });

    test('bool field still uses int in FFI Struct', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('@Int8()'));
      expect(out, contains('external int active;'));
    });

    test('enum field still uses int in FFI Struct', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('@Int32()'));
      expect(out, contains('external int status;'));
    });

    test('nested struct field uses Pointer<PointFfi>', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('external Pointer<PointFfi> origin;'));
    });

    test('toDart(): each field type converted correctly in same struct', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('label: label.toDartString()'));
      expect(out, contains('active: active != 0'));
      expect(out, contains('status: status.toStatus()'));
      expect(out, contains('origin: origin.ref.toDart()'));
    });

    test('toNative(): each field type assigned correctly in same struct', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('ptr.ref.label = label.toNativeUtf8(allocator: arena)'));
      expect(out, contains('ptr.ref.active = active ? 1 : 0'));
      expect(out, contains('ptr.ref.status = status.nativeValue'));
      expect(out, contains('ptr.ref.origin = origin.toNative(arena)'));
    });

    test('freeFields(): string freed but nested struct pointer also freed', () {
      final out = StructGenerator.generateDartExtensions(mixedSpec());
      expect(out, contains('if (label != nullptr) malloc.free(label)'));
      expect(out, contains('if (origin != nullptr) {'));
      expect(out, contains('origin.ref.freeFields();'));
      expect(out, contains('malloc.free(origin);'));
    });

    test('Kotlin: struct field maps to type name alongside other Kotlin types', () {
      final out = StructGenerator.generateKotlin(mixedSpec());
      expect(out, contains('val label: String'));
      expect(out, contains('val active: Boolean'));
      expect(out, contains('val status: Long')); // enum → Long
      expect(out, contains('val origin: Point'));
    });

    test('Swift: struct field maps to type name alongside other Swift types', () {
      final out = StructGenerator.generateSwift(mixedSpec());
      expect(out, contains('var label: String'));
      expect(out, contains('var active: Bool'));
      expect(out, contains('var status: Status')); // enum kept by name
      expect(out, contains('var origin: Point'));
    });

    test('C typedef: struct field uses TypeName* alongside other C types', () {
      final out = StructGenerator.generateCStructs(mixedSpec());
      expect(out, contains('const char* label'));
      expect(out, contains('int8_t active'));
      expect(out, contains('int32_t status'));
      expect(out, contains('Point* origin'));
    });
  });

  // ── Packed struct containing nested struct ────────────────────────────────
  group('Packed struct with nested struct field', () {
    BridgeSpec packedNestedSpec() => BridgeSpec(
      dartClassName: 'PackedModule',
      lib: 'packed_module',
      namespace: 'packed_module',
      iosImpl: NativeImpl.swift,
      sourceUri: 'packed_module.native.dart',
      structs: [
        BridgeStruct(
          name: 'Vec2',
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
        BridgeStruct(
          name: 'TightHeader',
          packed: true,
          fields: [
            BridgeField(
              name: 'flags',
              type: BridgeType(name: 'int'),
            ),
            BridgeField(
              name: 'pos',
              type: BridgeType(name: 'Vec2'),
            ),
          ],
        ),
      ],
      functions: [],
    );

    test('packed annotation emitted for packed parent struct', () {
      final out = StructGenerator.generateDartExtensions(packedNestedSpec());
      expect(out, contains('@Packed(1)'));
    });

    test('nested field in packed struct still uses Pointer<Vec2Ffi>', () {
      final out = StructGenerator.generateDartExtensions(packedNestedSpec());
      expect(out, contains('external Pointer<Vec2Ffi> pos;'));
    });

    test('C struct for packed parent uses struct pointer and pack pragma', () {
      final out = StructGenerator.generateCStructs(packedNestedSpec());
      expect(out, contains('#pragma pack(push, 1)'));
      expect(out, contains('Vec2* pos'));
    });
  });
}
