// Compile-level guard for the native-assets (@Native) emit (W2). The unit tests
// only string-match; this generates the @Native `.g.dart` for a comprehensive
// all-C++ spec, drops it into a package path-depending on the real nitro, and
// runs `dart analyze` — catching an arity desync / undeclared external / wrong
// FFI type that `contains(...)` can't. Usage: dart run tool/verify_native_assets_analyzes.dart
import 'dart:io';

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:path/path.dart' as p;

import '../test/spec_from_source.dart';

// A comprehensive ALL-C++ spec: every shape the widened gate now accepts, plus
// the ones already supported. If any of these emits code that doesn't compile,
// the analyze below fails.
const _spec = '''
import 'package:nitro/nitro.dart'; // re-exports dart:typed_data (Uint8List)

part 'comp.g.dart';

@HybridEnum()
enum Quality { low, medium, high }

@HybridStruct(packed: true)
class Pt {
  final double x;
  final double y;
  const Pt({required this.x, required this.y});
}

@HybridRecord()
class Info {
  final String name;
  final int count;
  const Info({required this.name, required this.count});
}

@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Comp extends HybridObject {
  static Comp get instance => _CompImpl();
  // scalars + String (already eligible)
  int add(int a, int b);
  String echo(String s);
  // N1: nullable prims (params + return)
  int clampN(int? a, double? b, bool? c);
  double? maybeScale(double? v);
  // N1: DateTime, enum
  DateTime roundTrip(DateTime t);
  Quality bump(Quality q);
  // N2: opaque handle param (leaf-safe)
  int useHandle(NativeHandle<Void> h);
  // struct + record (binary-blob / zero-copy proxy)
  Pt echoPt(Pt p);
  Info echoInfo(Info i);
  // TypedData (lever 2)
  int sumBytes(Uint8List data);
  // W1: TypedData zero-copy `.address` ALONGSIDE an arena-marshalled String in
  // the same leaf call — the mixed case the split enables.
  int writeFrame(Uint8List pixels, String label);
  // callback param (NativeCallable) — genuinely non-leaf, TypedData copies here
  void onTick(void Function(int n) cb);
}
''';

Future<void> main() async {
  final gDart = DartFfiGenerator.generate(
    SpecFromSource.parse(_spec, sourceUri: 'package:comp/src/comp.native.dart')
      ..assetPackage = 'comp'
      ..nativeAssets = true,
  );

  // Hard gate: this spec is fully eligible → it MUST be on the @Native path.
  if (!gDart.contains('@Native<') || gDart.contains('_dylib')) {
    stderr.writeln('FAIL: comprehensive all-C++ spec did not emit the @Native path '
        '(@Native: ${gDart.contains('@Native<')}, _dylib: ${gDart.contains('_dylib')}).');
    if (gDart.contains('native-assets: NOT applied')) {
      final line = gDart.split('\n').firstWhere((l) => l.contains('native-assets: NOT applied'), orElse: () => '');
      stderr.writeln('  fallback reason: $line');
    }
    exit(1);
  }

  // Minimal analyzable package: real nitro + nitro_annotations via path deps.
  final repoPkgs = p.normalize(p.join(Directory.current.path, '..'));
  final tmp = Directory.systemTemp.createTempSync('na_analyze_');
  try {
    // dependency_overrides (not plain path deps) so the un-published local
    // nitro/nitro_annotations resolve regardless of nitro's hosted version
    // constraint on nitro_annotations.
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: comp
environment:
  sdk: ">=3.6.0 <4.0.0"
dependencies:
  nitro: any
  nitro_annotations: any
  ffi: ^2.1.0
dependency_overrides:
  nitro:
    path: ${p.join(repoPkgs, 'nitro')}
  nitro_annotations:
    path: ${p.join(repoPkgs, 'nitro_annotations')}
''');
    final libSrc = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
    File(p.join(libSrc.path, 'comp.native.dart')).writeAsStringSync(_spec);
    File(p.join(libSrc.path, 'comp.g.dart')).writeAsStringSync(gDart);

    final pg = Process.runSync('dart', ['pub', 'get'], workingDirectory: tmp.path);
    if (pg.exitCode != 0) {
      stderr.writeln('FAIL: dart pub get\n${pg.stdout}\n${pg.stderr}');
      exit(1);
    }
    // Default strictness: fail on errors + warnings (a bad external signature /
    // arity mismatch is an error/warning). Style infos are advisory, not a gate.
    final an = Process.runSync('dart', ['analyze', 'lib'], workingDirectory: tmp.path);
    stdout.write(an.stdout);
    if (an.exitCode != 0) {
      stderr.writeln('FAIL: the emitted native-assets code did not analyze clean:\n${an.stderr}');
      exit(1);
    }
    stdout.writeln('OK: comprehensive native-assets emit analyzes clean (@Native path, no _dylib).');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
