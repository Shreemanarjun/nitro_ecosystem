// Lifetime check for typed-data record fields that Dart receives as a view of
// the record's native buffer.
//
// The buffer must stay valid for as long as the list is reachable — including
// after the isolate that decoded it has exited, which is what happens to the
// result of `Isolate.run` / `compute` — and must be freed once the list is
// garbage. Text-level tests cannot show either. This compiles the adopt export
// exactly as the generator emits it, and drives it with the real RecordReader.
//
//   dart run tool/verify_record_lend.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nitro/nitro.dart' show NitroAdopt, RecordReader, RecordWriter;
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';

BridgeSpec _spec() => BridgeSpec(
  dartClassName: 'Lend',
  lib: 'lend',
  namespace: 'lend',
  iosImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'lend.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Blob',
      fields: [BridgeRecordField(name: 'bytes', dartType: 'Uint8List', kind: RecordFieldKind.typedData)],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetch',
      cSymbol: 'lend_fetch',
      isAsync: false,
      returnType: BridgeType(name: 'Blob', isRecord: true),
      params: [],
    ),
  ],
);

/// The two functions `_emitNitroAdopt` writes, cut out of a generated bridge.
String _generatedAdopt() {
  final bridge = CppBridgeGenerator.generate(_spec());
  final from = bridge.indexOf('static void lend_nitro_adopted_gone(');
  const head = 'NITRO_EXPORT void lend_nitro_adopt(';
  final to = bridge.indexOf('\n}\n', bridge.indexOf(head));
  if (from < 0 || to < from) throw StateError('lend_nitro_adopt not found in the generated bridge');
  return bridge.substring(from, to + 3);
}

/// `free` is counted so the checks below can tell WHEN a buffer was released
/// without ever reading memory that might be gone.
String _source() =>
    '''
#include "dart_api_dl.h"
#include <atomic>
#include <cstdint>
#include <cstdlib>
#define NITRO_EXPORT extern "C" __attribute__((visibility("default")))
static std::atomic<long> g_freed{0};
static void counted_free(void* p) { ::free(p); g_freed++; }
#define free counted_free
${_generatedAdopt()}
#undef free
NITRO_EXPORT intptr_t lend_init(void* data) { return Dart_InitializeApiDL(data); }
NITRO_EXPORT long lend_freed(void) { return g_freed.load(); }
// For the dart:ffi comparison: the same counted free as a plain finalizer.
NITRO_EXPORT void lend_counted_free(void* p) { counted_free(p); }
''';

// Top-level state is per isolate: each isolate that decodes opens the library.
DynamicLibrary? _opened;
String _libPath = '';
DynamicLibrary get _lib => _opened ??= DynamicLibrary.open(_libPath);
final NitroAdopt _adopt = _lib.lookupFunction<Void Function(Handle, Pointer<Void>, IntPtr), void Function(Object, Pointer<Void>, int)>('lend_nitro_adopt');
final int Function() _freed = _lib.lookupFunction<Long Function(), int Function()>('lend_freed', isLeaf: true);

/// A `{Uint8List bytes}` record in malloc'd memory, as a bridge returns it.
Pointer<Uint8> _record(int n, int seed) {
  final w = RecordWriter()..writeBlob(Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xff)));
  return w.toNative(malloc);
}

/// What generated code does with a returned record: decode, then free unless a
/// field kept the buffer.
Uint8List _decode(Pointer<Uint8> p) {
  final Uint8List bytes;
  try {
    bytes = RecordReader.fromNative(p, adopt: _adopt).readBlobView();
  } finally {
    if (!RecordReader.keptAlive(p)) malloc.free(p);
  }
  return bytes;
}

bool _intact(Uint8List list, int seed) {
  for (var i = 0; i < list.length; i++) {
    if (list[i] != (i + seed) & 0xff) return false;
  }
  return true;
}

/// Allocates until the collector has had every reason to run.
void _churn(bool Function() done) {
  for (var i = 0; i < 400 && !done(); i++) {
    List.generate(50000, (j) => [j]);
  }
}

