// Tests for fully-implemented Backpressure.bufferDrop and Backpressure.block
// (Gap 10 and Gap 11 — previously declared but not generated in Kotlin/Swift).

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _bufferDropSpec({int capacity = 64}) => BridgeSpec(
      dartClassName: 'Sensor',
      lib: 'sensor',
      namespace: 'sensor',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'sensor.native.dart',
      streams: [
        BridgeStream(
          dartName: 'data',
          registerSymbol: 'sensor_register_data_stream',
          releaseSymbol: 'sensor_release_data_stream',
          itemType: BridgeType(name: 'double'),
          backpressure: Backpressure.bufferDrop,
          batchMaxSize: capacity,
          isAnnotated: true,
        ),
      ],
    );

BridgeSpec _blockSpec({int capacity = 32}) => BridgeSpec(
      dartClassName: 'Sensor',
      lib: 'sensor',
      namespace: 'sensor',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'sensor.native.dart',
      streams: [
        BridgeStream(
          dartName: 'frames',
          registerSymbol: 'sensor_register_frames_stream',
          releaseSymbol: 'sensor_release_frames_stream',
          itemType: BridgeType(name: 'int'),
          backpressure: Backpressure.block,
          batchMaxSize: capacity,
          isAnnotated: true,
        ),
      ],
    );

