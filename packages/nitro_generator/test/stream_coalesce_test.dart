// Backpressure.batch on every backend: the stream port is bound to the
// per-library batcher, native posts per item, and Dart receives
// [item, item, ...] per wake. No Kotlin/Swift-side accumulators, no
// [count, items...] shape, no item-type restriction.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _src = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@HybridStruct()
class Pt { final double x; final double y; Pt({required this.x, required this.y}); }
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp)
abstract class Demo extends HybridObject {
  @NitroStream(backpressure: Backpressure.batch)
  Stream<int> get ticks;
  @NitroStream(backpressure: Backpressure.batch)
  Stream<Pt> get points;
  @NitroStream(backpressure: Backpressure.batch)
  Stream<String> get names;
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<int> get plain;
}
''';

void main() {
  final spec = SpecFromSource.parse(_src, sourceUri: 'package:demo/src/demo.native.dart');
  final mixed = SpecFromSource.parse(_src.replaceFirst('ios: NativeImpl.cpp, android: NativeImpl.cpp,', 'ios: NativeImpl.swift, android: NativeImpl.kotlin,'), sourceUri: 'package:demo/src/demo.native.dart');

  test('validator: any item kind may batch, on any backend', () {
    for (final s in [spec, mixed]) {
      expect(SpecValidator.validate(s).where((i) => i.code == 'E005'), isEmpty);
    }
  });

  for (final (label, s) in [('all-C++', spec), ('Kotlin/Swift', mixed)]) {
    test('$label Dart: list unpack of the batcher message, ack after each, struct items stay proxies', () {
      final dart = DartFfiGenerator.generate(s);
      expect(dart, contains("_nitroAckPtr = _dylib.lookupFunction"));
      expect(dart, isNot(contains('_nitroBindPtr')), reason: 'no native-async: no shared completion port');
      expect(dart, contains('openStream<List<int>>('));
      expect(dart, contains('openStream<List<PtProxy>>('));
      expect(dart, contains('openStream<List<String>>('));
      expect(dart, contains('unpack: (message) => [for (final m in message as List<dynamic>) unpackItem(m)],'));
      expect('ack: _nitroAckPtr,'.allMatches(dart).length, 3);
      expect(dart, isNot(contains('final count = batch[0];')), reason: 'no [count, items...] shape anywhere');
      expect(dart, contains('openStream<int>('), reason: 'plain stream untouched');
    });

    test('$label C++: register/release bind the port to the batcher; plain streams do not', () {
      final cpp = CppBridgeGenerator.generate(s);
      expect(cpp, contains('g_nitro_batch_demo.coalesce(dart_port);'));
      expect(cpp, contains('g_nitro_batch_demo.uncoalesce(dart_port);'));
      expect(cpp, isNot(contains('_nitro_desktop_post_batch')));
      expect(cpp, isNot(contains('_batch_to_dart')), reason: 'no Swift-shim batch helpers');
      expect(cpp, isNot(contains('_1batch(')), reason: 'no JNI batch emit functions');
      final plainRegister = cpp.substring(cpp.indexOf('void demo_register_plain_stream('));
      expect(plainRegister.substring(0, plainRegister.indexOf('}')), isNot(contains('coalesce')));
    });
  }

  test('Kotlin/Swift specs post batch items one at a time, no accumulator', () {
    final kt = KotlinGenerator.generate(mixed);
    expect(kt, contains('external fun emit_ticks(dartPort: Long, item: Long): Boolean'));
    expect(kt, isNot(contains('emit_ticks_batch')));
    expect(kt, isNot(contains('_flushJob')));
    final swift = SwiftGenerator.generate(mixed);
    expect(swift, isNot(contains('emitBatch')));
    expect(swift, contains('_demo_register_ticks_stream'));
  });
}
