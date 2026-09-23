// Nullable typed-data parameters: null crosses as nullptr + length 0 and
// arrives as null on every backend; an empty list stays a (non-null) empty
// list. Before 0.7.7 the Dart side did not compile, JNI turned null into an
// empty array (and built a byte array for Float32List?), Swift into empty Data.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _src = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp)
abstract class Demo extends HybridObject {
  int maybe(Uint8List? bytes);
  int maybeF(Float32List? v);
  int always(Uint8List bytes);
}
''';

void main() {
  final spec = SpecFromSource.parse(_src, sourceUri: 'package:demo/src/demo.native.dart');

  test('Dart: null → nullptr + 0, list → arena copy', () {
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains('bytes == null ? nullptr : bytes.toPointer(arena), bytes?.length ?? 0'));
    expect(dart, contains('v == null ? nullptr : v.toPointer(arena), v?.length ?? 0'));
    expect(dart, contains('_alwaysPtr(_instanceId, bytes.toPointer(arena), bytes.length'), reason: 'non-null unchanged');
  });

  test('JNI: null stays a Java null; Float32List? builds a float array', () {
    final cpp = CppBridgeGenerator.generate(spec);
    expect(cpp, contains('jbyteArray j_bytes = nullptr;\n    if (bytes != nullptr) {'));
    expect(cpp, contains('jfloatArray j_v = nullptr;'));
    expect(cpp, contains('j_v = env->NewFloatArray((jsize)v_length);'));
  });

  test('Swift: null stays nil; non-null keeps the empty default', () {
    final swift = SwiftGenerator.generate(spec);
    expect(swift, contains('let bytesArr = bytes.map { Data(bytes: \$0, count: Int(bytes_length)) }\n'));
    expect(swift, contains('let vArr = v.map { Array(UnsafeBufferPointer(start: \$0, count: Int(v_length))) }\n'));
    expect(swift, contains('.map { Data(bytes: \$0, count: Int(bytes_length)) } ?? Data()'), reason: 'non-null Uint8List param unchanged');
  });
}
