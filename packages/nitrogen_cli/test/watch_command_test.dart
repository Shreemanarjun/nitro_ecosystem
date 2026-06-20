import 'dart:async';

import 'package:nitrogen_cli/commands/watch_command.dart';
import 'package:test/test.dart';

void main() {
  group('NativeSpecChangeDebouncer', () {
    test('coalesces native spec changes within the debounce window', () async {
      final calls = <List<String>>[];
      final completer = Completer<void>();
      final debouncer = NativeSpecChangeDebouncer(
        delay: const Duration(milliseconds: 25),
        onReady: (paths) {
          calls.add(paths);
          completer.complete();
        },
      );

      addTearDown(debouncer.dispose);

      expect(debouncer.schedule('/tmp/lib/src/camera.native.dart'), isTrue);
      expect(debouncer.schedule('/tmp/lib/src/audio.native.dart'), isTrue);
      expect(debouncer.schedule('/tmp/lib/src/camera.dart'), isFalse);

      await completer.future.timeout(const Duration(seconds: 1));

      expect(calls, hasLength(1));
      expect(
        calls.single,
        equals([
          '/tmp/lib/src/audio.native.dart',
          '/tmp/lib/src/camera.native.dart',
        ]),
      );
    });

    test('resets the timer when another native spec event arrives', () async {
      final calls = <List<String>>[];
      final completer = Completer<void>();
      final startedAt = DateTime.now();
      final debouncer = NativeSpecChangeDebouncer(
        delay: const Duration(milliseconds: 60),
        onReady: (paths) {
          calls.add(paths);
          completer.complete();
        },
      );

      addTearDown(debouncer.dispose);

      debouncer.schedule('/tmp/lib/src/first.native.dart');
      await Future<void>.delayed(const Duration(milliseconds: 35));
      debouncer.schedule('/tmp/lib/src/second.native.dart');

      await completer.future.timeout(const Duration(seconds: 1));

      expect(calls, hasLength(1));
      expect(calls.single, contains('/tmp/lib/src/first.native.dart'));
      expect(calls.single, contains('/tmp/lib/src/second.native.dart'));
      expect(DateTime.now().difference(startedAt).inMilliseconds, greaterThanOrEqualTo(85));
    });
  });
}
