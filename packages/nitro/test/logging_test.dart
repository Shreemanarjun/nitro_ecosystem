// Logging + error-handling behavior (issue #27): the default log handler
// routes through zone-aware print (keeping package:nitro's import graph
// flutter-free so it compiles under plain dart2js/dart2wasm — the 0.7.0 web
// split), and checkError swallows a failure in the error-check path itself
// but logs it at verbose so it is diagnosable rather than silently lost.
import 'dart:async';
import 'dart:ffi';

import 'package:nitro/src/nitro_runtime.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => NitroConfig.instance.reset());

  group('default log handler (#27)', () {
    test('routes through zone-aware print (flutter-free import graph)', () {
      final captured = <String>[];

      // After reset(), logHandler is the package default (_defaultLog).
      NitroConfig.instance.reset();
      runZoned(
        () => NitroConfig.instance.logHandler(NitroLogLevel.error, 'unit', 'boom'),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => captured.add(line),
        ),
      );

      expect(captured, hasLength(1));
      expect(captured.single, contains('[Nitro/unit]'));
      expect(captured.single, contains('boom'));
    });

    test('formats error + stack when provided', () {
      final captured = <String>[];

      NitroConfig.instance.reset();
      runZoned(
        () => NitroConfig.instance.logHandler(
          NitroLogLevel.error,
          'unit',
          'failed',
          StateError('bad'),
          StackTrace.current,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => captured.add(line),
        ),
      );

      expect(captured.single, contains('error: Bad state: bad'));
    });
  });

  group('checkError swallow-and-log (#27)', () {
    test('a throwing get() is swallowed (does not propagate)', () {
      NitroConfig.instance.logLevel = NitroLogLevel.none;
      expect(
        () => NitroRuntime.checkError(
          () => throw StateError('invalid get stub'),
          () {},
        ),
        returnsNormally,
      );
    });

    test('the swallowed failure is logged at verbose', () {
      final logs = <(NitroLogLevel, String, String)>[];
      NitroConfig.instance.logLevel = NitroLogLevel.verbose;
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) => logs.add((level, tag, msg));

      NitroRuntime.checkError(() => throw StateError('boom'), () {});

      final hit = logs.where((e) => e.$2 == 'checkError').toList();
      expect(hit, isNotEmpty, reason: 'expected a verbose checkError log');
      expect(hit.first.$1, NitroLogLevel.verbose);
      expect(hit.first.$3, contains('threw'));
    });

    test('at logLevel.error the failure is swallowed WITHOUT a log (verbose filtered)', () {
      final logs = <(NitroLogLevel, String, String)>[];
      NitroConfig.instance.logLevel = NitroLogLevel.error;
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) => logs.add((level, tag, msg));

      NitroRuntime.checkError(() => throw StateError('boom'), () {});

      expect(logs.where((e) => e.$2 == 'checkError'), isEmpty);
    });

    test('a no-error slot (nullptr get) is a clean no-op', () {
      NitroConfig.instance.logLevel = NitroLogLevel.verbose;
      final logs = <String>[];
      NitroConfig.instance.logHandler = (level, tag, msg, [_, _]) => logs.add(tag);
      expect(
        () => NitroRuntime.checkError(() => nullptr, () {}),
        returnsNormally,
      );
      expect(logs.where((t) => t == 'checkError'), isEmpty);
    });
  });
}
