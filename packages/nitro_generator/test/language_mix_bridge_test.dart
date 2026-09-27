// Bridge fixes found by building test_projects/nitro_combo: modules that are
// C++ on some platforms and Swift/Kotlin on others, several in one plugin.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

String _src(String impls) => '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
@NitroModule($impls)
abstract class Mix extends HybridObject {
  int add(int a, int b);
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<int> get ticks;
}
''';

void main() {
  group('shared-type shapes', sharedTypeShapes);
  group('edge cases', edgeCases);
  final iosCppMacSwift = SpecFromSource.parse(_src('ios: NativeImpl.cpp, android: NativeImpl.kotlin, macos: NativeImpl.swift'), sourceUri: 'package:demo/src/mix.native.dart');
  final iosSwiftAndroidCpp = SpecFromSource.parse(_src('ios: NativeImpl.swift, android: NativeImpl.cpp, macos: NativeImpl.cpp'), sourceUri: 'package:demo/src/mix.native.dart');

  test('Swift bridge: @_cdecl stubs only on the Apple platform that is Swift; declarations on both', () {
    final a = SwiftGenerator.generate(iosCppMacSwift);
    expect(a, contains('#if os(macOS)\n@_cdecl("_mix_call_add")'));
    expect(RegExp(r'^public protocol HybridMixProtocol', multiLine: true).allMatches(a), hasLength(1), reason: 'protocol unguarded, once');
    final b = SwiftGenerator.generate(iosSwiftAndroidCpp);
    expect(b, contains('#if os(iOS)\n@_cdecl("_mix_call_add")'));
  });

  test('android: NativeImpl.cpp in a mixed spec uses direct C++, not JNI', () {
    final cpp = CppBridgeGenerator.generate(iosSwiftAndroidCpp);
    final android = cpp.substring(cpp.indexOf('#ifdef __ANDROID__\n#include'), cpp.indexOf('#elif __APPLE__'));
    expect(android, contains('mix_register_impl('));
    expect(android, isNot(contains('JNI_OnLoad')));
  });

  test('stream emit helpers are file-local (several modules may share a stream name)', () {
    final cpp = CppBridgeGenerator.generate(iosCppMacSwift);
    expect(cpp, contains('static bool _emit_ticks_to_dart('));
    expect(RegExp(r'^bool _emit_ticks_to_dart\(', multiLine: true).hasMatch(cpp), isFalse);
  });
}

String _src2(String impls, {String body = ''}) => '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
$body
@NitroModule($impls)
abstract class Mix extends HybridObject {
  int add(int a, int b);
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<int> get ticks;
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<double> get levels;
}
''';

BridgeSpec _parse(String impls, {String body = ''}) => SpecFromSource.parse(_src2(impls, body: body), sourceUri: 'package:demo/src/mix.native.dart');

