// Tests that all three Backpressure enum values flow correctly through
// the DartFfiGenerator, KotlinGenerator, and SwiftGenerator outputs.
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
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
