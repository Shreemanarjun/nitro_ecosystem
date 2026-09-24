import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

// Every C++ module's bridge.g.cpp links into ONE image on Apple (SwiftPM or
// CocoaPods), so its internal helpers must not have external linkage — two
// modules each defining `_nitro_release_instance_streams` was a duplicate
// symbol (nitro_vani: VaniSpeechCpp.o vs VaniProcessorCpp.o).
void main() {
  for (final streams in [false, true]) {
    test('_nitro_release_instance_streams is file-local (${streams ? 'with' : 'no'} streams)', () {
      final cpp = CppBridgeGenerator.generate(SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Demo extends HybridObject {
  int ping(int x);
${streams ? '  @NitroStream(backpressure: Backpressure.dropLatest)\n  Stream<int> get ticks;' : ''}
}
''', sourceUri: 'package:demo/src/demo.native.dart'));
      final decls = RegExp(r'^(.*)void _nitro_release_instance_streams\(', multiLine: true).allMatches(cpp).toList();
      expect(decls, isNotEmpty);
      for (final d in decls) {
        expect(d.group(1), 'static ', reason: d.group(0));
      }
    });
  }
}
