// Cross-language wire agreement for every @HybridRecord field kind.
//
// Dart's RecordWriter is the reference. Each native codec — C++, Swift, Kotlin,
// exactly as the generator emits them — must decode the reference bytes and
// re-encode them to the same bytes. One record per type family, at sizes that
// cross the codecs' bulk paths, plus every nullable form.
//
// Text assertions cannot do this. The first run found a Kotlin decode for a
// nullable String field that had never compiled.
//
//   dart run tool/verify_record_wire.dart           # legs whose compiler is on PATH
//   dart run tool/verify_record_wire.dart --require=cpp,swift,kotlin
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro/src/web/record_codec_web.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';

BridgeRecordField _f(String name, String type, RecordFieldKind kind, [String? item]) =>
    BridgeRecordField(name: name, dartType: type, kind: kind, itemTypeName: item, isNullable: type.endsWith('?'));

const _p = RecordFieldKind.primitive, _lp = RecordFieldKind.listPrimitive, _td = RecordFieldKind.typedData;

/// One record per type family. `Point` is only used nested.
final _records = [
  BridgeRecordType(name: 'Scalars', fields: [_f('a', 'int', _p), _f('b', 'double', _p), _f('c', 'bool', _p), _f('s', 'String', _p)]),
  BridgeRecordType(
    name: 'Opt',
    fields: [
      _f('a', 'int?', _p),
      _f('b', 'double?', _p),
      _f('s', 'String?', _p),
      _f('c', 'bool?', _p),
      _f('bytes', 'Uint8List?', _td),
      _f('floats', 'Float32List?', _td),
      _f('ints', 'List<int>?', _lp, 'int'),
      _f('point', 'Point?', RecordFieldKind.recordObject),
    ],
  ),
  BridgeRecordType(
    name: 'Lists',
    fields: [
      _f('i', 'List<int>', _lp, 'int'),
      _f('d', 'List<double>', _lp, 'double'),
      _f('b', 'List<bool>', _lp, 'bool'),
      _f('s', 'List<String>', _lp, 'String'),
    ],
  ),
  BridgeRecordType(name: 'Point', fields: [_f('x', 'double', _p), _f('y', 'double', _p)]),
  BridgeRecordType(name: 'Points', fields: [_f('v', 'List<Point>', RecordFieldKind.listRecordObject, 'Point'), _f('last', 'Point', RecordFieldKind.recordObject)]),
  BridgeRecordType(
    name: 'Typed',
    fields: [
      // A one-byte field first, so every wider array below starts unaligned.
      _f('flag', 'bool', _p),
      _f('u8', 'Uint8List', _td),
      _f('i16', 'Int16List', _td),
      _f('i32', 'Int32List', _td),
      _f('i64', 'Int64List', _td),
      _f('f32', 'Float32List', _td),
      _f('f64', 'Float64List', _td),
    ],
  ),
];

BridgeSpec _spec() => BridgeSpec(
  dartClassName: 'Wire',
  lib: 'wire',
  namespace: 'wire',
  iosImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'wire.native.dart',
  recordTypes: _records,
  functions: [
    BridgeFunction(dartName: 'scalars', cSymbol: 'wire_scalars', isAsync: false, returnType: BridgeType(name: 'Scalars', isRecord: true), params: []),
  ],
);

// ── The reference encoding, field by field, with the Dart writer ────────────

void _blob(RecordWriter w, TypedData d) => w.writeBlob(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes));

void _point(RecordWriter w, int i) => w
  ..writeDouble(i * 1.5)
  ..writeDouble(-i / 3);

