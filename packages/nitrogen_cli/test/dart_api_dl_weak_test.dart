// GitHub #61: `nitrogen link` copies dart_api_dl.c verbatim into every plugin.
// Two nitro SPM plugins in one iOS/macOS app link their .o files together, so
// each Dart_*_DL symbol must be WEAK or the second plugin is a duplicate
// definition ("46 duplicate symbols" at link time). This guards the weak patch
// against being lost if the upstream Dart file is ever re-vendored.
import 'dart:io';

import 'package:nitrogen_cli/templates/native_headers.dart' show bundledDartApiDlContent;
import 'package:test/test.dart';

void main() {
  // nitro's src/native copy (CMake/CocoaPods) and the template `nitrogen link`
  // writes into each SPM `<Module>Cpp` target — the copy that actually collides.
  for (final (name, read) in [
    ('nitro/src/native/dart_api_dl.c', () => _dartApiDlSource().readAsStringSync()),
    ('bundledDartApiDlContent (SPM)', () => bundledDartApiDlContent),
  ]) {
    test('$name defines Dart DL symbols weakly (GitHub #61)', () {
      _expectWeak(read());
    });
  }
}

void _expectWeak(String content) {
  // MSVC guard — no __attribute__((weak)) there; Windows plugins are separate DLLs.
  expect(content, contains('#if defined(_MSC_VER)'));
  expect(content, contains('__attribute__((weak))'));

  // Every external definition in the file is weak:
  expect(content, contains('NITRO_DL_WEAK name##_Type name##_DL = NULL'), reason: 'DL globals');
  expect(content, contains('NITRO_DL_WEAK intptr_t Dart_InitializeApiDL'), reason: 'init function');
  expect(content, contains('NITRO_DL_WEAK DartApiEntry_function FindFunctionPointer'), reason: 'helper');
  // Export-first on the DART_EXPORT functions: GCC drops a `__attribute__((weak))`
  // that precedes `extern "C"` (DART_EXPORT in C++), so the attribute must follow it.
  expect(content, contains('DART_EXPORT NITRO_DL_WEAK void Dart_UpdateExternalSize_Deprecated'), reason: 'deprecated fn (export-first so weak survives GCC C++)');

  // No bare strong `..._DL = NULL` definition should remain.
  expect(
    content,
    isNot(contains(RegExp(r'^#define DART_API_DL_DEFINITIONS\(name, R, A\) name##_Type', multiLine: true))),
    reason: 'the DEFINITIONS macro must carry NITRO_DL_WEAK',
  );
}

File _dartApiDlSource() {
  for (final rel in [
    '../nitro/src/native/dart_api_dl.c', // cwd = packages/nitrogen_cli
    'packages/nitro/src/native/dart_api_dl.c', // cwd = repo root
  ]) {
    final f = File(rel);
    if (f.existsSync()) return f;
  }
  fail('could not locate packages/nitro/src/native/dart_api_dl.c');
}
