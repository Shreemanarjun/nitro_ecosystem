/// Backpressure.batch for @HybridRecord / @NitroVariant / numeric streams on a
/// Kotlin/Swift spec: native posts one framed item per emit (exactly like
/// dropLatest), the C bridge binds the port to the completion batcher, and
/// Dart receives `[item, item, ...]` per wake and acks each message.
library;

import 'package:nitro_annotations/nitro_annotations.dart' show NativeImpl, Backpressure;
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeRecordType _logEntry() => BridgeRecordType(
  name: 'LogEntry',
  fields: [
    BridgeRecordField(name: 'level', dartType: 'int', kind: RecordFieldKind.primitive),
    BridgeRecordField(name: 'message', dartType: 'String', kind: RecordFieldKind.primitive),
  ],
);

BridgeVariant _netEvent() => BridgeVariant(
  name: 'NetEvent',
  cases: [
    BridgeVariantCase(
      name: 'Connected',
      label: 'connected',
      fields: [],
    ),
    BridgeVariantCase(
      name: 'DataReceived',
      label: 'dataReceived',
      fields: [
        BridgeRecordField(name: 'bytes', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
);

BridgeSpec _recordBatchSpec() => BridgeSpec(
  dartClassName: 'LogService',
  lib: 'log_service',
  namespace: 'log_service',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'log_service.native.dart',
  recordTypes: [_logEntry()],
  streams: [
    BridgeStream(
      dartName: 'logStream',
      registerSymbol: 'log_service_register_logStream_stream',
      releaseSymbol: 'log_service_release_logStream_stream',
      isMethodStyle: false,
      isAnnotated: true,
      backpressure: Backpressure.batch,
      batchMaxSize: 32,
      itemType: BridgeType(name: 'LogEntry', isRecord: true),
    ),
  ],
);

BridgeSpec _variantBatchSpec() => BridgeSpec(
  dartClassName: 'NetMonitor',
  lib: 'net_monitor',
  namespace: 'net_monitor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'net_monitor.native.dart',
  variants: [_netEvent()],
  streams: [
    BridgeStream(
      dartName: 'events',
      registerSymbol: 'net_monitor_register_events_stream',
      releaseSymbol: 'net_monitor_release_events_stream',
      isMethodStyle: false,
      isAnnotated: true,
      backpressure: Backpressure.batch,
      batchMaxSize: 16,
      itemType: BridgeType(name: 'NetEvent'),
    ),
  ],
);

void main() {
  final record = _recordBatchSpec();
  final variant = _variantBatchSpec();
  final numeric = BridgeSpec(
    dartClassName: 'Sensor',
    lib: 'sensor',
    namespace: 'sensor',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'sensor.native.dart',
    streams: [
      BridgeStream(
        dartName: 'readings',
        registerSymbol: 'sensor_register_readings_stream',
        releaseSymbol: 'sensor_release_readings_stream',
        isMethodStyle: false,
        isAnnotated: true,
        backpressure: Backpressure.batch,
        batchMaxSize: 128,
        itemType: BridgeType(name: 'double'),
      ),
    ],
  );

  test('validator: batch is accepted for record, variant and numeric items', () {
    for (final spec in [record, variant, numeric]) {
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    }
  });

  group('Dart FFI', () {
    test('record batch: list of per-item decodes, each freed, acked', () {
      final dart = DartFfiGenerator.generate(record);
      expect(dart, contains('openStream<LogEntry>('));
      expect(dart, contains('coalesced: true,'));
      expect(dart, contains('_nitroFree(rawPtr)'));
      expect(dart, contains('ack: _nitroAckPtr,'));
      expect(dart, isNot(contains('openStream<Uint8List>')));
      expect(dart, isNot(contains('RecordReader.decodeList')));
    });

    test('variant batch: same shape with the variant decoder', () {
      final dart = DartFfiGenerator.generate(variant);
      expect(dart, contains('openStream<NetEvent>('));
      expect(dart, contains('NetEventVariantExt.fromNative(rawPtr)'));
      expect(dart, contains('ack: _nitroAckPtr,'));
    });

    test('numeric batch: List<double>, no [count, items...] unpack', () {
      final dart = DartFfiGenerator.generate(numeric);
      expect(dart, contains('openStream<double>('));
      expect(dart, isNot(contains('final count = batch[0];')));
    });
  });

  group('Kotlin', () {
    test('record and variant items are encoded and emitted one at a time', () {
      final kt = KotlinGenerator.generate(record);
      expect(kt, contains('external fun emit_logStream(dartPort: Long, item: ByteArray): Boolean'));
      expect(kt, contains('.encode()'));
      expect(kt, isNot(contains('_bytes_batch')));
      expect(kt, isNot(contains('_flushJob')));
      final ktv = KotlinGenerator.generate(variant);
      expect(ktv, contains('external fun emit_events(dartPort: Long, item: ByteArray): Boolean'));
    });

    test('numeric items keep their scalar JNI signature', () {
      final kt = KotlinGenerator.generate(numeric);
      expect(kt, contains('external fun emit_readings(dartPort: Long, item: Double): Boolean'));
      expect(kt, isNot(contains('LongArray')));
      expect(kt, isNot(contains('ArrayList<Long>')));
    });
  });

  group('Swift', () {
    test('no batch accumulator; the per-item sink registers the stream', () {
      for (final (spec, name) in [(record, 'logStream'), (variant, 'events'), (numeric, 'readings')]) {
        final swift = SwiftGenerator.generate(spec);
        expect(swift, isNot(contains('emitBatch')), reason: name);
        expect(swift, contains('_${spec.namespace}_register_${name}_stream'), reason: name);
      }
    });
  });

  group('C bridge', () {
    test('register binds the port to the batcher, release unbinds it', () {
      for (final spec in [record, variant, numeric]) {
        final cpp = CppBridgeGenerator.generate(spec);
        // record / variant items are heap blobs: registered with their free function
        expect(cpp, contains('g_nitro_batch_${spec.lib}.coalesce(dart_port'));
        expect(cpp, contains('g_nitro_batch_${spec.lib}.uncoalesce(dart_port);'));
        expect(cpp, isNot(contains('_batch_to_dart')));
        expect(cpp, isNot(contains('_1batch(')));
      }
    });

    test('record items are freed through <lib>_nitro_free, numeric items own nothing', () {
      expect(CppBridgeGenerator.generate(record), contains('coalesce(dart_port, [](int64_t a) { log_service_nitro_free((void*)(intptr_t)a); });'));
      expect(CppBridgeGenerator.generate(numeric), contains('g_nitro_batch_sensor.coalesce(dart_port);'));
    });

    test('JNI emit for record items takes one jbyteArray', () {
      final cpp = CppBridgeGenerator.generate(record);
      expect(cpp, contains('jbyteArray item)'));
      expect(cpp, isNot(contains('jbyteArray batch)')));
    });
  });
}
