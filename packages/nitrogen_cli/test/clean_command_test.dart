import 'dart:io';

import 'package:nitrogen_cli/commands/clean_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('deleteIncrementalGenerationCache', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nitrogen_clean_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('deletes the incremental generation cache', () async {
      final cache = File(p.join(tempDir.path, '.dart_tool', 'nitro', 'cache.json'));
      cache.parent.createSync(recursive: true);
      cache.writeAsStringSync('{}');
      final deleted = <String>[];

      final result = deleteIncrementalGenerationCache(tempDir.path, onDeleted: deleted.add);

      expect(result, isTrue);
      expect(cache.existsSync(), isFalse);
      expect(deleted, equals([p.join('.dart_tool', 'nitro', 'cache.json')]));
    });
  });
}
