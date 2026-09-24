// Shared types across modules (type-only `.native.dart` files): the web-split
// layout, imported struct streams and C++/Swift visibility. Verified end to end
// by nitro_type_coverage §87 (two modules, one shared type file, every platform).
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';

const _sharedUri = 'package:demo/src/shared.native.dart';

BridgeStruct _vec({bool imported = false}) => BridgeStruct(
  name: 'Vec',
  packed: false,
  isImported: imported,
  fields: [BridgeField(name: 'x', type: BridgeType(name: 'double')), BridgeField(name: 'y', type: BridgeType(name: 'double'))],
);

BridgeSpec _typeOnly({required bool forWeb}) => BridgeSpec(
  dartClassName: '',
  lib: 'shared',
  namespace: '',
  sourceUri: _sharedUri,
  structs: [_vec()],
  isTypeOnly: true,
)..typeOnlyForWeb = forWeb;

BridgeSpec _webModule() => BridgeSpec(
  dartClassName: 'Second',
  lib: 'second',
  namespace: 'second',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  webImpl: NativeImpl.wasm,
  sourceUri: 'package:demo/src/second.native.dart',
  structs: [_vec(imported: true)],
  importedSpecs: [(uri: _sharedUri, lib: 'shared', isTypeOnly: true, targetsWeb: false)],
  importedTypeLibs: {'Vec': 'shared'},
  functions: [BridgeFunction(dartName: 'addVec', cSymbol: 'second_add_vec', isAsync: false, returnType: BridgeType(name: 'Vec'), params: [BridgeParam(name: 'a', type: BridgeType(name: 'Vec'))])],
  streams: [
    BridgeStream(dartName: 'vecs', registerSymbol: 'second_register_vecs_stream', releaseSymbol: 'second_release_vecs_stream', itemType: BridgeType(name: 'Vec'), backpressure: Backpressure.dropLatest),
  ],
);

void main() {
  test('a type-only file imported by a web module is split: dart:ffi leaves the part', () {
    final split = _typeOnly(forWeb: true);
    expect(split.usesWebSplitDart, isTrue);
    expect(DartFfiGenerator.generate(split), isNot(contains('extends Struct')));
    expect(DartFfiGenerator.generateFfiLibrary(split), contains('final class VecFfi extends Struct'));
  });

  test('a type-only file with no web importer keeps the single-part layout', () {
    final plain = _typeOnly(forWeb: false);
    expect(plain.usesWebSplitDart, isFalse);
    expect(DartFfiGenerator.generate(plain), contains('extends Struct'));
  });

  test('split importers import the shared spec (and its dart:ffi library natively)', () {
    final spec = _webModule();
    final ffi = DartFfiGenerator.generateFfiLibrary(spec);
    expect(ffi, contains("import '$_sharedUri';"));
    expect(ffi, contains("import 'package:demo/src/generated/native/shared.ffi.g.dart';"));
    final web = WebBridgeGenerator.generate(spec);
    expect(web, contains("import '$_sharedUri';"));
    expect(web, isNot(contains('shared.ffi.g.dart')), reason: 'web never compiles dart:ffi');
  });

  test('imported structs: no private proxy init; stream items decode eagerly with this module\'s release', () {
    final ffi = DartFfiGenerator.generateFfiLibrary(_webModule());
    expect(ffi, isNot(contains('VecProxy._init')));
    expect(ffi, contains('openStream<Vec>'));
    expect(ffi, contains('p.ref.toDart()'));
    expect(ffi, contains("'second_release_Vec'"));
  });

  test('Swift C-ABI shadow is internal so other modules\' bridge files can marshal it', () {
    final swift = StructGenerator.generateSwift(_typeOnly(forWeb: false));
    expect(swift, contains('\nstruct _VecC {'));
    expect(swift, isNot(contains('fileprivate struct _VecC')));
  });

  test("Kotlin module files import the shared types' package", () {
    expect(KotlinGenerator.generate(_webModule()), contains('import nitro.shared_module.*'));
  });

  test("JNI names an imported struct by its owner's Kotlin package", () {
    final cpp = CppBridgeGenerator.generate(_webModule());
    expect(cpp, contains('Lnitro/shared_module/Vec;'));
    expect(cpp, contains('FindClass("nitro/shared_module/Vec")'));
    expect(cpp, isNot(contains('nitro/second_module/Vec')));
  });
}
