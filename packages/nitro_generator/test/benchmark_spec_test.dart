// Tests that exercise all generators against specs that mirror the real
// benchmark module (benchmark.native.dart / benchmark_cpp.native.dart).
// These act as integration-style regression guards: if a generator changes
// the shape of output for any of the types the benchmark uses, these tests
// will catch it before the generated files on disk go stale.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:test/test.dart';

// ── Shared spec helpers ───────────────────────────────────────────────────────

/// Mirrors benchmark.native.dart — Kotlin/Swift bridge, uses all major type
/// categories the benchmark exercises: primitives, structs, @HybridRecord,
/// TypedData, and streams.
BridgeSpec _benchmarkSpec() => BridgeSpec(
  dartClassName: 'Benchmark',
  lib: 'benchmark',
  namespace: 'benchmark_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'benchmark.native.dart',
  structs: [
    BridgeStruct(
      name: 'BenchmarkPoint',
      packed: true,
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
      name: 'BenchmarkBox',
      packed: true,
      fields: [
        BridgeField(
          name: 'color',
          type: BridgeType(name: 'int'),
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
    BridgeRecordType(
      name: 'BenchmarkStats',
      fields: [
        BridgeRecordField(name: 'count', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'meanUs', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'minUs', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'maxUs', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'benchmark_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'addFast',
      cSymbol: 'benchmark_add_fast',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'getGreeting',
      cSymbol: 'benchmark_get_greeting',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'name',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'scalePoint',
      cSymbol: 'benchmark_scale_point',
      isAsync: false,
      returnType: BridgeType(name: 'BenchmarkPoint'),
      params: [
        BridgeParam(
          name: 'point',
          type: BridgeType(name: 'BenchmarkPoint'),
        ),
        BridgeParam(
          name: 'factor',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'computeStats',
      cSymbol: 'benchmark_compute_stats',
      isAsync: true,
      returnType: BridgeType(name: 'BenchmarkStats', isRecord: true),
      params: [
        BridgeParam(
          name: 'iterations',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'sendLargeBuffer',
      cSymbol: 'benchmark_send_large_buffer',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'buffer',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'dataStream',
      registerSymbol: 'benchmark_register_data_stream_stream',
      releaseSymbol: 'benchmark_release_data_stream_stream',
      itemType: BridgeType(name: 'BenchmarkPoint'),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'boxStream',
      registerSymbol: 'benchmark_register_box_stream_stream',
      releaseSymbol: 'benchmark_release_box_stream_stream',
      itemType: BridgeType(name: 'BenchmarkBox'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// Mirrors benchmark_cpp.native.dart — NativeImpl.cpp on both platforms;
/// adds sendLargeBufferFast (Uint8List), sendLargeBufferNoop, and
/// sendLargeBufferUnsafe (Pointer`<Uint8>` raw ptr).
BridgeSpec _benchmarkCppSpec() => BridgeSpec(
  dartClassName: 'BenchmarkCpp',
  lib: 'benchmark_cpp',
  namespace: 'benchmark_cpp_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'benchmark_cpp.native.dart',
  structs: [
    BridgeStruct(
      name: 'BenchmarkPoint',
      packed: true,
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
      name: 'BenchmarkBox',
      packed: true,
      fields: [
        BridgeField(
          name: 'color',
          type: BridgeType(name: 'int'),
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
    BridgeRecordType(
      name: 'BenchmarkStats',
      fields: [
        BridgeRecordField(name: 'count', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'meanUs', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'minUs', dartType: 'double', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'maxUs', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'benchmark_cpp_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'addFast',
      cSymbol: 'benchmark_cpp_add_fast',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'getGreeting',
      cSymbol: 'benchmark_cpp_get_greeting',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'name',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'scalePoint',
      cSymbol: 'benchmark_cpp_scale_point',
      isAsync: false,
      returnType: BridgeType(name: 'BenchmarkPoint'),
      params: [
        BridgeParam(
          name: 'point',
          type: BridgeType(name: 'BenchmarkPoint'),
        ),
        BridgeParam(
          name: 'factor',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'computeStats',
      cSymbol: 'benchmark_cpp_compute_stats',
      isAsync: true,
      returnType: BridgeType(name: 'BenchmarkStats', isRecord: true),
      params: [
        BridgeParam(
          name: 'iterations',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'sendLargeBufferFast',
      cSymbol: 'benchmark_cpp_send_large_buffer_fast',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'buffer',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'sendLargeBufferNoop',
      cSymbol: 'benchmark_cpp_send_large_buffer_noop',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'buffer',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'sendLargeBufferUnsafe',
      cSymbol: 'benchmark_cpp_send_large_buffer_unsafe',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'ptr',
          type: BridgeType(name: 'Pointer<Uint8>', isPointer: true, pointerInnerType: 'Uint8'),
        ),
        BridgeParam(
          name: 'length',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'dataStream',
      registerSymbol: 'benchmark_cpp_register_data_stream_stream',
      releaseSymbol: 'benchmark_cpp_release_data_stream_stream',
      itemType: BridgeType(name: 'BenchmarkPoint'),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'boxStream',
      registerSymbol: 'benchmark_cpp_register_box_stream_stream',
      releaseSymbol: 'benchmark_cpp_release_box_stream_stream',
      itemType: BridgeType(name: 'BenchmarkBox'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── KotlinGenerator ───────────────────────────────────────────────────────────

void main() {
  group('KotlinGenerator — benchmark spec', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_benchmarkSpec()));

    test('package is nitro.benchmark_module', () {
      expect(out, contains('package nitro.benchmark_module'));
    });

    test('interface is HybridBenchmarkSpec', () {
      expect(out, contains('interface HybridBenchmarkSpec'));
    });

    test('add is a regular fun returning Double', () {
      expect(out, contains('fun add(a: Double, b: Double): Double'));
    });

    test('addFast is a regular fun returning Double', () {
      expect(out, contains('fun addFast(a: Double, b: Double): Double'));
    });

    test('getGreeting takes and returns String', () {
      expect(out, contains('fun getGreeting(name: String): String'));
    });

    test('scalePoint takes BenchmarkPoint struct and Double, returns BenchmarkPoint', () {
      expect(out, contains('fun scalePoint(point: BenchmarkPoint, factor: Double): BenchmarkPoint'));
    });

    test('computeStats is suspend and returns BenchmarkStats', () {
      expect(out, contains('suspend fun computeStats(iterations: Long): BenchmarkStats'));
    });

    test('sendLargeBuffer takes ByteArray and returns Long', () {
      expect(out, contains('fun sendLargeBuffer(buffer: ByteArray): Long'));
    });

    test('dataStream property is Flow<BenchmarkPoint>', () {
      expect(out, contains('val dataStream: Flow<BenchmarkPoint>'));
    });

    test('boxStream property is Flow<BenchmarkBox>', () {
      expect(out, contains('val boxStream: Flow<BenchmarkBox>'));
    });

    test('computeStats_call bridge method returns ByteArray (HybridRecord)', () {
      expect(out, contains('fun computeStats_call(iterations: Long): ByteArray'));
    });

    test('sendLargeBuffer_call bridge method returns Long', () {
      expect(out, contains('fun sendLargeBuffer_call(buffer: ByteArray): Long'));
    });

    test('data stream register bridge method emitted', () {
      expect(out, contains('fun benchmark_register_data_stream_stream_call(dartPort: Long)'));
    });

    test('BenchmarkStats record data class has all four fields', () {
      expect(out, contains('data class BenchmarkStats('));
      expect(out, contains('val count: Long'));
      expect(out, contains('val meanUs: Double'));
      expect(out, contains('val minUs: Double'));
      expect(out, contains('val maxUs: Double'));
    });

    test('BenchmarkPoint struct data class has x and y Double fields', () {
      expect(out, contains('data class BenchmarkPoint(val x: Double, val y: Double)'));
    });

    test('BenchmarkBox struct data class has color Long and dimension Double fields', () {
      expect(out, contains('data class BenchmarkBox(val color: Long, val width: Double, val height: Double)'));
    });

    test('BenchmarkStats has decode() companion method', () {
      expect(out, contains('fun decode(bytes: ByteArray): BenchmarkStats'));
    });

    test('BenchmarkStats encode() returns ByteArray with 4-byte length prefix', () {
      expect(out, contains('fun encode(): ByteArray'));
      expect(out, contains('lenBuf.putInt(payload.size)'));
    });
  });

  // ── SwiftGenerator ──────────────────────────────────────────────────────────

  group('SwiftGenerator — benchmark spec', () {
    late String out;
    setUpAll(() => out = SwiftGenerator.generate(_benchmarkSpec()));

    test('protocol is HybridBenchmarkProtocol', () {
      expect(out, contains('public protocol HybridBenchmarkProtocol'));
    });

    test('add function signature', () {
      expect(out, contains('func add(a: Double, b: Double) -> Double'));
    });

    test('scalePoint uses BenchmarkPoint struct type', () {
      expect(out, contains('func scalePoint(point: BenchmarkPoint, factor: Double) -> BenchmarkPoint'));
    });

    test('computeStats is async throws returning BenchmarkStats', () {
      expect(out, contains('func computeStats(iterations: Int64) async throws -> BenchmarkStats'));
    });

    test('sendLargeBuffer takes Data (Uint8List) and returns Int64', () {
      expect(out, contains('func sendLargeBuffer(buffer: Data) -> Int64'));
    });

    test('dataStream is AnyPublisher<BenchmarkPoint, Never>', () {
      expect(out, contains('var dataStream: AnyPublisher<BenchmarkPoint, Never>'));
    });

    test('sendLargeBuffer @_cdecl uses UnsafeMutablePointer<UInt8>? + Int64 length', () {
      expect(out, contains('_ buffer: UnsafeMutablePointer<UInt8>?'));
      expect(out, contains('_ buffer_length: Int64'));
    });

    test('stream sink uses ptr.initialize for struct items', () {
      expect(out, contains('ptr.initialize(to: item)'));
    });
  });

  // ── DartFfiGenerator ────────────────────────────────────────────────────────

  group('DartFfiGenerator — benchmark spec', () {
    late String out;
    setUpAll(() => out = DartFfiGenerator.generate(_benchmarkSpec()));

    test('loads library benchmark', () {
      expect(out, contains("NitroRuntime.loadLib('benchmark')"));
    });

    test('add uses lookupFunction with correct symbol', () {
      expect(out, contains("lookupFunction<Double Function(Double, Double), double Function(double, double)>('benchmark_add')"));
    });

    test('addFast uses lookup + asFunction with isLeaf: true', () {
      expect(out, contains("('benchmark_add_fast')"));
      expect(out, contains('isLeaf: true'));
    });

    test('sendLargeBuffer lookup includes Int64 length param', () {
      expect(out, contains('Int64 Function(Pointer<Uint8>, Int64)'));
    });

    test('sendLargeBuffer call site passes buffer and buffer.length', () {
      expect(out, contains('_sendLargeBufferPtr(buffer.toPointer(arena), buffer.length)'));
    });

    test('computeStats uses NitroRuntime.callAsync (async HybridRecord)', () {
      expect(out, contains('NitroRuntime.callAsync'));
    });

    test('add method has checkDisposed() immediately after opening brace', () {
      expect(out, contains('double add(double a, double b) {\n    checkDisposed();'));
    });

    test('dataStream getter has checkDisposed()', () {
      expect(out, contains('Stream<BenchmarkPoint> get dataStream {\n    checkDisposed();'));
    });

    test('streams use backpressure: Backpressure.dropLatest', () {
      final matches = RegExp('backpressure: Backpressure\\.dropLatest').allMatches(out).length;
      expect(matches, equals(2), reason: 'both dataStream and boxStream must use dropLatest');
    });

    test('dataStream register symbol is correct', () {
      expect(out, contains("'benchmark_register_data_stream_stream'"));
    });

    test('boxStream register symbol is correct', () {
      expect(out, contains("'benchmark_register_box_stream_stream'"));
    });

    test('struct stream unpack uses Pointer.fromAddress + toDart()', () {
      expect(out, contains('Pointer<BenchmarkPointFfi>.fromAddress(rawPtr)'));
    });
  });

  // ── CppInterfaceGenerator — benchmark_cpp ───────────────────────────────────

  group('CppInterfaceGenerator — benchmark_cpp spec', () {
    late String out;
    setUpAll(() => out = CppInterfaceGenerator.generate(_benchmarkCppSpec()));

    test('abstract class name is HybridBenchmarkCpp', () {
      expect(out, contains('class HybridBenchmarkCpp'));
    });

    test('add pure-virtual signature', () {
      expect(out, contains('virtual double add(double a, double b) = 0;'));
    });

    test('addFast pure-virtual signature', () {
      expect(out, contains('virtual double addFast(double a, double b) = 0;'));
    });

    test('getGreeting takes const std::string& and returns std::string', () {
      expect(out, contains('virtual std::string getGreeting(const std::string& name) = 0;'));
    });

    test('scalePoint takes const BenchmarkPoint& and returns BenchmarkPoint', () {
      expect(out, contains('virtual BenchmarkPoint scalePoint(const BenchmarkPoint& point, double factor) = 0;'));
    });

    test('computeStats takes int64_t and returns NitroCppBuffer (async HybridRecord)', () {
      expect(out, contains('virtual NitroCppBuffer computeStats(int64_t iterations) = 0;'));
    });

    test('sendLargeBufferFast expands Uint8List to const uint8_t* + size_t length', () {
      expect(out, contains('virtual int64_t sendLargeBufferFast(const uint8_t* buffer, size_t buffer_length) = 0;'));
    });

    test('sendLargeBufferUnsafe Pointer<Uint8> maps to void* param', () {
      expect(out, contains('virtual int64_t sendLargeBufferUnsafe(void* ptr, int64_t length) = 0;'));
    });

    test('registration API uses HybridBenchmarkCpp type', () {
      expect(out, contains('void benchmark_cpp_register_impl(HybridBenchmarkCpp* impl);'));
    });

    test('header guard uses BENCHMARK_CPP prefix', () {
      expect(out, contains('#ifndef BENCHMARK_CPP_NATIVE_G_H'));
    });
  });

  // ── CppBridgeGenerator — benchmark_cpp (direct dispatch path) ───────────────

  group('CppBridgeGenerator — benchmark_cpp spec (C++ direct dispatch)', () {
    late String out;
    setUpAll(() => out = CppBridgeGenerator.generate(_benchmarkCppSpec()));

    test('uses g_impl->add for virtual dispatch', () {
      expect(out, contains('g_impl->add(a, b)'));
    });

    test('computeStats returns void* (NitroCppBuffer wrapped)', () {
      expect(out, contains('void* benchmark_cpp_compute_stats(int64_t iterations)'));
    });

    test('sendLargeBufferFast has uint8_t* + int64_t length', () {
      expect(out, contains('int64_t benchmark_cpp_send_large_buffer_fast(uint8_t* buffer, int64_t buffer_length)'));
    });

    test('sendLargeBufferUnsafe Pointer<Uint8> param passes as void*', () {
      expect(out, contains('int64_t benchmark_cpp_send_large_buffer_unsafe(void* ptr, int64_t length)'));
    });

    test('stream ports use plain int64_t storage (written once at startup)', () {
      // g_port_ is plain int64_t — written once during registration and read under
      // the same thread model; no std::atomic overhead needed.
      expect(out, contains('static int64_t g_port_dataStream = 0;'));
    });

    test('dataStream register function signature', () {
      expect(out, contains('void benchmark_cpp_register_data_stream_stream(int64_t dart_port)'));
    });

    test('stream emit reads port via direct variable access', () {
      expect(out, contains('int64_t port = g_port_dataStream;'));
    });

    test('addFast skips error check (isFast path)', () {
      final addFastBlock = out.substring(out.indexOf('benchmark_cpp_add_fast'));
      final nextFunc = addFastBlock.indexOf('\n}');
      final body = addFastBlock.substring(0, nextFunc);
      expect(body, isNot(contains('checkError')));
    });
  });
}