Future<void> main() async {
  if (Platform.isWindows) {
    stdout.writeln('SKIP  package:ffi malloc is not the C runtime allocator on Windows');
    return;
  }
  final tmp = Directory.systemTemp.createTempSync('nitro_lend_');
  var failures = 0;
  void check(bool ok, String what) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $what');
    if (!ok) failures++;
  }

  try {
    final native = Directory('../nitro/src/native').existsSync() ? '../nitro/src/native' : 'packages/nitro/src/native';
    final src = File('${tmp.path}/lend.cpp')..writeAsStringSync(_source());
    final out = '${tmp.path}/liblend.${Platform.isMacOS ? 'dylib' : 'so'}';
    // dart_api_dl.c is C; the generated bridge is C++.
    final dl = Process.runSync(Platform.environment['CC'] ?? 'cc', ['-c', '-fPIC', '-I', native, '$native/dart_api_dl.c', '-o', '${tmp.path}/dl.o']);
    final cc = Process.runSync(Platform.environment['CXX'] ?? 'c++', [
      '-std=c++17', '-O1', '-Wall', '-shared', '-fPIC', '-I', native, src.path, '${tmp.path}/dl.o', '-o', out, //
    ]);
    if (dl.exitCode != 0 || cc.exitCode != 0) {
      stderr.writeln('COMPILE FAILED:\n${dl.stderr}${cc.stderr}');
      exitCode = 1;
      return;
    }
    stdout.writeln('PASS  generated adopt export compiles (c++17, -Wall)');

    _libPath = out;
    final init = _lib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('lend_init');
    check(init(NativeApi.initializeApiDLData) == 0, 'Dart API initialised');

    // 1. Lists decoded on a helper isolate and returned from Isolate.run. Small
    //    fields too: a freed small block is reused at once, so they show a
    //    premature free soonest.
    const sizes = [16, 64, 4096, 64 << 10, 4 << 20];
    final returned = <Uint8List>[];
    for (final n in sizes) {
      returned.add(
        await Isolate.run(() {
          _libPath = out;
          RecordReader.lendMinBytes = 0;
          return _decode(_record(n, n));
        }),
      );
    }
    _churn(() => false);
    check(_freed() == 0, 'no buffer freed while its list is alive in another isolate (${_freed()} freed)');
    check([for (var i = 0; i < sizes.length; i++) _intact(returned[i], sizes[i])].every((ok) => ok), 'every list returned from Isolate.run is intact');

    // 2. Dropped lists are freed, here and for the ones that crossed isolates.
    returned.clear();
    RecordReader.lendMinBytes = 0;
    const dropped = 500;
    for (var i = 0; i < dropped; i++) {
      _decode(_record(64 << 10, i));
    }
    const all = dropped + 5; // + the five from step 1
    _churn(() => _freed() >= all);
    // A stack slot can keep the last list or two reachable; a leak would be hundreds.
    check(_freed() >= all - 2, 'buffers are freed once their lists are garbage (${_freed()} of $all)');

    // 3. For the record: what dart:ffi's own finalizer does with the same list.
    final counted = _lib.lookup<NativeFinalizerFunction>('lend_counted_free');
    final base = _freed();
    final viaFfi = await Isolate.run(() {
      final p = _record(64, 1);
      return (p + 4 + 4).asTypedList(64, finalizer: counted, token: p.cast());
    });
    stdout.writeln(
      'NOTE  asTypedList(finalizer:) returned from Isolate.run: buffer ${_freed() > base ? 'ALREADY FREED' : 'still allocated'} '
      'while the list (${viaFfi.length} bytes) is reachable',
    );
  } finally {
    tmp.deleteSync(recursive: true);
  }
  stdout.writeln(failures == 0 ? '\nlent record buffers outlive their isolate and are freed with their list' : '\n$failures check(s) failed');
  exitCode = failures == 0 ? 0 : 1; // main's return value is ignored
}
