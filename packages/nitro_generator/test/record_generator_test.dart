import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

/// Mirrors the nitro_ar scenario:
///   @HybridStruct Vector3 + @HybridStruct Quaternion
///   nested inside @HybridRecord LiveTrackingUpdate (via @HybridStruct PackageDimensions).
///
/// Root bug: RecordGenerator was emitting `toNative(Allocator)` for EVERY
/// struct RecordExt, including @HybridStruct types that already have
/// `XxxExt.toNative(Arena arena)`.  Since Arena implements Allocator, Dart
/// reported "member defined in both Vector3Ext and Vector3RecordExt" at
/// every call site that passed an Arena.
BridgeSpec _nestedStructInRecordSpec() {
  final vector3 = BridgeStruct(
    name: 'Vector3',
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
      BridgeField(
        name: 'z',
        type: BridgeType(name: 'double'),
      ),
    ],
  );
  final quaternion = BridgeStruct(
    name: 'Quaternion',
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
      BridgeField(
        name: 'z',
        type: BridgeType(name: 'double'),
      ),
      BridgeField(
        name: 'w',
        type: BridgeType(name: 'double'),
      ),
    ],
  );
  final dimensions = BridgeStruct(
    name: 'PackageDimensions',
    fields: [
      BridgeField(
        name: 'length',
        type: BridgeType(name: 'double'),
      ),
      BridgeField(
        name: 'vector3',
        type: BridgeType(name: 'Vector3'),
      ),
      BridgeField(
        name: 'quaternion',
        type: BridgeType(name: 'Quaternion'),
      ),
    ],
    packed: false,
  );
  final liveUpdate = BridgeRecordType(
    name: 'LiveTrackingUpdate',
    fields: [
      BridgeRecordField(name: 'isTracking', dartType: 'bool', kind: RecordFieldKind.primitive),
      BridgeRecordField(name: 'centerDimensions', dartType: 'PackageDimensions', kind: RecordFieldKind.recordObject),
    ],
  );
  return BridgeSpec(
    dartClassName: 'NitroAr',
    lib: 'nitro_ar',
    namespace: 'nitro_ar',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'nitro_ar.native.dart',
    structs: [vector3, quaternion, dimensions],
    recordTypes: [liveUpdate],
  );
}

void main() {
  group('RecordGenerator', () {
    test('emits extension for each @HybridRecord type', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('extension CameraDeviceRecordExt on CameraDevice'));
    });

    test('emits static fromNative factory', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('static CameraDevice fromNative(Pointer<Uint8> ptr)'));
    });

    test('emits writeFields method', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('void writeFields(RecordWriter writer)'));
    });

    test('primitive String field reads via r.readString()', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('r.readString()'));
    });

    test('List<@HybridRecord> field uses List.generate + fromReader', () {
      final out = RecordGenerator.generateDartExtensions(recordListSpec());
      expect(out, contains('List.generate(r.readInt32(), (_) => ResolutionRecordExt.fromReader(r))'));
    });
  });

  // ── Struct-in-record: toNative(Allocator) must NOT be emitted for @HybridStruct ──
  //
  // Regression for: "A member named 'toNative' is defined in both
  // 'extension Vector3Ext on Vector3' and 'extension Vector3RecordExt on Vector3'"
  //
  // Root cause: RecordGenerator was emitting `toNative(Allocator alloc)` for
  // every struct used as a record field. @HybridStruct types already have
  // `XxxExt.toNative(Arena arena)`, and since Arena implements Allocator,
  // Dart sees two equally applicable `toNative` methods and refuses to compile.
  group('RecordGenerator — @HybridStruct nested in @HybridRecord: no toNative conflict', () {
    late String out;
    setUpAll(() => out = RecordGenerator.generateDartExtensions(_nestedStructInRecordSpec()));

    test('Vector3RecordExt is emitted for inline serialisation', () {
      expect(out, contains('extension Vector3RecordExt on Vector3'));
    });

    test('Vector3RecordExt has fromReader for inline deserialisation', () {
      expect(out, contains('static Vector3 fromReader(RecordReader r)'));
    });

    test('Vector3RecordExt has writeFields for inline serialisation', () {
      expect(out, contains('void writeFields(RecordWriter writer)'));
    });

    test('Vector3RecordExt does NOT emit toNative(Allocator) — would conflict with Vector3Ext.toNative(Arena)', () {
      // Extract the Vector3RecordExt block and verify it has no toNative method.
      // Any toNative in this block would be ambiguous with Vector3Ext.toNative(Arena)
      // because Arena implements Allocator.
      final start = out.indexOf('extension Vector3RecordExt on Vector3');
      final end = out.indexOf('\nextension ', start + 1);
      final block = start != -1 ? out.substring(start, end != -1 ? end : out.length) : '';
      expect(
        block,
        isNot(contains('toNative(')),
        reason: 'Vector3RecordExt must not define toNative — conflicts with Vector3Ext.toNative(Arena)',
      );
    });

    test('QuaternionRecordExt does NOT emit toNative(Allocator)', () {
      final start = out.indexOf('extension QuaternionRecordExt on Quaternion');
      final end = out.indexOf('\nextension ', start + 1);
      final block = start != -1 ? out.substring(start, end != -1 ? end : out.length) : '';
      expect(block, isNot(contains('toNative(')));
    });

    test('PackageDimensionsRecordExt does NOT emit toNative(Allocator)', () {
      final start = out.indexOf('extension PackageDimensionsRecordExt on PackageDimensions');
      final end = out.indexOf('\nextension ', start + 1);
      final block = start != -1 ? out.substring(start, end != -1 ? end : out.length) : '';
      expect(block, isNot(contains('toNative(')));
    });

    test('@HybridRecord types still get toNative(Allocator) — they have no struct FFI extension', () {
      // LiveTrackingUpdate is a @HybridRecord (not @HybridStruct), so its
      // RecordExt must still include toNative to support standalone serialisation
      // (e.g. as a stream item or return value).
      expect(out, contains('extension LiveTrackingUpdateRecordExt on LiveTrackingUpdate'));
      final start = out.indexOf('extension LiveTrackingUpdateRecordExt on LiveTrackingUpdate');
      final block = out.substring(start);
      expect(block, contains('toNative(Allocator alloc)'));
    });

    test('nested struct fields are still serialised via writeFields, not toNative', () {
      // PackageDimensionsRecordExt.writeFields calls vector3.writeFields(writer),
      // which assumes vector3 has its own RecordExt generated.
      expect(out, contains('vector3.writeFields(writer)'));
      expect(out, contains('quaternion.writeFields(writer)'));
    });
  });
}