void main() {
  // ── Gap 10: Backpressure.bufferDrop ──────────────────────────────────────

  group('Gap 10 — Backpressure.bufferDrop', () {
    group('SpecValidator', () {
      test('bufferDrop produces no validation errors', () {
        final issues = SpecValidator.validate(_bufferDropSpec());
        expect(issues.where((i) => i.isError), isEmpty,
            reason: 'bufferDrop is now implemented — no E016 error should be emitted');
      });

      test('isBufferDrop getter on BridgeStream is true', () {
        final spec = _bufferDropSpec();
        expect(spec.streams.first.isBufferDrop, isTrue);
      });
    });

    group('Kotlin generator — bufferDrop', () {
      test('emits .buffer() with DROP_OLDEST overflow strategy', () {
        final code = KotlinGenerator.generate(_bufferDropSpec());
        expect(code, contains('BufferOverflow.DROP_OLDEST'),
            reason: 'bufferDrop must use Kotlin coroutines DROP_OLDEST overflow');
      });

      test('emits buffer capacity in Flow.buffer() call', () {
        final code = KotlinGenerator.generate(_bufferDropSpec(capacity: 128));
        expect(code, contains('capacity = 128'));
      });

      test('emits .collect lambda that calls emit_data', () {
        final code = KotlinGenerator.generate(_bufferDropSpec());
        expect(code, contains('emit_data(dartPort, item)'));
      });

      test('does NOT emit batch-style buffer code for bufferDrop', () {
        final code = KotlinGenerator.generate(_bufferDropSpec());
        expect(code, isNot(contains('ArrayList')));
        expect(code, isNot(contains('_flushJob')));
      });
    });

    group('Swift generator — bufferDrop', () {
      test('emits .buffer() with whenFull: .dropOldest', () {
        final code = SwiftGenerator.generate(_bufferDropSpec());
        expect(code, contains('whenFull: .dropOldest'),
            reason: 'bufferDrop must use Combine .dropOldest buffer policy');
      });

      test('emits buffer capacity in .buffer(size:) call', () {
        final code = SwiftGenerator.generate(_bufferDropSpec(capacity: 96));
        expect(code, contains('size: 96'));
      });

      test('emits .sink after .buffer()', () {
        final code = SwiftGenerator.generate(_bufferDropSpec());
        expect(code, contains('.buffer('));
        expect(code, contains('.sink {'));
      });

      test('does NOT emit batch timer for bufferDrop', () {
        final code = SwiftGenerator.generate(_bufferDropSpec());
        expect(code, isNot(contains('makeTimerSource')));
        expect(code, isNot(contains('_flushTimers')));
      });
    });

    group('Dart FFI generator — bufferDrop', () {
      test('passes Backpressure.bufferDrop to openStream', () {
        final code = DartFfiGenerator.generate(_bufferDropSpec());
        expect(code, contains('Backpressure.bufferDrop'),
            reason: 'Dart side must record the actual backpressure mode for NitroRuntime');
      });
    });
  });

  // ── Gap 11: Backpressure.block ────────────────────────────────────────────

  group('Gap 11 — Backpressure.block', () {
    group('SpecValidator', () {
      test('block produces no validation errors', () {
        final issues = SpecValidator.validate(_blockSpec());
        expect(issues.where((i) => i.isError), isEmpty,
            reason: 'block is now implemented — no E017 error should be emitted');
      });

      test('isBlock getter on BridgeStream is true', () {
        final spec = _blockSpec();
        expect(spec.streams.first.isBlock, isTrue);
      });
    });

    group('Kotlin generator — block', () {
      test('emits .buffer() without DROP_OLDEST (SUSPEND is the default)', () {
        final code = KotlinGenerator.generate(_blockSpec());
        expect(code, contains('.buffer(capacity = '),
            reason: 'block uses bounded buffer with SUSPEND overflow');
        expect(code, isNot(contains('DROP_OLDEST')),
            reason: 'block must not drop items — it suspends the producer');
        expect(code, isNot(contains('DROP_LATEST')));
      });

      test('emits buffer capacity in Flow.buffer() call', () {
        final code = KotlinGenerator.generate(_blockSpec(capacity: 16));
        expect(code, contains('capacity = 16'));
      });

      test('emits .collect that calls emit_frames', () {
        final code = KotlinGenerator.generate(_blockSpec());
        expect(code, contains('emit_frames(dartPort, item)'));
      });
    });

    group('Swift generator — block', () {
      test('emits .buffer() + .receive(on:) for serial delivery', () {
        final code = SwiftGenerator.generate(_blockSpec());
        expect(code, contains('.buffer('),
            reason: 'block needs a bounded buffer to limit in-flight items');
        expect(code, contains('.receive(on: _serialQ)'),
            reason: 'block uses serial DispatchQueue to rate-limit emissions');
      });

      test('emits serial DispatchQueue for block mode', () {
        final code = SwiftGenerator.generate(_blockSpec());
        expect(code, contains('DispatchQueue(label: "com.nitro.block.frames.'));
      });

      test('emits .whenFull: .dropNewest (bounded buffer, newest item rejected when full)', () {
        final code = SwiftGenerator.generate(_blockSpec());
        expect(code, contains('whenFull: .dropNewest'));
      });

      test('does NOT emit batch timer for block', () {
        final code = SwiftGenerator.generate(_blockSpec());
        expect(code, isNot(contains('makeTimerSource')));
      });
    });

    group('Dart FFI generator — block', () {
      test('passes Backpressure.block to openStream', () {
        final code = DartFfiGenerator.generate(_blockSpec());
        expect(code, contains('Backpressure.block'));
      });
    });
  });

  // ── Cross-mode: all three modes produce distinct code ─────────────────────

  group('Backpressure modes produce distinct Kotlin code', () {
    BridgeSpec specWith(Backpressure mode) => BridgeSpec(
          dartClassName: 'Hub',
          lib: 'hub',
          namespace: 'hub',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'hub.native.dart',
          streams: [
            BridgeStream(
              dartName: 'events',
              registerSymbol: 'hub_register_events_stream',
              releaseSymbol: 'hub_release_events_stream',
              itemType: BridgeType(name: 'int'),
              backpressure: mode,
              isAnnotated: true,
            ),
          ],
        );

    test('dropLatest has no .buffer() call in Kotlin', () {
      final code = KotlinGenerator.generate(specWith(Backpressure.dropLatest));
      expect(code, isNot(contains('.buffer(')));
    });

    test('bufferDrop has .buffer(DROP_OLDEST) in Kotlin', () {
      final code = KotlinGenerator.generate(specWith(Backpressure.bufferDrop));
      expect(code, contains('DROP_OLDEST'));
    });

    test('block has .buffer() without DROP_OLDEST in Kotlin', () {
      final code = KotlinGenerator.generate(specWith(Backpressure.block));
      expect(code, contains('.buffer(capacity = '));
      expect(code, isNot(contains('DROP_OLDEST')));
    });

    test('dropLatest has no .buffer() Combine operator in Swift', () {
      final code = SwiftGenerator.generate(specWith(Backpressure.dropLatest));
      // dropLatest goes directly to .sink without .buffer
      expect(code, isNot(contains('whenFull:')));
    });

    test('bufferDrop has .dropOldest in Swift', () {
      final code = SwiftGenerator.generate(specWith(Backpressure.bufferDrop));
      expect(code, contains('dropOldest'));
    });

    test('block has .dropNewest + serial queue in Swift', () {
      final code = SwiftGenerator.generate(specWith(Backpressure.block));
      expect(code, contains('dropNewest'));
      expect(code, contains('receive(on: _serialQ)'));
    });
  });

  // ── Gap 13 + 17: Kotlin variant callback + stream fixes ──────────────────

  group('Gap 13 — Kotlin variant callback parameter (ByteArray, not Long)', () {
    BridgeSpec variantCallbackSpec() {
      final variant = BridgeVariant(
        name: 'UIEvent',
        cases: [
          BridgeVariantCase(name: 'UIEventTap', label: 'tap', fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ]),
        ],
      );
      return BridgeSpec(
        dartClassName: 'Widget',
        lib: 'widget',
        namespace: 'widget',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'widget.native.dart',
        variants: [variant],
        functions: [
          BridgeFunction(
            dartName: 'onEvent',
            cSymbol: 'widget_on_event',
            isAsync: false,
            params: [
              BridgeParam(
                name: 'handler',
                type: BridgeType(
                  name: 'void Function(UIEvent)',
                  isFunction: true,
                  functionParams: [BridgeType(name: 'UIEvent')],
                  functionReturnType: 'void',
                ),
              ),
            ],
            returnType: BridgeType(name: 'void'),
          ),
        ],
      );
    }

    test('_invoke_handler external fun uses ByteArray, not Long', () {
      final code = KotlinGenerator.generate(variantCallbackSpec());
      expect(code, contains('external fun _invoke_handler(callbackPtr: Long, arg0: ByteArray)'),
          reason: 'variant callback param must be ByteArray (encoded bytes), not Long');
    });

    test('callbackLambda encodes variant with .encode()', () {
      final code = KotlinGenerator.generate(variantCallbackSpec());
      expect(code, contains('p0.encode()'),
          reason: 'variant callback lambda must call encode() before passing to _invoke_handler');
    });

    test('Kotlin bridge imports kotlinx.coroutines.flow.buffer when bufferDrop present', () {
      final code = KotlinGenerator.generate(_bufferDropSpec());
      expect(code, contains('import kotlinx.coroutines.flow.buffer'),
          reason: '.buffer() extension requires this import');
    });

    test('Kotlin bridge imports kotlinx.coroutines.flow.buffer when block present', () {
      final code = KotlinGenerator.generate(_blockSpec());
      expect(code, contains('import kotlinx.coroutines.flow.buffer'),
          reason: '.buffer() extension requires this import');
    });

    test('Kotlin bridge does NOT import flow.buffer for dropLatest-only streams', () {
      final BridgeSpec spec = BridgeSpec(
        dartClassName: 'Hub',
        lib: 'hub',
        namespace: 'hub',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'hub.native.dart',
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'hub_register_events_stream',
            releaseSymbol: 'hub_release_events_stream',
            itemType: BridgeType(name: 'int'),
            backpressure: Backpressure.dropLatest,
            isAnnotated: true,
          ),
        ],
      );
      final code = KotlinGenerator.generate(spec);
      expect(code, isNot(contains('import kotlinx.coroutines.flow.buffer')),
          reason: 'dropLatest streams do not use .buffer() and do not need the import');
    });
  });

  group('Gap 17 — Kotlin variant Stream item (ByteArray emit + encode)', () {
    BridgeSpec variantStreamSpec() {
      final variant = BridgeVariant(
        name: 'UIEvent',
        cases: [
          BridgeVariantCase(name: 'UIEventTap', label: 'tap', fields: [
            BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
          ]),
        ],
      );
      return BridgeSpec(
        dartClassName: 'Widget',
        lib: 'widget',
        namespace: 'widget',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'widget.native.dart',
        variants: [variant],
        streams: [
          BridgeStream(
            dartName: 'eventStream',
            registerSymbol: 'widget_register_event_stream_stream',
            releaseSymbol: 'widget_release_event_stream_stream',
            itemType: BridgeType(name: 'UIEvent'),
            backpressure: Backpressure.dropLatest,
            isAnnotated: true,
          ),
        ],
      );
    }

    test('emit_eventStream JNI extern uses ByteArray, not UIEvent', () {
      final code = KotlinGenerator.generate(variantStreamSpec());
      expect(code, contains('external fun emit_eventStream(dartPort: Long, item: ByteArray): Boolean'),
          reason: 'variant stream item must be encoded as ByteArray before crossing JNI');
    });

    test('stream collect encodes item with .encode() before emit', () {
      final code = KotlinGenerator.generate(variantStreamSpec());
      expect(code, contains('item.encode()'),
          reason: 'variant stream collect must encode item to ByteArray before emitting');
    });

    test('variant stream RecordReader/RecordWriter helpers are emitted', () {
      final code = KotlinGenerator.generate(variantStreamSpec());
      expect(code, anyOf(contains('RecordWriter'), contains('RecordReader')),
          reason: 'variant encode/decode needs RecordReader/RecordWriter bridge helpers');
    });
  });
}
