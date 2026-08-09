// Compiles generated C++ bridges with a real compiler.
//
// Generator unit tests assert on emitted text, which cannot catch "this does not
// build" — issue #40 shipped exactly that: JNI code emitted into a JNI-free
// bridge, textually fine, uncompilable for Android. This closes that gap.
//
//   dart run tool/verify_cpp_bridge_compiles.dart
import 'dart:io';

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';

/// All-cpp module with a @zeroCopy struct field — the issue #40 repro.
BridgeSpec _zeroCopyCppSpec() => BridgeSpec(
  dartClassName: 'Repro',
  lib: 'repro',
  namespace: 'repro',
  iosImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'repro.native.dart',
  structs: [
    BridgeStruct(
      name: 'Chunk',
      packed: false,
      fields: [
        BridgeField(name: 'bytes', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
        BridgeField(name: 'requestId', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'chunks',
      registerSymbol: 'repro_register_chunks_stream',
      releaseSymbol: 'repro_release_chunks_stream',
      itemType: BridgeType(name: 'Chunk'),
      backpressure: Backpressure.bufferDrop,
    ),
  ],
  functions: [],
);

Future<int> main() async {
  final cc = Platform.environment['CXX'] ?? 'clang++';
  final dartApiDl = Directory('benchmark/src/native').existsSync()
      ? 'benchmark/src/native'
      : '../../benchmark/src/native';

  final cases = <String, BridgeSpec>{'zero_copy_all_cpp (#40)': _zeroCopyCppSpec()};

  var failures = 0;
  for (final entry in cases.entries) {
    final dir = Directory.systemTemp.createTempSync('nitro_cc_');
    try {
      final spec = entry.value;
      File('${dir.path}/${spec.lib}.bridge.g.h').writeAsStringSync(CppHeaderGenerator.generate(spec));
      File('${dir.path}/${spec.lib}.native.g.h').writeAsStringSync(CppInterfaceGenerator.generate(spec));
      final src = File('${dir.path}/${spec.lib}.bridge.g.cpp')
        ..writeAsStringSync(CppBridgeGenerator.generate(spec));

      // No -I for jni.h: an all-cpp bridge must not need it. Android defines
      // __ANDROID__, so compile with it set to reach any guarded block.
      final r = Process.runSync(cc, [
        '-fsyntax-only', '-std=c++17', '-D__ANDROID__',
        '-I', dir.path, '-I', dartApiDl, src.path,
      ]);
      if (r.exitCode == 0) {
        stdout.writeln('PASS  ${entry.key}');
      } else {
        failures++;
        stdout.writeln('FAIL  ${entry.key}\n${r.stderr}');
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
  stdout.writeln(failures == 0 ? '\nall bridges compile' : '\n$failures bridge(s) failed to compile');
  return failures == 0 ? 0 : 1;
}
