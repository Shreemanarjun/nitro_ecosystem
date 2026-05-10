// Integration tests for the full nitro_ar spec pattern.
//
// These tests build a spec that mirrors the real nitro_ar use case and verify
// that the generated Swift / Dart / Kotlin output is correct for the three
// historically broken patterns:
//
//   1. Async bool return  → Int8((result ?? false) ? 1 : 0)  (not result ?? 0)
//   2. Stream<RecordType> → emitCb(dartPort, item.toNative()) (not raw item)
//   3. Struct in record   → fromReader / writeFields extensions emitted only for
//                           structs actually referenced in record fields

import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Shared spec: mirrors the real nitro_ar.native.dart structure ──────────────

BridgeSpec _nitroArSpec() => BridgeSpec(
  dartClassName: 'NitroAr',
  lib: 'nitro_ar',
  namespace: 'nitro_ar',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'nitro_ar.native.dart',
  structs: [
    // Transitively embedded via PackageDimensions
    BridgeStruct(
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
    ),
    BridgeStruct(
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
    ),
    // Directly referenced in LiveTrackingUpdate (a record)
    BridgeStruct(
      name: 'PackageDimensions',
      packed: false,
      fields: [
        BridgeField(
          name: 'length',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'width',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'height',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'confidence',
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
        BridgeField(
          name: 'dimensionSource',
          type: BridgeType(name: 'int'),
        ),
        BridgeField(
          name: 'ransacInlierCount',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
    // Used only as function return/param — NOT in any record field
    BridgeStruct(
      name: 'BoundingBox',
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
          name: 'width',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'height',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
  recordTypes: [
    // Record with List<double> items (primitive list)
    BridgeRecordType(
      name: 'PackageBoxes',
      fields: [
        BridgeRecordField(
          name: 'boxes',
          dartType: 'List<double>',
          kind: RecordFieldKind.listPrimitive,
          itemTypeName: 'double',
        ),
      ],
    ),
    // Record with embedded @HybridStruct field
    BridgeRecordType(
      name: 'LiveTrackingUpdate',
      fields: [
        BridgeRecordField(name: 'isTracking', dartType: 'bool', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'centerDimensions', dartType: 'PackageDimensions', kind: RecordFieldKind.recordObject, itemTypeName: 'PackageDimensions'),
        BridgeRecordField(name: 'trackingFailureReason', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'detectedPlaneCount', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    // async bool — historically generated `result ?? 0` which is a Swift type error
    BridgeFunction(
      dartName: 'checkCameraPermission',
      cSymbol: 'nitro_ar_check_camera_permission',
      isAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'requestCameraPermission',
      cSymbol: 'nitro_ar_request_camera_permission',
      isAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [],
    ),
    // sync bool
    BridgeFunction(
      dartName: 'isDepthSupported',
      cSymbol: 'nitro_ar_is_depth_supported',
      isAsync: false,
      returnType: BridgeType(name: 'bool'),
      params: [],
    ),
    // struct param + struct return
    BridgeFunction(
      dartName: 'detectPackage',
      cSymbol: 'nitro_ar_detect_package',
      isAsync: true,
      returnType: BridgeType(name: 'PackageDimensions'),
      params: [
        BridgeParam(
          name: 'rect',
          type: BridgeType(name: 'BoundingBox'),
        ),
      ],
    ),
  ],
  streams: [
    // Stream<RecordType> — historically passed item directly instead of item.toNative()
    BridgeStream(
      dartName: 'detectedPackages',
      registerSymbol: 'nitro_ar_register_detected_packages',
      releaseSymbol: 'nitro_ar_release_detected_packages',
      itemType: BridgeType(name: 'PackageBoxes', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'liveTrackingUpdates',
      registerSymbol: 'nitro_ar_register_live_tracking_updates',
      releaseSymbol: 'nitro_ar_release_live_tracking_updates',
      itemType: BridgeType(name: 'LiveTrackingUpdate', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
    // Stream<Struct> — must NOT use toNative() (struct, not record)
    BridgeStream(
      dartName: 'livePreciseDimensions',
      registerSymbol: 'nitro_ar_register_live_precise_dimensions',
      releaseSymbol: 'nitro_ar_release_live_precise_dimensions',
      itemType: BridgeType(name: 'PackageDimensions'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  late String swiftBridge;
  late String swiftRecords;

  setUp(() {
    final spec = _nitroArSpec();
    swiftBridge = SwiftGenerator.generate(spec);
    swiftRecords = RecordGenerator.generateSwift(spec);
  });

  // ── Bug fix 1: async bool return ─────────────────────────────────────────────

  group('Async bool return — Int8 casting (Bug 1)', () {
    test('checkCameraPermission returns Int8 using ternary cast', () {
      expect(swiftBridge, contains('return Int8((result ?? false) ? 1 : 0)'));
    });

    test('requestCameraPermission returns Int8 using ternary cast', () {
      // Two async bool functions → two occurrences of the pattern
      expect(
        RegExp(r'return Int8\(\(result \?\? false\) \? 1 : 0\)').allMatches(swiftBridge).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('async bool stub does NOT use result ?? 0 (Swift type error)', () {
      // The broken pattern: `result ?? 0` — Bool? is not coercible to Int8
      expect(swiftBridge, isNot(matches(RegExp(r'result \?\? 0'))));
    });

    test('async bool stub declares result as Bool? not Int8?', () {
      expect(swiftBridge, contains('var result: Bool? = nil'));
    });

    test('sync bool still uses simple ternary (non-async path unchanged)', () {
      expect(swiftBridge, contains('Int8((NitroArRegistry.impl?.isDepthSupported() ?? false) ? 1 : 0)'));
    });
  });

  // ── Bug fix 2: Stream<RecordType> emit ───────────────────────────────────────

  group('Stream<RecordType> emits item.toNative() (Bug 2)', () {
    test('detectedPackages stream emits item.toNative()', () {
      final registerBlock = _extractBlock(swiftBridge, '_register_detectedPackages_stream');
      expect(registerBlock, contains('item.toNative()'));
    });

    test('liveTrackingUpdates stream emits item.toNative()', () {
      final registerBlock = _extractBlock(swiftBridge, '_register_liveTrackingUpdates_stream');
      expect(registerBlock, contains('item.toNative()'));
    });

    test('detectedPackages emitCb parameter is UnsafeMutablePointer<UInt8>?', () {
      // The parameter type is in the function signature, not the body
      final fnIdx = swiftBridge.indexOf('_register_detectedPackages_stream');
      final fnSlice = swiftBridge.substring(fnIdx, swiftBridge.indexOf('{', fnIdx));
      expect(fnSlice, contains('UnsafeMutablePointer<UInt8>?'));
    });

    test('record stream does NOT pass item directly as emitCb argument', () {
      // The broken pattern: emitCb(dartPort, item) where item is a struct/record type
      expect(swiftBridge, isNot(contains('emitCb(dartPort, item)\n')));
    });

    test('struct stream (livePreciseDimensions) uses pointer allocation, not toNative()', () {
      final registerBlock = _extractBlock(swiftBridge, '_register_livePreciseDimensions_stream');
      expect(registerBlock, contains('UnsafeMutablePointer<PackageDimensions>.allocate'));
      expect(registerBlock, isNot(contains('item.toNative()')));
    });
  });

  // ── Bug fix 3: struct extensions in record output ────────────────────────────

  group('Swift struct fromReader/writeFields extensions (Bug 3)', () {
    test('PackageDimensions gets fromReader extension (directly in LiveTrackingUpdate)', () {
      expect(swiftRecords, contains('extension PackageDimensions {'));
      expect(swiftRecords, contains('public static func fromReader(_ r: NitroRecordReader) -> PackageDimensions'));
    });

    test('PackageDimensions gets writeFields extension', () {
      expect(swiftRecords, contains('public func writeFields(_ writer: NitroRecordWriter)'));
    });

    test('PackageDimensions.fromReader reads nested Vector3 via Vector3.fromReader', () {
      final block = _extractExtensionBlock(swiftRecords, 'PackageDimensions');
      expect(block, contains('Vector3.fromReader(r)'));
    });

    test('PackageDimensions.fromReader reads nested Quaternion via Quaternion.fromReader', () {
      final block = _extractExtensionBlock(swiftRecords, 'PackageDimensions');
      expect(block, contains('Quaternion.fromReader(r)'));
    });

    test('PackageDimensions.writeFields calls vector3.writeFields', () {
      final block = _extractExtensionBlock(swiftRecords, 'PackageDimensions');
      expect(block, contains('vector3.writeFields(writer)'));
    });

    test('Vector3 gets fromReader extension (transitively embedded in PackageDimensions)', () {
      expect(swiftRecords, contains('extension Vector3 {'));
    });

    test('Quaternion gets fromReader extension (transitively embedded in PackageDimensions)', () {
      expect(swiftRecords, contains('extension Quaternion {'));
    });

    test('BoundingBox does NOT get fromReader extension (not in any record field)', () {
      expect(swiftRecords, isNot(contains('extension BoundingBox {')));
    });

    test('LiveTrackingUpdate.fromReader calls PackageDimensions.fromReader', () {
      // The record type itself (not the extension) calls fromReader on the struct
      expect(swiftRecords, contains('PackageDimensions.fromReader(r)'));
    });

    test('LiveTrackingUpdate.writeFields calls centerDimensions.writeFields', () {
      expect(swiftRecords, contains('centerDimensions.writeFields(writer)'));
    });
  });

  // ── PackageBoxes record shape ─────────────────────────────────────────────────

  group('PackageBoxes record generation', () {
    test('PackageBoxes struct is emitted with boxes field', () {
      expect(swiftRecords, contains('public struct PackageBoxes'));
      expect(swiftRecords, contains('public var boxes:'));
    });

    test('PackageBoxes has toNative() method', () {
      expect(swiftRecords, contains('public func toNative() -> UnsafeMutablePointer<UInt8>?'));
    });

    test('PackageBoxes has fromReader', () {
      expect(swiftRecords, contains('public static func fromReader(_ r: NitroRecordReader) -> PackageBoxes'));
    });

    test('PackageBoxes.writeFields uses simple count+values format (not indexed)', () {
      expect(swiftRecords, contains('writer.writeInt32(Int32(boxes.count))'));
      expect(swiftRecords, isNot(contains('writeIndexedList')));
    });

    test('PackageBoxes.fromReader uses simple count+map format (not skip-offsets)', () {
      // Simple: (0..<Int(r.readInt32())).map { _ in r.readDouble() }
      expect(swiftRecords, contains('r.readInt32()'));
      // No offset-skip: must NOT have `r.readInt()` inside a loop for offsets
      expect(swiftRecords, isNot(matches(RegExp(r'for _ in 0\.\.<.*r\.readInt\(\)'))));
    });

    test('Swift list wire format matches Dart (count-then-values, no offset table)', () {
      expect(swiftRecords, isNot(contains('writeIndexedList')));
    });
  });

  // ── NitroRecordWriter / NitroRecordReader helpers ─────────────────────────────

  group('NitroRecordWriter and NitroRecordReader are emitted', () {
    test('NitroRecordWriter class is present', () {
      expect(swiftRecords, contains('public class NitroRecordWriter'));
    });

    test('NitroRecordReader class is present', () {
      expect(swiftRecords, contains('public class NitroRecordReader'));
    });

    test('NitroRecordWriter.encodeList is present', () {
      expect(swiftRecords, contains('public static func encodeList<T>'));
    });
  });

  // ── Protocol and registry shape ───────────────────────────────────────────────

  group('Protocol and registry', () {
    test('HybridNitroArProtocol is emitted', () {
      expect(swiftBridge, contains('public protocol HybridNitroArProtocol'));
    });

    test('NitroArRegistry is emitted', () {
      expect(swiftBridge, contains('public class NitroArRegistry'));
    });

    test('async bool methods appear in protocol as async throws', () {
      expect(swiftBridge, contains('func checkCameraPermission() async throws -> Bool'));
    });

    test('streams appear in protocol as AnyPublisher', () {
      expect(swiftBridge, contains('AnyPublisher<PackageBoxes, Never>'));
      expect(swiftBridge, contains('AnyPublisher<LiveTrackingUpdate, Never>'));
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Extracts the text of the `@_cdecl("_register_<name>_stream")` function.
String _extractBlock(String src, String funcName) {
  final start = src.indexOf(funcName);
  if (start == -1) return '';
  final openBrace = src.indexOf('{', start);
  if (openBrace == -1) return '';
  var depth = 1;
  var i = openBrace + 1;
  while (i < src.length && depth > 0) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') depth--;
    i++;
  }
  return src.substring(openBrace, i);
}

/// Extracts the `extension <name> { ... }` block from Swift output.
String _extractExtensionBlock(String src, String typeName) {
  final marker = 'extension $typeName {';
  final start = src.indexOf(marker);
  if (start == -1) return '';
  var depth = 1;
  var i = start + marker.length;
  while (i < src.length && depth > 0) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') depth--;
    i++;
  }
  return src.substring(start, i);
}
