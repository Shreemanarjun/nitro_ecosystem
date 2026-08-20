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

/// Web-targeting all-cpp module with a stream + native-async — exercises the
/// __EMSCRIPTEN__ seam (nitro_wasm_compat.h include, post-fn setter, posts
/// routed through the compat shim). Compiled with em++ when emsdk is on PATH.
BridgeSpec _webWasmSpec() => BridgeSpec(
  dartClassName: 'WebRepro',
  lib: 'web_repro',
  namespace: 'web_repro',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  webImpl: NativeImpl.wasm,
  sourceUri: 'web_repro.native.dart',
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
      registerSymbol: 'web_repro_register_chunks_stream',
      releaseSymbol: 'web_repro_release_chunks_stream',
      itemType: BridgeType(name: 'Chunk'),
      backpressure: Backpressure.bufferDrop,
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoAsync',
      cSymbol: 'web_repro_echo_async',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'int'))],
    ),
  ],
);

/// Records whose list fields are nullable. The C++ codec has to emplace into a
/// `std::optional<std::vector<T>>` and bracket it with a null tag; getting the
/// accessor wrong (`.size()` on an optional) is a compile error that emitted-text
/// assertions cannot see.
BridgeSpec _nullableListFieldsSpec() => BridgeSpec(
  dartClassName: 'ListRepro',
  lib: 'list_repro',
  namespace: 'list_repro',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'list_repro.native.dart',
  enums: [
    BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'high']),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Inner',
      fields: [BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive)],
    ),
    BridgeRecordType(
      name: 'Outer',
      fields: [
        BridgeRecordField(
          name: 'tags',
          dartType: 'List<int>?',
          kind: RecordFieldKind.listPrimitive,
          itemTypeName: 'int',
          isNullable: true,
        ),
        BridgeRecordField(
          name: 'levels',
          dartType: 'List<Level>?',
          kind: RecordFieldKind.listEnumValue,
          itemTypeName: 'Level',
          isNullable: true,
        ),
        BridgeRecordField(
          name: 'items',
          dartType: 'List<Inner>?',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Inner',
          isNullable: true,
        ),
        // Non-nullable siblings must keep compiling unchanged.
        BridgeRecordField(
          name: 'required',
          dartType: 'List<Inner>',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Inner',
        ),
        BridgeRecordField(name: 'trailing', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoOuter',
      cSymbol: 'list_repro_echo_outer',
      isAsync: false,
      returnType: BridgeType(name: 'Outer', isRecord: true),
      params: [BridgeParam(name: 'v', type: BridgeType(name: 'Outer', isRecord: true))],
    ),
  ],
);

Future<int> main() async {
  final cc = Platform.environment['CXX'] ?? 'clang++';
  final dartApiDl = Directory('benchmark/src/native').existsSync()
      ? 'benchmark/src/native'
      : '../../benchmark/src/native';

  final cases = <String, BridgeSpec>{
    'zero_copy_all_cpp (#40)': _zeroCopyCppSpec(),
    'web_wasm_all_cpp': _webWasmSpec(),
    'nullable_list_record_fields': _nullableListFieldsSpec(),
  };

  // em++ is optional locally, required in the web CI job (NITRO_REQUIRE_EMCC=1).
  final emcc = Process.runSync('sh', ['-c', 'command -v em++']).exitCode == 0;
  final requireEmcc = Platform.environment['NITRO_REQUIRE_EMCC'] == '1';
  if (!emcc && requireEmcc) {
    stderr.writeln('NITRO_REQUIRE_EMCC=1 but em++ is not on PATH');
    return 1;
  }
  final nitroNative = Directory('../nitro/src/native').existsSync()
      ? '../nitro/src/native'
      : 'packages/nitro/src/native';

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

      // Web seam: compile the same bridge with em++ (defines __EMSCRIPTEN__).
      if (spec.webIsWasm && emcc) {
        final w = Process.runSync('em++', [
          '-fsyntax-only', '-std=c++17',
          '-I', dir.path, '-I', nitroNative, src.path,
        ]);
        if (w.exitCode == 0) {
          stdout.writeln('PASS  ${entry.key} (em++)');
        } else {
          failures++;
          stdout.writeln('FAIL  ${entry.key} (em++)\n${w.stderr}');
        }
      } else if (spec.webIsWasm) {
        stdout.writeln('SKIP  ${entry.key} (em++ not on PATH)');
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
  stdout.writeln(failures == 0 ? '\nall bridges compile' : '\n$failures bridge(s) failed to compile');
  return failures == 0 ? 0 : 1;
}
