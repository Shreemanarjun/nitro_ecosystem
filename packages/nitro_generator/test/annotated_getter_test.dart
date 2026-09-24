// Getters carrying a method annotation take the method path, so every annotation and type works on them — but
// every emitter keeps the PROPERTY shape: Dart `T get x`, Swift `var x`,
// Kotlin `val x`, C++ `get_x()`. Plain getters stay on the property path.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_impl_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_mock_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

String _src(String impl) => '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule($impl)
abstract class Demo extends HybridObject {
  @nitroFast
  int get level;
  @mainThread
  double get width;
  @nitroAsync
  Future<String> get label;
  @nitroNativeAsync
  Future<int> get remote;
  int get plain;
}
''';

String _flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('read/write properties', readWriteProperties);
  final platform = SpecFromSource.parse(_src('ios: NativeImpl.swift, android: NativeImpl.kotlin'), sourceUri: 'package:demo/src/demo.native.dart');
  final cpp = SpecFromSource.parse(
    _src('ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp, linux: NativeImpl.cpp, windows: NativeImpl.cpp'),
    sourceUri: 'package:demo/src/demo.native.dart',
  );
  const getters = ['level', 'width', 'label', 'remote'];

  test('annotated getters take the method path; a plain getter stays a property', () {
    expect(platform.functions.where((f) => f.isGetter).map((f) => f.dartName), getters);
    expect(platform.properties.map((p) => p.dartName), ['plain']);
  });

  test('Dart: getter signatures, each with its annotation behaviour', () {
    final dart = _flat(DartFfiGenerator.generate(platform));
    expect(dart, contains('int get level {'));
    expect(dart, isNot(contains('int level(')));
    expect(dart, contains('Future<String> get label'));
    expect(dart, contains('Future<int> get remote'));
    expect(dart, contains('int get plain'));
    // @nitroFast: bare call, no error-slot check in the getter body.
    final body = dart.substring(dart.indexOf('int get level {'), dart.indexOf('}', dart.indexOf('int get level {')));
    expect(body, isNot(contains('throwIfOutParamError')));
    // Defaults mixin uses getter form too.
    expect(dart, contains("int get level => throw UnimplementedError('Demo.level')"));
  });

  test('Swift: properties with accessor effects, calls without ()', () {
    final swift = SwiftGenerator.generate(platform);
    expect(swift, contains('var level: Int64 { get }'));
    expect(swift, contains('var label: String { get async throws }'));
    expect(swift, contains('var remote: Int64 { get async throws }'));
    for (final g in getters) {
      expect(swift, isNot(contains('func $g(')), reason: g);
      expect(swift, isNot(contains('impl.$g()')), reason: g);
      expect(swift, isNot(contains('impl?.$g()')), reason: g);
    }
    expect(swift, contains('impl.label'));
  });

  test('Kotlin: vals, calls without ()', () {
    final kt = KotlinGenerator.generate(platform);
    expect(kt, contains('val level: Long'));
    expect(kt, contains('val label: String'));
    for (final g in getters) {
      expect(kt, isNot(contains('fun $g(')), reason: g);
      expect(kt, isNot(contains('impl.$g()')), reason: g);
    }
    expect(kt, contains('impl.level'));
  });

  test('C++: get_x() members, const when synchronous, calls renamed', () {
    final header = CppInterfaceGenerator.generate(cpp);
    expect(header, contains('virtual int64_t get_level() const = 0;'));
    expect(header, contains('virtual void get_remote(NitroError* _nitro_err, int64_t dartPort) = 0;'));
    expect(header, isNot(contains(' level(')));
    final bridge = CppBridgeGenerator.generate(cpp);
    for (final g in getters) {
      expect(bridge, isNot(contains('_impl->$g(')), reason: g);
    }
    expect(bridge, contains('_impl->get_level('));
    expect(CppImplGenerator.generate(cpp), contains('get_level() const override'));
    expect(CppMockGenerator.generateMockHeader(cpp), contains('MOCK_METHOD(int64_t, get_level, (), (const, override));'));
  });

  test('web: getter signatures', () {
    final web = _flat(WebBridgeGenerator.generate(SpecFromSource.parse(_src('ios: NativeImpl.cpp, android: NativeImpl.cpp, web: WebNativeImpl.wasm'), sourceUri: 'package:demo/src/demo.native.dart')));
    expect(web, contains('int get level {'));
    expect(web, contains('Future<String> get label'));
    expect(web, isNot(contains('label()')));
  });
}

void readWriteProperties() {
  const src = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Demo extends HybridObject {
  @nitroFast
  int get volume;
  @nitroFast
  set volume(int value);

  @mainThread
  double get brightness;
  @mainThread
  set brightness(double value);

  String? get label;
  @nitroFast
  set label(String? value);
}
''';
  final spec = SpecFromSource.parse(src, sourceUri: 'package:demo/src/demo.native.dart');

  test('read/write annotated properties stay properties with per-accessor flags', () {
    expect(spec.functions.where((f) => f.isGetter), isEmpty);
    final byName = {for (final p in spec.properties) p.dartName: p};
    expect([byName['volume']!.getFast, byName['volume']!.setFast], [true, true]);
    expect([byName['brightness']!.getMainThread, byName['brightness']!.setMainThread], [true, true]);
    expect([byName['label']!.getFast, byName['label']!.setFast], [false, true]);
  });

  test('Dart: @nitroFast accessors are bare calls; unannotated keep callSync', () {
    final dart = _flat(DartFfiGenerator.generate(spec));
    String body(String sig) => dart.substring(dart.indexOf(sig), dart.indexOf(' } ', dart.indexOf(sig)) + 2);
    expect(body('int get volume {'), isNot(contains('callSync')));
    expect(body('set volume(int value) {'), isNot(contains('callSync')));
    expect(body('set volume(int value) {'), isNot(contains('throwIfOutParamError')));
    expect(body('set label(String? value) {'), contains('withArena'));
    expect(body('set label(String? value) {'), isNot(contains('callSync')));
    expect(dart, contains("methodName: 'get label'"), reason: 'unannotated getter keeps callSync');
  });

  test('Kotlin: @mainThread accessors hop to Dispatchers.Main around the impl access', () {
    final kt = KotlinGenerator.generate(spec);
    expect(kt, contains('var brightness: Double'));
    expect(kt, contains('val _mainValue = kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.Main.immediate) { impl.brightness }'));
    expect(kt, contains('return _mainValue'));
    expect(kt, contains('kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.Main.immediate) { impl.brightness = value }'));
    expect(kt, contains('return impl.volume'), reason: 'non-main accessors unchanged');
  });

  test('Swift: @mainThread accessor bodies run in _nitroMainSync; helper emitted', () {
    final swift = SwiftGenerator.generate(spec);
    expect(swift, contains('var brightness: Double { get set }'));
    expect(swift, contains('fileprivate func _nitroMainSync<T>'));
    final get = swift.indexOf('_call_get_brightness() -> Double {');
    expect(swift.substring(get, swift.indexOf('\n}\n', get)), contains('return _nitroMainSync { () -> Double in'));
    final set = swift.indexOf('_call_set_brightness(_ value: Double) {');
    expect(swift.substring(set, swift.indexOf('\n}\n', set)), contains('_nitroMainSync { () -> Void in'));
    final vol = swift.indexOf('_call_get_volume() -> Int64 {');
    expect(swift.substring(vol, swift.indexOf('\n}\n', vol)), isNot(contains('_nitroMainSync')));
  });
}
