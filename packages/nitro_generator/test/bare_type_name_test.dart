// `replaceFirst('?', '')` strips the FIRST '?', which in a generic is the
// INNER type's: `Map<String, int?>` became `Map<String, int>` and the value's
// nullability vanished. That shipped as a real bug on the Kotlin and web
// backends. bareTypeName() strips only a trailing '?'.
import 'dart:io';

import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:test/test.dart';

void main() {
  group('bareTypeName', () {
    test('strips a trailing marker', () {
      expect(bareTypeName('int?'), 'int');
      expect(bareTypeName('TcConfig?'), 'TcConfig');
      expect(bareTypeName('Map<String, int>?'), 'Map<String, int>');
    });

    test('leaves a non-nullable type alone', () {
      expect(bareTypeName('int'), 'int');
      expect(bareTypeName(''), '');
    });

    test('preserves an INNER marker — the whole point', () {
      expect(bareTypeName('Map<String, int?>'), 'Map<String, int?>');
      expect(bareTypeName('List<int?>'), 'List<int?>');
      // Nullable container of nullable values: only the outer one goes.
      expect(bareTypeName('Map<String, int?>?'), 'Map<String, int?>');
    });
  });

  test('the replaceFirst idiom is not reintroduced anywhere in lib/', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final (i, line) in f.readAsLinesSync().indexed) {
        // The doc comment on bareTypeName names the idiom deliberately.
        if (line.contains("replaceFirst('?', '')") && !line.trimLeft().startsWith('///')) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use bareTypeName(...) — replaceFirst removes an inner generic marker',
    );
  });
}
