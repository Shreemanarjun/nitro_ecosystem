// Stream<TypedData> items used to be posted as kNull on every backend (and the
// Swift sink did not compile). Each backend now posts a Dart typed list of the
// declared element type; web rebuilds it from the shim's raw bytes.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _src = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp, web: WebNativeImpl.wasm)
abstract class Demo extends HybridObject {
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<Uint8List> get bytes;
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<Float32List> get floats;
}
''';

void main() {
  _dateTimeStreams();
  _lifecycleLogs();
  final spec = SpecFromSource.parse(_src, sourceUri: 'package:demo/src/demo.native.dart');
  final cpp = CppBridgeGenerator.generate(spec);

  test('no backend posts kNull for a typed-data item any more', () {
    for (final fn in ['emit_1bytes(', 'emit_1floats(', '_emit_bytes_to_dart(', 'HybridDemo::emit_bytes(']) {
      final i = cpp.indexOf(fn);
      expect(i, greaterThan(0), reason: fn);
      final body = cpp.substring(i, cpp.indexOf('\n}\n', i));
      expect(body, contains('Dart_CObject_kTypedData'), reason: fn);
    }
  });

  test('element type follows the Dart list type', () {
    expect(cpp, contains('obj.value.as_typed_data.type = Dart_TypedData_kUint8;'));
    expect(cpp, contains('obj.value.as_typed_data.type = Dart_TypedData_kFloat32;'));
    expect(cpp, contains('(intptr_t)(item.size / 4)'), reason: 'C++ buffer size is in bytes');
  });

  test('Swift passes (pointer, count) through the C callback', () {
    final swift = SwiftGenerator.generate(spec);
    expect(swift, contains('_ emitCb: @convention(c) (Int64, UnsafeRawPointer?, Int64) -> Bool'));
    expect(swift, contains('item.withUnsafeBytes { buf in'));
    expect(swift, contains('item.withUnsafeBufferPointer { buf in'));
  });

  test('web rebuilds the element type from bytes', () {
    final web = WebBridgeGenerator.generate(spec);
    expect(web, contains('Float32List.sublistView(Uint8List.fromList(message as Uint8List))'));
    expect(web, contains('return message as Uint8List;'));
  });
}

void _dateTimeStreams() {
  test('Swift shim posts DateTime (and DateTime?) stream items as epoch ms, not kNull', () {
    const src = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Demo extends HybridObject {
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<DateTime> get dates;
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<DateTime?> get maybeDates;
}
''';
    final cpp = CppBridgeGenerator.generate(SpecFromSource.parse(src, sourceUri: 'package:demo/src/demo.native.dart'));
    String body(String fn) {
      final i = cpp.indexOf(fn);
      return cpp.substring(i, cpp.indexOf('\n}\n', i));
    }

    expect(body('bool _emit_dates_to_dart('), contains('obj.value.as_int64 = (int64_t)item;'));
    expect(body('bool _emit_maybeDates_to_dart('), contains('const int64_t* item'));
    expect(body('bool _emit_maybeDates_to_dart('), contains('obj.value.as_int64 = *item;'));
  });
}

void _lifecycleLogs() {
  test('lifecycle log messages and the init Stopwatch exist only at verbose', () {
    parse(String web) => SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin$web)
abstract class Demo extends HybridObject {
  int ping(int x);
}
''', sourceUri: 'package:demo/src/demo.native.dart');
    const verbose = 'NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose';
    final dart = DartFfiGenerator.generate(parse(''));
    expect(dart, contains('final initSw = $verbose ? (Stopwatch()..start()) : null;'));
    expect(dart, isNot(contains('initSw.stop()')));
    expect(RegExp(r"if \(initSw != null\) \{\n\s*NitroRuntime\.logLifecycle\('init").hasMatch(dart), isTrue);
    expect(RegExp("if \\(${RegExp.escape(verbose)}\\) \\{\\n\\s*NitroRuntime\\.logLifecycle\\('dispose\\(demo\\)', 'disposing").hasMatch(dart), isTrue);
    final web = WebBridgeGenerator.generate(parse(', web: WebNativeImpl.wasm'));
    for (final what in ['web instance created', 'web instance disposed']) {
      expect(RegExp("if \\(${RegExp.escape(verbose)}\\) \\{\\n\\s*NitroRuntime\\.logLifecycle\\('\\w+', '$what").hasMatch(web), isTrue, reason: what);
    }
  });
}
