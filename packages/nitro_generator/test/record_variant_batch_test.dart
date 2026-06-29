/// Tests for L3 — Backpressure.batch for @HybridRecord and @NitroVariant streams.
///
/// Wire format: [4B outer_len][4B count][item0 raw bytes][item1 raw bytes]...
/// where raw bytes = writeFields() output (no per-item length prefix).
/// Native posts as kTypedData/kUint8; Dart receives Uint8List.
/// Dart decode: copy to malloc, call RecordReader.decodeList, free.
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
  // ── §28: L3 — Backpressure.batch for @HybridRecord ───────────────────────

  group('§28: L3 — Backpressure.batch for @HybridRecord streams', () {
    late String dartCode;
    late String kotlinCode;
    late String swiftCode;
    late String cCode;

    setUpAll(() {
      final spec = _recordBatchSpec();
      dartCode = DartFfiGenerator.generate(spec);
      kotlinCode = KotlinGenerator.generate(spec);
      swiftCode = SwiftGenerator.generate(spec);
      cCode = CppBridgeGenerator.generate(spec);
    });

    test('Spec validates without E005', () {
      expect(SpecValidator.validate(_recordBatchSpec()).where((i) => i.code == 'E005'), isEmpty);
    });

    test('Spec validates without any errors', () {
      expect(SpecValidator.validate(_recordBatchSpec()).where((i) => i.isError), isEmpty);
    });

    group('Dart FFI', () {
      test('stream is typed as Uint8List batch', () {
        expect(dartCode, contains('NitroRuntime.openStream<Uint8List>'));
      });

      test('unpack casts message as Uint8List', () {
        expect(dartCode, contains('unpack: (message) => message as Uint8List'));
      });

      test('asyncExpand copies batch to malloc ptr', () {
        expect(dartCode, contains('final ptr = malloc<Uint8>(batch.length)'));
        expect(dartCode, contains('ptr.asTypedList(batch.length).setAll(0, batch)'));
      });

      test('decode uses RecordReader.decodeList with fromReader', () {
        expect(dartCode, contains('RecordReader.decodeList(ptr, (r) => LogEntryExt.fromReader(r))'));
      });

      test('malloc.free is called in finally block', () {
        expect(dartCode, contains('malloc.free(ptr)'));
      });

      test('stream return type is Stream<LogEntry>', () {
        expect(dartCode, contains('Stream<LogEntry> get logStream'));
      });
    });

    group('Kotlin', () {
      test('external emit uses ByteArray (not LongArray)', () {
        expect(kotlinCode, contains('emit_logStream_bytes_batch(dartPort: Long, batch: ByteArray): Boolean'));
        expect(kotlinCode, isNot(contains('emit_logStream_batch(dartPort: Long, batch: LongArray)')));
      });

      test('batch collect accumulates ArrayList<ByteArray>', () {
        expect(kotlinCode, contains('ArrayList<ByteArray>(32)'));
      });

      test('batch collect calls item.writeFields(_iw)', () {
        expect(kotlinCode, contains('item.writeFields(_iw)'));
        expect(kotlinCode, contains('_buf.add(_iw.toByteArray())'));
      });

      test('flush writes 4B outer_len then 4B count', () {
        expect(kotlinCode, contains('_tmp.putInt(4 + totalBytes)'));
        expect(kotlinCode, contains('_tmp.putInt(_buf.size)'));
      });

      test('flush calls emit_logStream_bytes_batch', () {
        expect(kotlinCode, contains('emit_logStream_bytes_batch(dartPort, _out.toByteArray())'));
      });

      test('batch max size is respected', () {
        expect(kotlinCode, contains('_buf.size >= 32'));
      });
    });

    group('Swift', () {
      test('register function uses UInt8 emit callback type', () {
        expect(swiftCode, contains('@convention(c) (Int64, UnsafeMutablePointer<UInt8>?, Int32) -> Bool'));
      });

      test('accumulates item bytes in [[UInt8]]', () {
        expect(swiftCode, contains('var _itemBytes = [[UInt8]]()'));
      });

      test('writes item fields to NitroRecordWriter', () {
        expect(swiftCode, contains('let _iw = NitroRecordWriter()'));
        expect(swiftCode, contains('item.writeFields(_iw)'));
        expect(swiftCode, contains('_itemBytes.append(_iw.bytes)'));
      });

      test('flush builds LE32 prefixed batch', () {
        expect(swiftCode, contains('appendLE32(Int32(4 + totalItemBytes))'));
        expect(swiftCode, contains('appendLE32(Int32(items.count))'));
      });

      test('flush allocates and emits ptr', () {
        expect(swiftCode, contains('UnsafeMutablePointer<UInt8>.allocate(capacity: batch.count)'));
        expect(swiftCode, contains('emitBatch(dartPort, ptr, Int32(batch.count))'));
        expect(swiftCode, contains('ptr.deallocate()'));
      });
    });

    group('C bridge', () {
      test('JNI emit function takes jbyteArray batch', () {
        expect(cCode, contains('jbyteArray batch'));
      });

      test('JNI emit function posts kTypedData/kUint8', () {
        expect(cCode, contains('Dart_TypedData_kUint8'));
        expect(cCode, contains('GetByteArrayElements(batch, nullptr)'));
        expect(cCode, contains('ReleaseByteArrayElements(batch, bytes, JNI_ABORT)'));
      });

      test('Swift shim emit function takes uint8_t* bytes', () {
        expect(cCode, contains('const uint8_t* bytes, int32_t len'));
        expect(cCode, contains('_emit_logStream_bytes_batch_to_dart'));
      });

      test('Swift shim register extern has uint8_t* callback signature', () {
        expect(cCode, contains('bool (*emitBatch)(int64_t, const uint8_t*, int32_t)'));
      });
    });
  });

  // ── §29: L3 edge — Backpressure.batch for @NitroVariant ──────────────────

  group('§29: L3 edge — Backpressure.batch for @NitroVariant streams', () {
    late String dartCode;
    late String kotlinCode;
    late String swiftCode;

    setUpAll(() {
      final spec = _variantBatchSpec();
      dartCode = DartFfiGenerator.generate(spec);
      kotlinCode = KotlinGenerator.generate(spec);
      swiftCode = SwiftGenerator.generate(spec);
    });

    test('Spec validates without E005', () {
      expect(SpecValidator.validate(_variantBatchSpec()).where((i) => i.code == 'E005'), isEmpty);
    });

    group('Dart FFI', () {
      test('decode uses decodeList with VariantExt.fromReader', () {
        expect(dartCode, contains('RecordReader.decodeList(ptr, (r) => NetEventVariantExt.fromReader(r))'));
      });

      test('stream typed as Uint8List batch', () {
        expect(dartCode, contains('NitroRuntime.openStream<Uint8List>'));
      });
    });

    group('Kotlin', () {
      test('external emit uses ByteArray for variant batch', () {
        expect(kotlinCode, contains('emit_events_bytes_batch(dartPort: Long, batch: ByteArray): Boolean'));
      });

      test('variant batch collect uses item.writeFields(_iw)', () {
        expect(kotlinCode, contains('item.writeFields(_iw)'));
      });
    });

    group('Swift', () {
      test('variant batch uses writeFields(to:) for @NitroVariant', () {
        expect(swiftCode, contains('item.writeFields(to: _iw)'));
      });

      test('variant batch uses [[UInt8]] buffer', () {
        expect(swiftCode, contains('var _itemBytes = [[UInt8]]()'));
      });
    });
  });

  // ── §30: L3 contrast — numeric batch unchanged ───────────────────────────

  group('§30: L3 contrast — numeric batch streams unchanged', () {
    late String dartCode;
    late String kotlinCode;

    setUpAll(() {
      final spec = BridgeSpec(
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
      dartCode = DartFfiGenerator.generate(spec);
      kotlinCode = KotlinGenerator.generate(spec);
    });

    test('numeric batch still uses List<int> not Uint8List', () {
      expect(dartCode, contains('NitroRuntime.openStream<List<int>>'));
      expect(dartCode, isNot(contains('NitroRuntime.openStream<Uint8List>')));
    });

    test('numeric batch decode does not use RecordReader', () {
      expect(dartCode, isNot(contains('RecordReader.decodeList')));
    });

    test('numeric batch Kotlin uses LongArray', () {
      expect(kotlinCode, contains('emit_readings_batch(dartPort: Long, batch: LongArray): Boolean'));
      expect(kotlinCode, isNot(contains('emit_readings_bytes_batch')));
    });

    test('numeric batch Kotlin uses ArrayList<Long>', () {
      expect(kotlinCode, contains('ArrayList<Long>(128)'));
    });
  });
}
