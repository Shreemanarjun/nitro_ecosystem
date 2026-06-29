// Tests that all three Backpressure enum values flow correctly through
// the DartFfiGenerator, KotlinGenerator, and SwiftGenerator outputs.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _streamSpec(Backpressure bp) => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  streams: [
    BridgeStream(
      dartName: 'ticks',
      registerSymbol: 'sensor_register_ticks_stream',
      releaseSymbol: 'sensor_release_ticks_stream',
      itemType: BridgeType(name: 'double'),
      backpressure: bp,
    ),
  ],
);

BridgeSpec _multiStreamSpec() => BridgeSpec(
  dartClassName: 'Hub',
  lib: 'hub',
  namespace: 'hub_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'hub.native.dart',
  streams: [
    BridgeStream(
      dartName: 'fast',
      registerSymbol: 'hub_register_fast_stream',
      releaseSymbol: 'hub_release_fast_stream',
      itemType: BridgeType(name: 'double'),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'safe',
      registerSymbol: 'hub_register_safe_stream',
      releaseSymbol: 'hub_release_safe_stream',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.block,
    ),
    BridgeStream(
      dartName: 'buffered',
      registerSymbol: 'hub_register_buffered_stream',
      releaseSymbol: 'hub_release_buffered_stream',
      itemType: BridgeType(name: 'bool'),
      backpressure: Backpressure.bufferDrop,
    ),
  ],
);

