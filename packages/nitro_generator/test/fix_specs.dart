import 'dart:io';

void main() {
  final testDir = Directory('packages/nitro_generator/test');
  final specs = [
    'simpleSpec',
    'enumSpec',
    'structStreamSpec',
    'underscoreLibSpec',
    'richSpec',
    'asyncEnumSpec',
    'singleRecordSpec',
    'recordListSpec',
    'cppSpec',
    'cppEnumSpec',
    'cppStreamSpec',
    'cppStreamStructSpec',
  ];

  for (final file in testDir.listSync(recursive: true)) {
    if (file is File && file.path.endsWith('.dart')) {
      var content = file.readAsStringSync();
      var changed = false;
      for (final spec in specs) {
        if (content.contains(spec)) {
          // Replace '_specName(' with 'specName(' or '_specName()' with 'specName()'
          final replacement = spec.substring(1);
          content = content.replaceAll(spec, replacement);
          changed = true;
        }
      }
      if (changed) {
        file.writeAsStringSync(content);
        print('Updated ${file.path}');
      }
    }
  }
}
