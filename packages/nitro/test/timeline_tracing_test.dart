import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

int _echoInt(int value) => value;

void main() {
  tearDown(() => NitroConfig.instance.reset());

  group('Nitro timeline tracing', () {
    test('is disabled by default and reset clears it', () {
      expect(NitroConfig.instance.timelineTracingEnabled, isFalse);

      NitroConfig.instance.timelineTracingEnabled = true;
      NitroConfig.instance.reset();

      expect(NitroConfig.instance.timelineTracingEnabled, isFalse);
    });

    test('callSync preserves fast-path behavior when tracing is enabled without logging', () {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.none
        ..slowCallThresholdUs = 0
        ..timelineTracingEnabled = true;

      var logged = false;
      NitroConfig.instance.logHandler = (_, _, _, [_, _]) {
        logged = true;
      };

      final result = NitroRuntime.callSync(() => 7, methodName: 'profiledSync');

      expect(result, 7);
      expect(logged, isFalse);
    });

    test('callSync still rethrows with tracing enabled', () {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.none
        ..slowCallThresholdUs = 0
        ..timelineTracingEnabled = true;

      final error = StateError('sync failed');

      expect(
        () => NitroRuntime.callSync<void>(() => throw error, methodName: 'profiledThrow'),
        throwsA(same(error)),
      );
    });

    test('callAsync returns result with tracing enabled', () async {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.none
        ..slowCallThresholdUs = 0
        ..isolatePoolSize = 0
        ..timelineTracingEnabled = true;

      final result = await NitroRuntime.callAsync<int>(
        _echoInt,
        [42],
        methodName: 'profiledAsync',
      );

      expect(result, 42);
    });

    test('callAsync still rethrows with tracing enabled', () async {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.none
        ..slowCallThresholdUs = 0
        ..isolatePoolSize = 0
        ..timelineTracingEnabled = true;

      await expectLater(
        NitroRuntime.callAsync<int>(
          (_) => throw StateError('async failed'),
          [1],
          methodName: 'profiledAsyncThrow',
        ),
        throwsStateError,
      );
    });

    test('openNativeAsync closes startup failure path with tracing enabled', () async {
      NitroConfig.instance
        ..logLevel = NitroLogLevel.none
        ..slowCallThresholdUs = 0
        ..timelineTracingEnabled = true;

      expect(
        () => NitroRuntime.openNativeAsync<int>(
          call: (_) => throw StateError('register failed'),
          unpack: (_) => 0,
          methodName: 'profiledNativeAsync',
        ),
        throwsStateError,
      );
    });
  });
}