/// Framed bytes for every case: `<record>.<case>` -> `[4B len][payload]`.
Map<String, Uint8List> _cases() {
  final out = <String, Uint8List>{};
  void add(String name, void Function(RecordWriter w) write) {
    final w = RecordWriter();
    write(w);
    out[name] = w.takeFramedBytes();
  }

  // 64 / 65 chars and a late non-ASCII char: the Kotlin writer copies ASCII
  // strings of up to 64 chars itself and backs out on the first other char.
  for (final s in ['', 'ascii only', 'ünïcødé ✓ 日本語', '\u{FEFF}leading bom', 'x' * 5000, 'y' * 64, 'y' * 65, '${'z' * 63}é']) {
    add('Scalars.${out.length}', (w) => w..writeInt(-42)..writeDouble(1e300)..writeBool(true)..writeString(s));
  }
  add('Scalars.limits', (w) => w..writeInt(-9223372036854775808)..writeDouble(double.negativeInfinity)..writeBool(false)..writeString('a'));

  // Every nullable field absent, then every one present.
  add('Opt.absent', (w) {
    for (var i = 0; i < 8; i++) {
      w.writeNullTag(true);
    }
  });
  add('Opt.present', (w) {
    w..writeNullTag(false)..writeInt(7);
    w..writeNullTag(false)..writeDouble(2.5);
    w..writeNullTag(false)..writeString('présent');
    w..writeNullTag(false)..writeBool(true);
    w..writeNullTag(false)..writeBlob(Uint8List.fromList(List.generate(300, (i) => i & 0xff)));
    w.writeNullTag(false);
    _blob(w, Float32List.fromList(List.generate(33, (i) => i * 0.25)));
    w..writeNullTag(false)..writeIntList(List.generate(5, (i) => i - 2));
    w.writeNullTag(false);
    _point(w, 9);
  });

  // 256 and 1000: the C++ bool-list writer works in 256-item chunks.
  for (final n in [0, 1, 7, 256, 1000]) {
    add('Lists.$n', (w) {
      w.writeIntList(List.generate(n, (i) => i * 1000003 - 5));
      w.writeDoubleList(List.generate(n, (i) => i * 0.125 - 1));
      w.writeBoolList(List.generate(n, (i) => i % 3 == 0));
      w.writeInt32(n);
      for (var i = 0; i < n; i++) {
        w.writeString(i.isEven ? 'item $i' : 'élément $i');
      }
    });
    add('Points.$n', (w) {
      w.writeInt32(n);
      for (var i = 0; i < n; i++) {
        _point(w, i);
      }
      _point(w, n);
    });
    add('Typed.$n', (w) {
      w.writeBool(n.isOdd);
      w.writeBlob(Uint8List.fromList(List.generate(n, (i) => (i * 7) & 0xff)));
      _blob(w, Int16List.fromList(List.generate(n, (i) => i * 31 - 16000)));
      _blob(w, Int32List.fromList(List.generate(n, (i) => i * 2654435 - 9)));
      _blob(w, Int64List.fromList(List.generate(n, (i) => i * 4294967311 - 3)));
      _blob(w, Float32List.fromList(List.generate(n, (i) => i / 7)));
      _blob(w, Float64List.fromList(List.generate(n, (i) => i / 11 - 1e-9)));
    });
  }
  return out;
}

// ── Native drivers: decode every `<Record>.<case>.bin`, write it back out ───

String _cppDriver() {
  final b = StringBuffer('''
#include "wire.native.g.h"
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
static std::vector<uint8_t> slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); return {std::istreambuf_iterator<char>(f), {}}; }
static void spit(const std::string& p, NitroCppBuffer b) { std::ofstream f(p, std::ios::binary); f.write((const char*)b.data, (std::streamsize)b.size); ::free((void*)b.data); }
int main(int argc, char** argv) {
  std::string dir = argv[1];
  for (int i = 2; i < argc; i++) {
    std::string name = argv[i], type = name.substr(0, name.find('.'));
    auto in = slurp(dir + "/" + name + ".bin");
    NitroCppBuffer payload = { in.data() + 4, in.size() - 4 };
''');
  for (final r in _records) {
    b.writeln('    if (type == "${r.name}") { spit(dir + "/" + name + ".out", ${r.name}::fromNative(payload).toNativeBuffer()); continue; }');
  }
  b.writeln('    std::fprintf(stderr, "unknown record %s\\n", type.c_str()); return 2;\n  }\n  return 0;\n}');
  return b.toString();
}

String _swiftDriver() {
  final b = StringBuffer('''
import Foundation
let dir = CommandLine.arguments[1]
for name in CommandLine.arguments.dropFirst(2) {
  let type = name.split(separator: ".")[0]
  let data = try! Data(contentsOf: URL(fileURLWithPath: "\\(dir)/\\(name).bin"))
  let wire = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
  data.copyBytes(to: wire, count: data.count)
  let out: UnsafeMutablePointer<UInt8>?
  switch type {
''');
  for (final r in _records) {
    b.writeln('  case "${r.name}": out = ${r.name}.fromNative(wire).toNative()');
  }
  b.writeln('''
  default: fatalError("unknown record \\(type)")
  }
  let n = Int(out!.withMemoryRebound(to: Int32.self, capacity: 1) { \$0.pointee }) + 4
  try! Data(bytes: out!, count: n).write(to: URL(fileURLWithPath: "\\(dir)/\\(name).out"))
}''');
  return b.toString();
}

String _kotlinDriver() {
  final b = StringBuffer('''
fun main(args: Array<String>) {
    val dir = args[0]
    for (name in args.drop(1)) {
        val bytes = java.io.File("\$dir/\$name.bin").readBytes()
        val out = when (name.substringBefore('.')) {
''');
  for (final r in _records) {
    b.writeln('            "${r.name}" -> ${r.name}.decode(bytes).encode()');
  }
  b.writeln('''
            else -> error("unknown record \$name")
        }
        java.io.File("\$dir/\$name.out").writeBytes(out)
    }
}''');
  return b.toString();
}

