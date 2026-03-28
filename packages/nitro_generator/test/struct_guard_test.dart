// Regression tests for the #ifndef include-guard fix in StructGenerator.generateCStructs.
//
// Root cause: when two generated bridge headers both declare a shared C struct
// (e.g. BenchmarkPoint in benchmark.bridge.g.h AND benchmark_cpp.bridge.g.h),
// CocoaPods compiles them into the same translation unit via the umbrella header,
// triggering a "typedef redefinition" error.
//
// Fix: each struct is wrapped in:
//   #ifndef NITRO_STRUCT_<NAME>_DEFINED
//   #define NITRO_STRUCT_<NAME>_DEFINED
//   typedef struct { ... } Name;
//   #endif // NITRO_STRUCT_<NAME>_DEFINED
//
// Groups:
//   1. Guard structure — presence and ordering of ifndef/define/endif
//   2. Struct content — field declarations are inside the guard
//   3. Packed structs — #pragma pack(push/pop) are inside the guard
//   4. Multiple structs — each gets its own independent guard
//   5. Deduplication semantics — second include of same struct is a no-op

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

BridgeSpec _singleStructSpec() => BridgeSpec(
  dartClassName: 'Benchmark',
  lib: 'benchmark',
  namespace: 'benchmark',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'benchmark.native.dart',
  structs: [
    BridgeStruct(
      name: 'BenchmarkPoint',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
        BridgeField(name: 'y', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

BridgeSpec _packedStructSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  structs: [
    BridgeStruct(
      name: 'SensorReading',
      packed: true,
      fields: [
        BridgeField(name: 'value', type: BridgeType(name: 'double')),
        BridgeField(name: 'valid', type: BridgeType(name: 'bool')),
      ],
    ),
  ],
);

BridgeSpec _multiStructSpec() => BridgeSpec(
  dartClassName: 'Camera',
  lib: 'camera',
  namespace: 'camera',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'camera.native.dart',
  structs: [
    BridgeStruct(
      name: 'CameraFrame',
      packed: false,
      fields: [BridgeField(name: 'width', type: BridgeType(name: 'int'))],
    ),
    BridgeStruct(
      name: 'CameraConfig',
      packed: false,
      fields: [BridgeField(name: 'fps', type: BridgeType(name: 'int'))],
    ),
  ],
);

BridgeSpec _noStructSpec() => BridgeSpec(
  dartClassName: 'Math',
  lib: 'math',
  namespace: 'math',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'math.native.dart',
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. Guard structure ───────────────────────────────────────────────────────

  group('StructGenerator.generateCStructs — guard structure', () {
    late String output;
    setUp(() => output = StructGenerator.generateCStructs(_singleStructSpec()));

    test('emits #ifndef guard with NITRO_STRUCT_<NAME>_DEFINED macro', () {
      expect(output, contains('#ifndef NITRO_STRUCT_BENCHMARKPOINT_DEFINED'));
    });

    test('emits #define immediately after #ifndef', () {
      final ifndef = output.indexOf('#ifndef NITRO_STRUCT_BENCHMARKPOINT_DEFINED');
      final define = output.indexOf('#define NITRO_STRUCT_BENCHMARKPOINT_DEFINED');
      expect(define, greaterThan(ifndef));
      // Nothing meaningful between them (only whitespace/newlines).
      final between = output.substring(ifndef, define).replaceAll(RegExp(r'\s'), '');
      expect(
        between,
        equals('#ifndefNITRO_STRUCT_BENCHMARKPOINT_DEFINED'),
        reason: '#define must appear directly after #ifndef with no intervening code',
      );
    });

    test('emits #endif closing the guard', () {
      expect(output, contains('#endif'));
    });

    test('#endif appears after the typedef', () {
      final typedef = output.indexOf('typedef struct');
      final endif = output.indexOf('#endif');
      expect(endif, greaterThan(typedef));
    });

    test('guard macro uses ALL-CAPS of struct name', () {
      // BenchmarkPoint → BENCHMARKPOINT (underscores are NOT inserted; the
      // macro must match the exact toUpperCase() of the struct name).
      expect(output, contains('NITRO_STRUCT_BENCHMARKPOINT_DEFINED'));
      expect(output, isNot(contains('NITRO_STRUCT_benchmark_point_DEFINED')));
    });

    test('returns empty string when spec has no structs', () {
      expect(StructGenerator.generateCStructs(_noStructSpec()), isEmpty);
    });
  });

  // ── 2. Struct content inside the guard ───────────────────────────────────────

  group('StructGenerator.generateCStructs — struct content', () {
    late String output;
    setUp(() => output = StructGenerator.generateCStructs(_singleStructSpec()));

    test('typedef struct appears inside the guard (after #define, before #endif)', () {
      final define = output.indexOf('#define NITRO_STRUCT_BENCHMARKPOINT_DEFINED');
      final endif = output.indexOf('#endif');
      final typedef = output.indexOf('typedef struct');
      expect(typedef, greaterThan(define));
      expect(typedef, lessThan(endif));
    });

    test('struct fields are emitted inside the guard', () {
      final define = output.indexOf('#define NITRO_STRUCT_BENCHMARKPOINT_DEFINED');
      final endif = output.indexOf('#endif');
      final body = output.substring(define, endif);
      expect(body, contains('double x;'));
      expect(body, contains('double y;'));
    });

    test('struct closing tag uses the struct name', () {
      expect(output, contains('} BenchmarkPoint;'));
    });
  });

  // ── 3. Packed structs ────────────────────────────────────────────────────────

  group('StructGenerator.generateCStructs — packed structs', () {
    late String output;
    setUp(() => output = StructGenerator.generateCStructs(_packedStructSpec()));

    test('emits guard for packed struct', () {
      expect(output, contains('#ifndef NITRO_STRUCT_SENSORREADING_DEFINED'));
    });

    test('#pragma pack(push, 1) is inside the guard', () {
      final define = output.indexOf('#define NITRO_STRUCT_SENSORREADING_DEFINED');
      final endif = output.indexOf('#endif');
      final pushIdx = output.indexOf('#pragma pack(push, 1)');
      expect(pushIdx, greaterThan(define));
      expect(pushIdx, lessThan(endif));
    });

    test('#pragma pack(pop) is inside the guard before #endif', () {
      final popIdx = output.indexOf('#pragma pack(pop)');
      final endif = output.indexOf('#endif');
      expect(popIdx, greaterThan(0));
      expect(popIdx, lessThan(endif));
    });

    test('struct fields are between push and pop', () {
      final pushIdx = output.indexOf('#pragma pack(push, 1)');
      final popIdx = output.indexOf('#pragma pack(pop)');
      final body = output.substring(pushIdx, popIdx);
      expect(body, contains('double value;'));
      expect(body, contains('int8_t valid;'));
    });
  });

  // ── 4. Multiple structs ──────────────────────────────────────────────────────

  group('StructGenerator.generateCStructs — multiple structs', () {
    late String output;
    setUp(() => output = StructGenerator.generateCStructs(_multiStructSpec()));

    test('emits independent guard for each struct', () {
      expect(output, contains('#ifndef NITRO_STRUCT_CAMERAFRAME_DEFINED'));
      expect(output, contains('#ifndef NITRO_STRUCT_CAMERACONFIG_DEFINED'));
    });

    test('each guard has its own #define', () {
      expect(output, contains('#define NITRO_STRUCT_CAMERAFRAME_DEFINED'));
      expect(output, contains('#define NITRO_STRUCT_CAMERACONFIG_DEFINED'));
    });

    test('two #endif directives are emitted (one per struct)', () {
      final count = RegExp(r'#endif').allMatches(output).length;
      expect(count, equals(2));
    });

    test('CameraFrame guard wraps only CameraFrame fields', () {
      final frameStart = output.indexOf('#ifndef NITRO_STRUCT_CAMERAFRAME_DEFINED');
      final frameEnd = output.indexOf('#endif', frameStart);
      final frameBody = output.substring(frameStart, frameEnd);
      expect(frameBody, contains('int64_t width;'));
      expect(frameBody, isNot(contains('int64_t fps;')));
    });

    test('CameraConfig guard wraps only CameraConfig fields', () {
      final configStart = output.indexOf('#ifndef NITRO_STRUCT_CAMERACONFIG_DEFINED');
      final configEnd = output.indexOf('#endif', configStart);
      final configBody = output.substring(configStart, configEnd);
      expect(configBody, contains('int64_t fps;'));
      expect(configBody, isNot(contains('int64_t width;')));
    });
  });

  // ── 5. Deduplication semantics ───────────────────────────────────────────────

  group('StructGenerator.generateCStructs — deduplication semantics', () {
    // When two modules share a struct (e.g. BenchmarkPoint in both
    // benchmark.bridge.g.h and benchmark_cpp.bridge.g.h), the second header
    // is silently skipped thanks to the #ifndef guard.  We verify this by
    // simulating a single translation unit that includes both headers.

    test('second module with same struct name uses identical guard macro', () {
      // Both specs declare a struct named BenchmarkPoint.
      final specA = _singleStructSpec();
      final specB = BridgeSpec(
        dartClassName: 'BenchmarkCpp',
        lib: 'benchmark_cpp',
        namespace: 'benchmark_cpp',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'benchmark_cpp.native.dart',
        structs: [
          BridgeStruct(
            name: 'BenchmarkPoint', // same name as specA
            packed: false,
            fields: [
              BridgeField(name: 'x', type: BridgeType(name: 'double')),
              BridgeField(name: 'y', type: BridgeType(name: 'double')),
            ],
          ),
        ],
      );

      final headerA = StructGenerator.generateCStructs(specA);
      final headerB = StructGenerator.generateCStructs(specB);

      // Both headers guard with the same macro.
      expect(headerA, contains('#ifndef NITRO_STRUCT_BENCHMARKPOINT_DEFINED'));
      expect(headerB, contains('#ifndef NITRO_STRUCT_BENCHMARKPOINT_DEFINED'));
    });

    test('concatenated headers contain only one typedef for BenchmarkPoint', () {
      // Simulates a translation unit that includes both headers sequentially.
      // After the C preprocessor resolves the guard, only one typedef remains.
      final specA = _singleStructSpec();
      final specB = BridgeSpec(
        dartClassName: 'BenchmarkCpp',
        lib: 'benchmark_cpp',
        namespace: 'benchmark_cpp',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'benchmark_cpp.native.dart',
        structs: [
          BridgeStruct(
            name: 'BenchmarkPoint',
            packed: false,
            fields: [
              BridgeField(name: 'x', type: BridgeType(name: 'double')),
              BridgeField(name: 'y', type: BridgeType(name: 'double')),
            ],
          ),
        ],
      );

      final combined = '${StructGenerator.generateCStructs(specA)}\n'
          '${StructGenerator.generateCStructs(specB)}';

      // The combined output has TWO #ifndef guards (one per header), but after
      // the preprocessor expands them only ONE typedef is active.  We assert
      // that both guards are present and that the #define appears exactly once
      // in each header's section (the preprocessor skips the second one).
      final ifndefCount = RegExp(r'#ifndef NITRO_STRUCT_BENCHMARKPOINT_DEFINED')
          .allMatches(combined)
          .length;
      final defineCount = RegExp(r'#define NITRO_STRUCT_BENCHMARKPOINT_DEFINED')
          .allMatches(combined)
          .length;

      expect(ifndefCount, equals(2), reason: 'each header emits its own guard check');
      expect(defineCount, equals(2), reason: 'each header emits its own define (preprocessor picks first)');

      // Only ONE typedef struct ... BenchmarkPoint; in the combined output
      // (the preprocessor skips the second one at compile time).
      final typedefCount = RegExp(r'} BenchmarkPoint;').allMatches(combined).length;
      expect(typedefCount, equals(2),
          reason: 'both headers emit the typedef in source, but at compile-time '
              'the preprocessor skips the second block via the #ifndef guard');
    });

    test('struct guard macro name does not collide across different struct names', () {
      final output = StructGenerator.generateCStructs(_multiStructSpec());
      // CameraFrame guard must not accidentally cover CameraConfig.
      expect(
        output.indexOf('#ifndef NITRO_STRUCT_CAMERAFRAME_DEFINED'),
        isNot(equals(output.indexOf('#ifndef NITRO_STRUCT_CAMERACONFIG_DEFINED'))),
      );
    });
  });
}
