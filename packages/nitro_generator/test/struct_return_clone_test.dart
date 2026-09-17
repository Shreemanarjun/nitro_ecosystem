// A @HybridStruct returned by a C++ implementation must come back with fresh
// malloc'd pointer fields: Dart frees each one (`freeFields`), so returning the
// impl's own storage or the caller's arguments is a double free (Linux glibc
// aborts; found by the type-coverage Linux container run, §71).
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _source = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@HybridStruct()
class Inner { final double x; final double y; Inner({required this.x, required this.y}); }
@HybridStruct()
class Rich { final String label; final Uint8List bytes; final Inner origin; final int count; final Float64List scores;
  Rich({required this.label, required this.bytes, required this.origin, required this.count, required this.scores}); }
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp)
abstract class Demo extends HybridObject {
  Rich echoRich(Rich value);
  @nitroAsync
  Future<Rich> echoRichAsync(Rich value);
  Rich get current;
}
''';

void main() {
  late String cpp;
  setUpAll(() {
    cpp = CppBridgeGenerator.generate(SpecFromSource.parse(_source, sourceUri: 'package:demo/src/demo.native.dart'));
  });

  test('one deep-copy helper per struct: strdup strings, memcpy typed data by element size, recurse into nested structs', () {
    expect(cpp, contains('static Rich _nitro_clone_Rich(const Rich& _s) {'));
    expect(cpp, contains('_c.label = _s.label ? strdup(_s.label) : nullptr;'));
    expect(cpp, contains('size_t _len = (size_t)_s.bytesLength * sizeof(*_s.bytes);'));
    expect(cpp, contains('if (_len) memcpy(_c.bytes, _s.bytes, _len);'));
    expect(cpp, contains('size_t _len = (size_t)_s.scoresLength * sizeof(*_s.scores);'));
    expect(cpp, contains('_c.origin = (Inner*)malloc(sizeof(Inner));'));
    expect(cpp, contains('*_c.origin = _nitro_clone_Inner(*_s.origin);'));
    expect(cpp, contains('static Inner _nitro_clone_Inner(const Inner& _s) {\n    Inner _c = _s;\n    return _c;\n}'), reason: 'no pointer fields: plain copy');
  });

  test('every struct return site (sync, async, property getter) hands Dart the clone, never the impl value', () {
    expect(RegExp(r'\*_ptr = _nitro_clone_Rich\(_res\);').allMatches(cpp).length, 3);
    expect(cpp, isNot(contains('*_ptr = _res;')));
  });

  test('@zeroCopy fields stay borrowed (Dart never frees them); an explicit <field>Length companion supplies the count', () {
    final spec = BridgeSpec(
      dartClassName: 'Demo', lib: 'demo', namespace: 'demo', sourceUri: 'demo.native.dart',
      iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp, macosImpl: NativeImpl.cpp, linuxImpl: NativeImpl.cpp, windowsImpl: NativeImpl.cpp,
      structs: [
        BridgeStruct(name: 'Frame', packed: false, fields: [
          BridgeField(name: 'data', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
          BridgeField(name: 'pcm', type: BridgeType(name: 'Float32List')),
          BridgeField(name: 'pcmLength', type: BridgeType(name: 'int')),
          BridgeField(name: 'width', type: BridgeType(name: 'int')),
        ]),
      ],
      functions: [BridgeFunction(dartName: 'echoFrame', cSymbol: 'demo_echo_frame', isAsync: false, returnType: BridgeType(name: 'Frame'), params: [BridgeParam(name: 'f', type: BridgeType(name: 'Frame'))])],
    );
    final out = CppBridgeGenerator.generate(spec);
    final clone = out.substring(out.indexOf('static Frame _nitro_clone_Frame(const Frame& _s) {'));
    final body = clone.substring(0, clone.indexOf('\n}\n'));
    expect(body, isNot(contains('_s.data')), reason: 'zero-copy view is not copied');
    expect(body, contains('size_t _len = (size_t)_s.pcmLength * sizeof(*_s.pcm);'));
    expect(out, isNot(contains('dataLength')));
    expect(out, contains('*_ptr = _nitro_clone_Frame(_res);'));
  });
}