bool _onPath(String tool) => Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

Future<void> main(List<String> args) async {
  final require = args.where((a) => a.startsWith('--require=')).expand((a) => a.substring(10).split(',')).toSet();
  final tmp = Directory.systemTemp.createTempSync('nitro_wire_');
  var failures = 0;
  try {
    final cases = _cases();
    for (final e in cases.entries) {
      File('${tmp.path}/${e.key}.bin').writeAsBytesSync(e.value);
    }
    final names = cases.keys.toList();
    final spec = _spec();
    final native = Directory('../nitro/src/native').existsSync() ? '../nitro/src/native' : 'packages/nitro/src/native';

    /// Builds one language's driver, runs it over every case, compares.
    void leg(String lang, {required bool available, required ProcessResult Function() build, required List<String> run}) {
      if (!available) {
        if (require.contains(lang)) {
          stdout.writeln('FAIL  $lang: required, but its compiler is not on PATH');
          failures++;
        } else {
          stdout.writeln('SKIP  $lang (compiler not on PATH)');
        }
        return;
      }
      final built = build();
      if (built.exitCode != 0) {
        stdout.writeln('FAIL  $lang: generated codec does not compile\n${built.stderr}');
        failures++;
        return;
      }
      final ran = Process.runSync(run.first, [...run.skip(1), tmp.path, ...names]);
      if (ran.exitCode != 0) {
        stdout.writeln('FAIL  $lang: driver exited ${ran.exitCode}\n${ran.stderr}');
        failures++;
        return;
      }
      final wrong = [
        for (final n in names)
          if (!_same(cases[n]!, File('${tmp.path}/$n.out').readAsBytesSync())) n,
      ];
      for (final n in names) {
        File('${tmp.path}/$n.out').deleteSync();
      }
      if (wrong.isEmpty) {
        stdout.writeln('PASS  $lang: ${names.length} records decoded and re-encoded byte for byte');
      } else {
        stdout.writeln('FAIL  $lang: re-encoded bytes differ for ${wrong.join(', ')}');
        failures++;
      }
    }

    // C++
    File('${tmp.path}/wire.bridge.g.h').writeAsStringSync(CppHeaderGenerator.generate(spec));
    File('${tmp.path}/wire.native.g.h').writeAsStringSync(CppInterfaceGenerator.generate(spec));
    File('${tmp.path}/driver.cpp').writeAsStringSync(_cppDriver());
    final cxx = Platform.environment['CXX'] ?? 'c++';
    leg(
      'cpp',
      available: _onPath(cxx),
      build: () => Process.runSync(cxx, ['-std=c++17', '-O1', '-Wall', '-I', tmp.path, '-I', native, '${tmp.path}/driver.cpp', '-o', '${tmp.path}/cpp_driver']),
      run: ['${tmp.path}/cpp_driver'],
    );

    // Swift: generated for Apple targets only.
    File('${tmp.path}/Records.swift').writeAsStringSync(
      'import Foundation\npublic protocol NitroEncodable { func toNative() -> UnsafeMutablePointer<UInt8>? }\n${RecordGenerator.generateSwift(spec)}',
    );
    File('${tmp.path}/main.swift').writeAsStringSync(_swiftDriver());
    leg(
      'swift',
      available: Platform.isMacOS && _onPath('swiftc'),
      build: () => Process.runSync('swiftc', ['-O', '-wmo', '${tmp.path}/Records.swift', '${tmp.path}/main.swift', '-o', '${tmp.path}/swift_driver']),
      run: ['${tmp.path}/swift_driver'],
    );

    // Kotlin, on the JVM. The generated code carries an Android-only annotation.
    File('${tmp.path}/Keep.kt').writeAsStringSync('package androidx.annotation\nannotation class Keep\n');
    File('${tmp.path}/Records.kt').writeAsStringSync(RecordGenerator.generateKotlin(spec));
    File('${tmp.path}/Driver.kt').writeAsStringSync(_kotlinDriver());
    leg(
      'kotlin',
      available: _onPath('kotlinc') && _onPath('java'),
      build: () => Process.runSync('kotlinc', ['${tmp.path}/Keep.kt', '${tmp.path}/Records.kt', '${tmp.path}/Driver.kt', '-include-runtime', '-d', '${tmp.path}/kt_driver.jar']),
      run: ['java', '-jar', '${tmp.path}/kt_driver.jar'],
    );
  } finally {
    tmp.deleteSync(recursive: true);
  }
  stdout.writeln(failures == 0 ? '\nnative record codecs agree with the Dart wire format' : '\n$failures leg(s) failed');
  exitCode = failures == 0 ? 0 : 1; // main's return value is ignored
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