void edgeCases() {
  test('Apple platforms agree (both Swift / both C++): no #if os split', () {
    expect(SwiftGenerator.generate(_parse('ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift')), isNot(contains('#if os(')));
    expect(SwiftGenerator.generate(_parse('ios: NativeImpl.cpp, android: NativeImpl.kotlin, macos: NativeImpl.cpp')), isNot(contains('#if os(')));
  });

  test('macOS not targeted follows iOS: iOS C++ gets no Swift @_cdecl stubs, iOS Swift gets them unguarded', () {
    final cppIos = SwiftGenerator.generate(_parse('ios: NativeImpl.cpp, android: NativeImpl.kotlin'));
    expect(cppIos, isNot(contains('#if os(')));
    expect(cppIos, isNot(contains('@_cdecl("_mix_call_add")')));
    final swiftIos = SwiftGenerator.generate(_parse('ios: NativeImpl.swift, android: NativeImpl.cpp'));
    expect(swiftIos, isNot(contains('#if os(')));
    expect(swiftIos, contains('@_cdecl("_mix_call_add")'));
  });

  test('android C++ with iOS Swift only (no macOS): Android direct C++, Apple Swift shim', () {
    final cpp = CppBridgeGenerator.generate(_parse('ios: NativeImpl.swift, android: NativeImpl.cpp'));
    final split = cpp.indexOf('#elif __APPLE__');
    expect(split, greaterThan(0));
    expect(cpp.substring(0, split), contains('mix_register_impl('));
    expect(cpp, isNot(contains('JNI_OnLoad')));
  });

  test('android C++ in a mixed spec never references the JNI zero-copy pin (Kotlin control does)', () {
    // The source parser ignores @zeroCopy fields: build the spec directly.
    BridgeSpec spec(NativeImpl android) => BridgeSpec(
      dartClassName: 'Mix',
      lib: 'mix',
      namespace: 'mix',
      iosImpl: NativeImpl.swift,
      androidImpl: android,
      sourceUri: 'package:demo/src/mix.native.dart',
      structs: [
        BridgeStruct(name: 'Frame', packed: false, fields: [
          BridgeField(name: 'data', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
          BridgeField(name: 'dataLength', type: BridgeType(name: 'int')),
        ]),
      ],
      streams: [
        BridgeStream(dartName: 'frames', registerSymbol: 'mix_register_frames_stream', releaseSymbol: 'mix_release_frames_stream', itemType: BridgeType(name: 'Frame'), backpressure: Backpressure.dropLatest),
      ],
    );
    expect(CppBridgeGenerator.generate(spec(NativeImpl.kotlin)), contains('mix_zero_copy_release'), reason: 'control');
    expect(CppBridgeGenerator.generate(spec(NativeImpl.cpp)), isNot(contains('zero_copy_release')));
  });

  test('several streams in one module: every emit helper is static, one definition each', () {
    final cpp = CppBridgeGenerator.generate(_parse('ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp'));
    for (final s in ['ticks', 'levels']) {
      expect(RegExp('^static bool _emit_${s}_to_dart\\(', multiLine: true).allMatches(cpp), hasLength(1), reason: s);
      expect(RegExp('^bool _emit_${s}_to_dart\\(', multiLine: true).hasMatch(cpp), isFalse, reason: s);
    }
  });
}

void sharedTypeShapes() {
  test('imported variant: its C++ structs + codecs reach the module header', () {
    final spec = BridgeSpec(
      dartClassName: 'Mix', lib: 'mix', namespace: 'mix', iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp,
      sourceUri: 'package:demo/src/mix.native.dart',
      variants: [
        BridgeVariant(name: 'Shape', isImported: true, cases: [
          BridgeVariantCase(name: 'Circle', label: 'circle', fields: [BridgeRecordField(name: 'r', dartType: 'double', kind: RecordFieldKind.primitive)]),
        ]),
      ],
    );
    final h = CppInterfaceGenerator.generate(spec);
    expect(h, contains('struct Circle {'));
    expect(h, contains('nitro_decode_Shape('));
  });

  test('Swift variant whose field is named `w` does not shadow the writer', () {
    final spec = BridgeSpec(
      dartClassName: '', lib: 'shapes', namespace: '', sourceUri: 'package:demo/src/shapes.native.dart', isTypeOnly: true,
      variants: [
        BridgeVariant(name: 'Shape', cases: [
          BridgeVariantCase(name: 'Box', label: 'box', fields: [
            BridgeRecordField(name: 'w', dartType: 'double', kind: RecordFieldKind.primitive),
            BridgeRecordField(name: 'h', dartType: 'double', kind: RecordFieldKind.primitive),
          ]),
        ]),
      ],
    );
    final swift = SwiftGenerator.generate(spec);
    expect(swift, contains('case .box(let w, let h):'));
    expect(swift, contains('_nitroW.writeDouble(w)'));
    expect(swift, isNot(contains('w.writeDouble(w)\n')));
  });

  test("record callback params decode through the record's extension", () {
    final spec = SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
@HybridRecord()
class Tag { final String name; Tag({required this.name}); }
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Mix extends HybridObject {
  void each(void Function(Tag t) cb);
}
''', sourceUri: 'package:demo/src/mix.native.dart');
    final dart = DartFfiGenerator.generate(spec);
    expect(dart, contains('TagRecordExt.fromNative(arg0)'));
    expect(dart, isNot(contains(' Tag.fromNative(')));
  });

  test('record callback params: C definition matches the header declaration (void*)', () {
    final spec = SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
@HybridRecord()
class Tag { final String name; Tag({required this.name}); }
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Mix extends HybridObject {
  void each(void Function(Tag t) cb);
}
''', sourceUri: 'package:demo/src/mix.native.dart');
    final cpp = CppBridgeGenerator.generate(spec);
    expect(RegExp(r'void mix_each\([^)]*void \(\*cb\)\(void\*\)').allMatches(cpp), isNotEmpty);
    expect(cpp, isNot(contains('void (*cb)(const uint8_t*), NitroError*')));
  });

  test('a type-only file emits its struct codec even with no local record; importers never duplicate it', () {
    final vec = BridgeStruct(name: 'Vec', packed: false, fields: [BridgeField(name: 'x', type: BridgeType(name: 'double'))]);
    final owner = BridgeSpec(dartClassName: '', lib: 'shared', namespace: '', sourceUri: 'package:demo/src/shared.native.dart', isTypeOnly: true, structs: [vec]);
    expect(DartFfiGenerator.generate(owner), contains('extension VecRecordExt on Vec'));
    final importer = BridgeSpec(
      dartClassName: '', lib: 'extra', namespace: '', sourceUri: 'package:demo/src/extra.native.dart', isTypeOnly: true,
      structs: [BridgeStruct(name: 'Vec', packed: false, isImported: true, fields: vec.fields)],
      recordTypes: [BridgeRecordType(name: 'Bundle', fields: [BridgeRecordField(name: 'origin', dartType: 'Vec', kind: RecordFieldKind.struct)])],
    );
    final out = DartFfiGenerator.generate(importer);
    expect(out, contains('VecRecordExt.fromReader(r)'));
    expect(out, isNot(contains('extension VecRecordExt')));
  });

  test('Swift map params call the impl with the real label (not a hard-coded `value:`)', () {
    // Built directly: the extractor marks Map<String, Record> as isMap + isRecord.
    final spec = BridgeSpec(
      dartClassName: 'Mix', lib: 'mix', namespace: 'mix', iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
      sourceUri: 'package:demo/src/mix.native.dart',
      recordTypes: [BridgeRecordType(name: 'Tag', fields: [BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive)])],
      functions: [
        BridgeFunction(
          dartName: 'tagMap', cSymbol: 'mix_tag_map', isAsync: false,
          returnType: BridgeType(name: 'Map<String, Tag>', isMap: true, isRecord: true),
          params: [BridgeParam(name: 'm', type: BridgeType(name: 'Map<String, Tag>', isMap: true, isRecord: true))],
        ),
      ],
    );
    final swift = SwiftGenerator.generate(spec);
    expect(swift, contains('impl.tagMap(m: inputMap)'));
    expect(swift, isNot(contains('impl.tagMap(value: inputMap)')));
  });

  test("a type-only file building on another type file imports that file's Kotlin package", () {
    final spec = BridgeSpec(
      dartClassName: '', lib: 'extra', namespace: '', sourceUri: 'package:demo/src/extra.native.dart', isTypeOnly: true,
      recordTypes: [BridgeRecordType(name: 'Bundle', fields: [BridgeRecordField(name: 'k', dartType: 'Kind', kind: RecordFieldKind.enumValue)])],
      enums: [BridgeEnum(name: 'Kind', startValue: 0, values: ['a'], isImported: true)],
      importedSpecs: [(uri: 'package:demo/src/shared.native.dart', lib: 'shared', isTypeOnly: true, targetsWeb: false)],
    );
    expect(KotlinGenerator.generate(spec), contains('import nitro.shared_module.*'));
  });

  test('a type-only file declaring a variant carries its own Kotlin RecordReader/RecordWriter', () {
    final spec = BridgeSpec(
      dartClassName: '', lib: 'shapes', namespace: '', sourceUri: 'package:demo/src/shapes.native.dart', isTypeOnly: true,
      variants: [
        BridgeVariant(name: 'Shape', cases: [
          BridgeVariantCase(name: 'Circle', label: 'circle', fields: [BridgeRecordField(name: 'r', dartType: 'double', kind: RecordFieldKind.primitive)]),
        ]),
      ],
    );
    final kt = KotlinGenerator.generate(spec);
    expect(kt, contains('class RecordReader('));
    expect(kt, contains('class RecordWriter {'));
  });

  test('Kotlin variant field named `w` does not shadow the writer', () {
    final spec = BridgeSpec(
      dartClassName: '', lib: 'shapes', namespace: '', sourceUri: 'package:demo/src/shapes.native.dart', isTypeOnly: true,
      variants: [
        BridgeVariant(name: 'Shape', cases: [
          BridgeVariantCase(name: 'Box', label: 'box', fields: [BridgeRecordField(name: 'w', dartType: 'double', kind: RecordFieldKind.primitive)]),
        ]),
      ],
    );
    final kt = KotlinGenerator.generate(spec);
    expect(kt, contains('_nitroW.writeFloat64(w)'));
    expect(kt, isNot(contains(' w.writeFloat64(w)')));
  });

  test("Kotlin decodes/encodes an imported variant with its owner package's RecordReader/RecordWriter", () {
    final spec = BridgeSpec(
      dartClassName: 'Mix', lib: 'mix', namespace: 'mix', iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
      sourceUri: 'package:demo/src/mix.native.dart',
      importedTypeLibs: {'Shape': 'shapes'},
      variants: [
        BridgeVariant(name: 'Shape', isImported: true, cases: [
          BridgeVariantCase(name: 'Circle', label: 'circle', fields: [BridgeRecordField(name: 'r', dartType: 'double', kind: RecordFieldKind.primitive)]),
        ]),
      ],
      functions: [
        BridgeFunction(dartName: 'grow', cSymbol: 'mix_grow', isAsync: false, returnType: BridgeType(name: 'Shape'), params: [BridgeParam(name: 's', type: BridgeType(name: 'Shape'))]),
      ],
    );
    final kt = KotlinGenerator.generate(spec);
    expect(kt, contains('Shape.fromReader(nitro.shapes_module.RecordReader('));
    expect(kt, contains('val _vw = nitro.shapes_module.RecordWriter()'));
  });

  test('OS-split Swift bridge: shared helpers defined once and unguarded, so every OS has them', () {
    final spec = SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
@HybridRecord()
class Tag { final String name; Tag({required this.name}); }
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp)
abstract class Mix extends HybridObject {
  Tag echo(Tag t);
}
''', sourceUri: 'package:demo/src/mix.native.dart');
    final swift = SwiftGenerator.generate(spec);
    final writer = RegExp(r'^public class NitroRecordWriter\b', multiLine: true).allMatches(swift).toList();
    expect(writer, hasLength(1));
    final before = swift.substring(0, writer.single.start);
    expect('#if os('.allMatches(before).length, '#endif'.allMatches(before).length, reason: 'not inside an OS branch');
  });

  test('web: a @nitroFast method is a bare call with a debug-only error check, like native', () {
    final spec = SpecFromSource.parse('''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'mix.g.dart';
@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, web: WebNativeImpl.wasm)
abstract class Mix extends HybridObject {
  @nitroFast
  int bump(int v);
  int checked(int v);
}
''', sourceUri: 'package:demo/src/mix.native.dart');
    final web = WebBridgeGenerator.generate(spec);
    final fast = web.substring(web.indexOf('int bump(int v) {'), web.indexOf('int checked(int v) {'));
    expect(fast, isNot(contains('callSync')));
    // Debug-only check: the slot is read inside an assert (gone in release).
    expect(fast, contains('assert(() { NitroRuntime.throwIfOutParamError(_err); return true; }());'));
    expect('throwIfOutParamError'.allMatches(fast), hasLength(1), reason: 'no unguarded check');
    final checked = web.substring(web.indexOf('int checked(int v) {'));
    expect(checked, contains('throwIfOutParamError'));
  });
}
