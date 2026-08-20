// Cross-language wire check for the C++ indexed-list helpers.
//
// The C++ bridge forwards lists as an opaque [4B len][payload] blob and never
// parses them, so nothing in the generated code can tell us whether a
// hand-written C++ impl agrees with the Dart codec. Generator unit tests assert
// on emitted text; they cannot catch "this compiles but reads the offset table
// as field bytes". That is exactly the bug class that shipped once already.
//
// So: emit the real generated reader/writer, compile them with a real C++
// compiler, and round-trip actual bytes produced by the real Dart codec.
//
//   dart run tool/verify_cpp_indexed_list.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nitro/src/web/record_codec_web.dart';
// cpp_record_generator.dart is a `part of` record_generator.dart, so the
// reader definition is reached through the enclosing library.
import 'package:nitro_generator/src/generators/record_generator.dart';

typedef _Row = (int id, String name, double score);

const _rows = <_Row>[
  (1, '', 1.5),
  (2, 'a', 2.5),
  (7, 'a longer label', -3.25),
  (9, 'ünïcødé ✓', 4.0),
];

/// The writer struct is emitted by CppInterfaceGenerator inside a full header;
/// re-declaring just the pieces under test keeps this gate independent of the
/// surrounding module scaffolding.
const _writerStruct = r'''
struct NitroCppBuffer { const uint8_t* data; size_t size; };

struct NitroRecordWriter {
  std::vector<uint8_t> _buf;
  NitroRecordWriter() { _buf.reserve(64); }
  void writeInt(int64_t v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 8); }
  void writeInt32(int32_t v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 4); }
  void writeDouble(double v) { _buf.insert(_buf.end(), reinterpret_cast<const uint8_t*>(&v), reinterpret_cast<const uint8_t*>(&v) + 8); }
  void writeString(const std::string& s) { int32_t n = (int32_t)s.size(); writeInt32(n); _buf.insert(_buf.end(), s.begin(), s.end()); }
  uint8_t* toNative() const {
      int32_t payloadLen = (int32_t)_buf.size();
      uint8_t* out = (uint8_t*)::malloc(sizeof(int32_t) + (size_t)payloadLen);
      if (!out) return nullptr;
      ::memcpy(out, &payloadLen, sizeof(int32_t));
      if (payloadLen > 0) ::memcpy(out + sizeof(int32_t), _buf.data(), (size_t)payloadLen);
      return out;
  }
  template <typename T, typename WriteItem>
  void writeIndexedList(const std::vector<T>& items, WriteItem writeItem) {
      int32_t n = (int32_t)items.size();
      writeInt32(n);
      size_t tableStart = _buf.size();
      for (int32_t i = 0; i < n; i++) writeInt(0);
      std::vector<int64_t> offsets((size_t)n);
      for (int32_t i = 0; i < n; i++) {
          offsets[(size_t)i] = (int64_t)_buf.size();
          writeItem(*this, items[(size_t)i]);
      }
      for (int32_t i = 0; i < n; i++)
          ::memcpy(_buf.data() + tableStart + (size_t)i * 8, &offsets[(size_t)i], 8);
  }
};
''';

/// Reads Dart-encoded bytes on stdin, verifies them, re-encodes, writes stdout.
const _main = r'''
struct Row { int64_t id; std::string name; double score; };

int main() {
    std::vector<uint8_t> in((std::istreambuf_iterator<char>(std::cin)),
                             std::istreambuf_iterator<char>());
    if (in.size() < 4) { std::cerr << "short input\n"; return 2; }
    int32_t payloadLen; std::memcpy(&payloadLen, in.data(), 4);
    if ((size_t)payloadLen + 4 != in.size()) {
        std::cerr << "frame len " << payloadLen << " != " << (in.size() - 4) << "\n";
        return 2;
    }

    NitroRecordReader r(in.data() + 4, (size_t)payloadLen);
    std::vector<Row> rows = r.readIndexedList<Row>([](NitroRecordReader& rr) {
        Row row;
        row.id = rr.readInt();
        row.name = rr.readString();
        row.score = rr.readDouble();
        return row;
    });

    // Re-encode with the writer helper; Dart decodes this back and compares.
    NitroRecordWriter w;
    w.writeIndexedList<Row>(rows, [](NitroRecordWriter& ww, const Row& row) {
        ww.writeInt(row.id + 100);
        ww.writeString(row.name + "|cpp");
        ww.writeDouble(row.score * 2.0);
    });
    uint8_t* out = w.toNative();
    int32_t outLen; std::memcpy(&outLen, out, 4);
    std::cout.write(reinterpret_cast<const char*>(out), 4 + outLen);
    ::free(out);
    return 0;
}
''';

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('nitro_cpp_list');
  try {
    final src = File('${tmp.path}/main.cpp');
    await src.writeAsString(
      '#include <cstdint>\n#include <cstring>\n#include <cstdlib>\n'
      '#include <string>\n#include <vector>\n#include <stdexcept>\n'
      '#include <iostream>\n#include <iterator>\n\n'
      '$_writerStruct\n$cppRecordReaderDefinition\n\n$_main',
    );

    final bin = '${tmp.path}/a.out';
    final compile = await Process.run('c++', ['-std=c++17', '-O1', '-Wall', src.path, '-o', bin]);
    if (compile.exitCode != 0) {
      stderr.writeln('COMPILE FAILED:\n${compile.stderr}');
      exit(1);
    }
    stdout.writeln('✓ generated reader/writer compile clean (c++17, -Wall)');

    // Dart encodes exactly as the web bridge does for a List<@HybridRecord>.
    final encoded = RecordWriter.encodeIndexedListBytes<_Row>(_rows, (w, r) {
      w.writeInt(r.$1);
      w.writeString(r.$2);
      w.writeDouble(r.$3);
    });

    final proc = await Process.start(bin, []);
    proc.stdin.add(encoded);
    await proc.stdin.close();
    final outBytes = <int>[];
    await proc.stdout.forEach(outBytes.addAll);
    final errText = await utf8.decoder.bind(proc.stderr).join();
    if (await proc.exitCode != 0) {
      stderr.writeln('C++ REJECTED Dart bytes: $errText');
      exit(1);
    }
    stdout.writeln('✓ C++ readIndexedList consumed Dart-encoded bytes');

    final back = RecordReader.decodeIndexedListBytes<_Row>(
      Uint8List.fromList(outBytes),
      (r) => (r.readInt(), r.readString(), r.readDouble()),
    );

    if (back.length != _rows.length) {
      stderr.writeln('count mismatch: ${back.length} != ${_rows.length}');
      exit(1);
    }
    for (var i = 0; i < _rows.length; i++) {
      final want = (_rows[i].$1 + 100, '${_rows[i].$2}|cpp', _rows[i].$3 * 2.0);
      if (back[i].$1 != want.$1 || back[i].$2 != want.$2 || (back[i].$3 - want.$3).abs() > 1e-9) {
        stderr.writeln('row $i mismatch:\n  got  ${back[i]}\n  want $want');
        exit(1);
      }
    }
    stdout.writeln('✓ Dart decoded C++ writeIndexedList output, all ${back.length} rows match');
    stdout.writeln('C++ <-> Dart indexed-list wire agreement verified.');
  } finally {
    await tmp.delete(recursive: true);
  }
}
