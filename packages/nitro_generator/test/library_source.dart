import 'dart:io';

/// The source of a Dart library as one text: the file at [path] (relative to
/// the package root) followed by every `part` it declares. Tests that pin the
/// source itself use this, so they keep working when a library is split into
/// part files. Line endings are normalised (a CRLF checkout on Windows CI).
String readLibrarySource(String path) {
  final file = File(path).existsSync() ? File(path) : File('packages/nitro_generator/$path');
  final main = file.readAsStringSync().replaceAll('\r\n', '\n');
  final parts = RegExp(r"^part '([^']+)';", multiLine: true).allMatches(main).map((m) => File('${file.parent.path}/${m.group(1)}').readAsStringSync().replaceAll('\r\n', '\n'));
  return [main, ...parts].join('\n');
}