void main() {
  group('DartFfiGenerator — stream backpressure', () {
    test('dropLatest backpressure emits Backpressure.dropLatest', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.dropLatest));
      expect(out, contains('Backpressure.dropLatest'));
    });

    test('block backpressure emits Backpressure.block', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.block));
      expect(out, contains('Backpressure.block'));
    });

    test('bufferDrop backpressure emits Backpressure.bufferDrop', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.bufferDrop));
      expect(out, contains('Backpressure.bufferDrop'));
    });

    test('each stream gets its own backpressure value in multi-stream spec', () {
      final out = DartFfiGenerator.generate(_multiStreamSpec());
      expect(out, contains('Backpressure.dropLatest'));
      expect(out, contains('Backpressure.block'));
      expect(out, contains('Backpressure.bufferDrop'));
    });

    test('dropLatest output does not contain block or bufferDrop', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.dropLatest));
      expect(out, isNot(contains('Backpressure.block')));
      expect(out, isNot(contains('Backpressure.bufferDrop')));
    });

    test('block output does not contain dropLatest or bufferDrop', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.block));
      expect(out, isNot(contains('Backpressure.dropLatest')));
      expect(out, isNot(contains('Backpressure.bufferDrop')));
    });

    test('bufferDrop output does not contain dropLatest or block', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.bufferDrop));
      expect(out, isNot(contains('Backpressure.dropLatest')));
      expect(out, isNot(contains('Backpressure.block')));
    });

    test('stream register symbol appears in generated output', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.dropLatest));
      expect(out, contains('sensor_register_ticks_stream'));
    });

    test('stream release symbol appears in generated output', () {
      final out = DartFfiGenerator.generate(_streamSpec(Backpressure.dropLatest));
      expect(out, contains('sensor_release_ticks_stream'));
    });
  });

  group('KotlinGenerator — stream backpressure', () {
    test('dropLatest stream appears in kotlin output', () {
      final out = KotlinGenerator.generate(_streamSpec(Backpressure.dropLatest));
      // Kotlin streams are declared as flow-like coroutines — register symbol present
      expect(out, contains('sensor_register_ticks_stream'));
    });

    test('multi-stream spec generates all three stream entries', () {
      final out = KotlinGenerator.generate(_multiStreamSpec());
      expect(out, contains('hub_register_fast_stream'));
      expect(out, contains('hub_register_safe_stream'));
      expect(out, contains('hub_register_buffered_stream'));
    });

    test('collector starts undispatched so immediate native emits are not missed', () {
      final out = KotlinGenerator.generate(_streamSpec(Backpressure.block));
      expect(out, contains('import kotlinx.coroutines.CoroutineStart'));
      expect(out, contains('launch(start = CoroutineStart.UNDISPATCHED)'));
    });
  });

  group('SwiftGenerator — stream backpressure', () {
    test('dropLatest stream register stub appears in swift output', () {
      final out = SwiftGenerator.generate(_streamSpec(Backpressure.dropLatest));
      // Swift uses @_cdecl("_register_ticks_stream") — the stream name without lib prefix
      expect(out, contains('_register_ticks_stream'));
    });

    test('multi-stream spec generates all three stream stubs in swift', () {
      final out = SwiftGenerator.generate(_multiStreamSpec());
      expect(out, contains('_register_fast_stream'));
      expect(out, contains('_register_safe_stream'));
      expect(out, contains('_register_buffered_stream'));
    });

    test('multi-stream spec generates release stubs for all streams in swift', () {
      final out = SwiftGenerator.generate(_multiStreamSpec());
      expect(out, contains('_release_fast_stream'));
      expect(out, contains('_release_safe_stream'));
      expect(out, contains('_release_buffered_stream'));
    });
  });

  // ── Point 5: String batch stream ──────────────────────────────────────────

  group('String batch stream — Point 5 fix', () {
    BridgeSpec stringBatchSpec() => BridgeSpec(
      dartClassName: 'Logger',
      lib: 'logger',
      namespace: 'logger',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'logger.native.dart',
      streams: [
        BridgeStream(
          dartName: 'logs',
          registerSymbol: 'logger_register_logs_stream',
          releaseSymbol: 'logger_release_logs_stream',
          itemType: BridgeType(name: 'String'),
          backpressure: Backpressure.batch,
          batchMaxSize: 16,
        ),
      ],
    );

    test('Kotlin: String batch uses Array<String> external (not LongArray)', () {
      final out = KotlinGenerator.generate(stringBatchSpec());
      expect(out, contains('emit_logs_string_batch(dartPort: Long, batch: Array<String>): Boolean'));
      expect(out, isNot(contains('emit_logs_batch(dartPort: Long, batch: LongArray)')));
    });

    test('Kotlin: String batch buffer is ArrayList<String> (not ArrayList<Long>)', () {
      final out = KotlinGenerator.generate(stringBatchSpec());
      expect(out, contains('ArrayList<String>('));
      expect(out, isNot(contains('ArrayList<Long>(')));
    });

    test('Kotlin: String batch _flush uses toTypedArray()', () {
      final out = KotlinGenerator.generate(stringBatchSpec());
      expect(out, contains('_buf.toTypedArray()'));
    });

    test('Kotlin: String batch collect adds item (no toLong/doubleToRawLongBits)', () {
      final out = KotlinGenerator.generate(stringBatchSpec());
      expect(out, contains('_buf.add(item)'));
      expect(out, isNot(contains('toLong()')));
      expect(out, isNot(contains('doubleToRawLongBits')));
    });

    test('Kotlin: String batch uses Mutex guard same as numeric batch', () {
      final out = KotlinGenerator.generate(stringBatchSpec());
      expect(out, contains('Mutex()'));
      expect(out, contains('_lock.withLock'));
    });

    test('Dart FFI: String batch uses asyncExpand with batch.cast<String>()', () {
      final out = DartFfiGenerator.generate(stringBatchSpec());
      expect(out, contains('batch.cast<String>()'));
      expect(out, contains('Backpressure.batch'));
    });

    test('Dart FFI: String batch openStream type is List<dynamic>', () {
      final out = DartFfiGenerator.generate(stringBatchSpec());
      expect(out, contains('openStream<List<dynamic>>'));
    });

    test('C bridge: String batch emits jobjectArray JNI handler (not jlongArray)', () {
      final out = CppBridgeGenerator.generate(stringBatchSpec());
      expect(out, contains('jobjectArray batch'));
      expect(out, contains('Dart_CObject_kArray'));
      expect(out, contains('Dart_CObject_kString'));
      expect(out, isNot(contains('jlongArray batch')));
    });

    test('C bridge: String batch handler converts jstring to UTF-8 and posts array', () {
      final out = CppBridgeGenerator.generate(stringBatchSpec());
      expect(out, contains('GetStringUTFChars'));
      expect(out, contains('ReleaseStringUTFChars'));
      expect(out, contains('GetObjectArrayElement'));
    });

    test('numeric batch: still emits LongArray (not regressed)', () {
      final numericBatchSpec = BridgeSpec(
        dartClassName: 'Sensor',
        lib: 'sensor',
        namespace: 'sensor',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'sensor.native.dart',
        streams: [
          BridgeStream(
            dartName: 'values',
            registerSymbol: 'sensor_register_values_stream',
            releaseSymbol: 'sensor_release_values_stream',
            itemType: BridgeType(name: 'int'),
            backpressure: Backpressure.batch,
          ),
        ],
      );
      final out = KotlinGenerator.generate(numericBatchSpec);
      expect(out, contains('emit_values_batch(dartPort: Long, batch: LongArray): Boolean'));
      expect(out, contains('ArrayList<Long>('));
    });
  });

  group('Backpressure — all three values exist', () {
    test('Backpressure enum has dropLatest', () {
      expect(Backpressure.dropLatest.name, equals('dropLatest'));
    });

    test('Backpressure enum has block', () {
      expect(Backpressure.block.name, equals('block'));
    });

    test('Backpressure enum has bufferDrop', () {
      expect(Backpressure.bufferDrop.name, equals('bufferDrop'));
    });
  });
}
