/// Tests for [NitroRuntime.callSync] logging and slow-call detection.
///
/// These tests verify that [NitroRuntime.callSync] provides the same DX as
/// [NitroRuntime.callAsync]:
///   - verbose "calling" / "completed in N µs" log pairs
///   - slow-call [NitroLogLevel.warning] when threshold is exceeded
///   - error logging when the call throws
///   - fast-path (no allocation) when logging is fully disabled
library;

import 'dart:io';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  // Restore config after each test.
  tearDown(() => NitroConfig.instance.reset());

  // ── Helper: capture log output ────────────────────────────────────────────

  List<(NitroLogLevel, String, String)> captureLogs(void Function() body) {
    final logs = <(NitroLogLevel, String, String)>[];
    NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) {
      logs.add((level, tag, msg));
    };
    body();
    return logs;
  }

  // ── Fast-path: logging disabled ───────────────────────────────────────────

  group('ABI version check', () {
    test('accepts the current ABI version', () {
      expect(
        () => NitroRuntime.checkAbiVersion(
          'camera',
          () => NitroRuntime.expectedAbiVersion,
        ),
        returnsNormally,
      );
    });

    test('throws actionable error when the ABI symbol is missing', () {
      expect(
        () => NitroRuntime.checkAbiVersion(
          'camera',
          () => throw ArgumentError('Symbol not found'),
        ),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('camera: Nitro ABI version check failed'))
              .having((e) => e.message, 'message', contains('nitrogen generate'))
              .having((e) => e.message, 'message', contains('nitrogen link')),
        ),
      );
    });

    test('throws actionable error when the ABI version mismatches', () {
      expect(
        () => NitroRuntime.checkAbiVersion('camera', () => 0),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('camera: Nitro ABI version mismatch'))
              .having((e) => e.message, 'message', contains('expects ${NitroRuntime.expectedAbiVersion}'))
              .having((e) => e.message, 'message', contains('reports 0'))
              .having((e) => e.message, 'message', contains('nitrogen generate'))
              .having((e) => e.message, 'message', contains('nitrogen link')),
        ),
      );
    });
  });

  group('bridge checksum check', () {
    test('accepts matching generated checksums', () {
      expect(
        () => NitroRuntime.checkLinkChecksum('camera', 'abc123', () => 'abc123'),
        returnsNormally,
      );
    });

    test('throws actionable error when the checksum symbol is missing', () {
      expect(
        () => NitroRuntime.checkLinkChecksum(
          'camera',
          'abc123',
          () => throw ArgumentError('Symbol not found'),
        ),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('camera: Nitro bridge checksum check failed'))
              .having((e) => e.message, 'message', contains('nitrogen generate'))
              .having((e) => e.message, 'message', contains('nitrogen link')),
        ),
      );
    });

    test('throws actionable error when the checksum mismatches', () {
      expect(
        () => NitroRuntime.checkLinkChecksum('camera', 'abc123', () => 'def456'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('camera: Nitro bridge checksum mismatch'))
              .having((e) => e.message, 'message', contains('expects abc123'))
              .having((e) => e.message, 'message', contains('reports def456'))
              .having((e) => e.message, 'message', contains('nitrogen generate'))
              .having((e) => e.message, 'message', contains('nitrogen link')),
        ),
      );
    });
  });

  group('loadLib — cache', () {
    test('platform target check accepts the current platform', () {
      expect(
        () => NitroRuntime.checkSupportedPlatform(
          'camera',
          ios: Platform.isIOS,
          android: Platform.isAndroid,
          macos: Platform.isMacOS,
          windows: Platform.isWindows,
          linux: Platform.isLinux,
          web: false,
        ),
        returnsNormally,
      );
    });

    test('platform target check throws actionable UnsupportedError', () {
      expect(
        () => NitroRuntime.checkSupportedPlatform(
          'camera',
          ios: false,
          android: false,
          macos: false,
          windows: false,
          linux: false,
          web: true,
        ),
        throwsA(
          isA<UnsupportedError>()
              .having((e) => e.message, 'message', contains('camera: this generated Nitro module does not target'))
              .having((e) => e.message, 'message', contains('Targeted platforms: Web'))
              .having((e) => e.message, 'message', contains('nitrogen generate'))
              .having((e) => e.message, 'message', contains('nitrogen link')),
        ),
      );
    });

    test(
      'loads a native library once per name',
      () {
        NitroConfig.instance.logLevel = NitroLogLevel.verbose;
        final logs = captureLogs(() {
          final first = NitroRuntime.loadLib('nitro_runtime_cache_test');
          final second = NitroRuntime.loadLib('nitro_runtime_cache_test');
          expect(identical(first, second), isTrue);
        });

        final loadLogs = logs.where((l) => l.$2 == 'loadLib' && l.$3.contains('Loading native lib')).toList();
        expect(loadLogs, hasLength(1));
      },
      skip: !(Platform.isMacOS || Platform.isIOS) ? 'loadLib requires a real platform library outside Apple process() platforms.' : false,
    );
  });

  group('callSync — fast path (logLevel.none)', () {
    test('returns the value without any logging', () {
      NitroConfig.instance.logLevel = NitroLogLevel.none;
      var handlerCalled = false;
      NitroConfig.instance.logHandler = (_, _, _, [_, _]) {
        handlerCalled = true;
      };

      final result = NitroRuntime.callSync(() => 42, methodName: 'test');

      expect(result, equals(42));
      expect(handlerCalled, isFalse);
    });

    test('passes through exceptions without logging', () {
      NitroConfig.instance.logLevel = NitroLogLevel.none;
      var handlerCalled = false;
      NitroConfig.instance.logHandler = (_, _, _, [_, _]) {
        handlerCalled = true;
      };

      expect(
        () => NitroRuntime.callSync<int>(() => throw StateError('boom'), methodName: 'x'),
        throwsStateError,
      );
      expect(handlerCalled, isFalse);
    });
  });

  // ── Verbose logging ───────────────────────────────────────────────────────

  group('callSync — verbose logging', () {
    setUp(() => NitroConfig.instance.logLevel = NitroLogLevel.verbose);

    test('emits "calling" and "completed in N µs" at verbose level', () {
      final logs = captureLogs(() {
        NitroRuntime.callSync(() => 1, methodName: 'add');
      });

      final verboseLogs = logs.where((l) => l.$1 == NitroLogLevel.verbose).toList();
      expect(verboseLogs.any((l) => l.$3.contains('calling')), isTrue, reason: 'should emit a "calling" log at verbose');
      expect(verboseLogs.any((l) => l.$3.contains('completed in') && l.$3.contains('µs')), isTrue, reason: 'should emit a "completed in N µs" log at verbose');
    });

    test('log tag includes the method name', () {
      final logs = captureLogs(() {
        NitroRuntime.callSync(() => 0, methodName: 'myMethod');
      });

      expect(
        logs.any((l) => l.$2.contains('myMethod')),
        isTrue,
        reason: 'tag should include methodName',
      );
    });

    test('tag falls back to "callSync" when methodName is empty', () {
      final logs = captureLogs(() {
        NitroRuntime.callSync(() => 0);
      });

      expect(logs.any((l) => l.$2 == 'callSync'), isTrue);
    });

    test('returns the correct value', () {
      NitroConfig.instance.logLevel = NitroLogLevel.verbose;
      final result = NitroRuntime.callSync(() => 'hello', methodName: 'greet');
      expect(result, equals('hello'));
    });
  });

  // ── Error logging ─────────────────────────────────────────────────────────

  group('callSync — error logging', () {
    setUp(() => NitroConfig.instance.logLevel = NitroLogLevel.error);

    test('logs at error level when call throws', () {
      final logs = <(NitroLogLevel, String, String)>[];
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) {
        logs.add((level, tag, msg));
      };

      expect(
        () => NitroRuntime.callSync<void>(
          () => throw StateError('native failure'),
          methodName: 'explode',
        ),
        throwsStateError,
      );

      final errorLogs = logs.where((l) => l.$1 == NitroLogLevel.error).toList();
      expect(errorLogs, isNotEmpty, reason: 'should log at error level on throw');
      expect(errorLogs.any((l) => l.$2.contains('explode')), isTrue, reason: 'error tag should contain the method name');
    });

    test('re-throws the original exception after logging', () {
      NitroConfig.instance.logHandler = (_, _, _, [_, _]) {};

      final err = ArgumentError('bad arg');
      expect(
        () => NitroRuntime.callSync<void>(() => throw err, methodName: 'bad'),
        throwsA(same(err)),
      );
    });
  });

  // ── Slow-call detection ───────────────────────────────────────────────────

  group('callSync — slow-call detection', () {
    test('emits warning when call exceeds threshold', () {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.warning
        ..slowCallThresholdUs = 1; // 1 µs — almost any call will be "slow"

      final logs = <(NitroLogLevel, String, String)>[];
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) {
        logs.add((level, tag, msg));
      };

      NitroRuntime.callSync(() {
        // busy-wait long enough to exceed the 1 µs threshold
        var x = 0;
        for (var i = 0; i < 1000000; i++) {
          x += i;
        }
        return x;
      }, methodName: 'slowOp');

      final warnings = logs.where((l) => l.$1 == NitroLogLevel.warning).toList();
      expect(warnings, isNotEmpty, reason: 'slow call should trigger a warning');
      expect(warnings.any((l) => l.$3.contains('slow call')), isTrue);
      expect(warnings.any((l) => l.$3.contains('slowOp') || l.$2.contains('slowOp')), isTrue);
    });

    test('no warning when call is within threshold', () {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.warning
        ..slowCallThresholdUs = 999999999; // 1000 s — nothing will exceed this

      final logs = <(NitroLogLevel, String, String)>[];
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) {
        logs.add((level, tag, msg));
      };

      NitroRuntime.callSync(() => 1, methodName: 'fastOp');

      expect(
        logs.where((l) => l.$1 == NitroLogLevel.warning),
        isEmpty,
        reason: 'fast call must not emit a warning',
      );
    });

    test('no Stopwatch when threshold is 0 and level is error', () {
      // White-box: verify we reach the fast path without timing overhead.
      // We can only observe this indirectly — ensure no verbose logs slip out.
      NitroConfig.instance
        ..logLevel = NitroLogLevel.error
        ..slowCallThresholdUs = 0;

      final logs = <(NitroLogLevel, String, String)>[];
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) {
        logs.add((level, tag, msg));
      };

      NitroRuntime.callSync(() => 1, methodName: 'noTimer');

      expect(logs.where((l) => l.$1 == NitroLogLevel.verbose), isEmpty);
    });
  });

  // ── Parity with callAsync config shape ────────────────────────────────────

  group('callSync — config parity with callAsync', () {
    test('enable(verbose) activates verbose logs for callSync', () {
      NitroConfig.instance.enable(level: NitroLogLevel.verbose);

      final logs = captureLogs(() {
        NitroRuntime.callSync(() => 0, methodName: 'check');
      });

      expect(logs.any((l) => l.$1 == NitroLogLevel.verbose), isTrue);
    });

    test('disable() suppresses all callSync logs', () {
      NitroConfig.instance.disable();

      var called = false;
      NitroConfig.instance.logHandler = (_, _, _, [_, _]) {
        called = true;
      };

      NitroRuntime.callSync(() => 0, methodName: 'silenced');
      expect(called, isFalse);
    });
  });
}
