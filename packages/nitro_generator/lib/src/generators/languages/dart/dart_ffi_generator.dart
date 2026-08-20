import '../../../bridge_item_kind.dart';
import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../struct_generator.dart';
import '../../record_generator.dart';
import '../../variant_generator.dart';
import 'dart_ffi_return_helpers.dart';

part 'emitters/dart_impl_class_emitter.dart';
part 'emitters/dart_function_emitter.dart';
part 'emitters/dart_property_emitter.dart';
part 'emitters/dart_stream_emitter.dart';
part 'emitters/dart_map_factory_emitter.dart';
part 'emitters/dart_type_ffi_mapper.dart';
part 'emitters/dart_map_encode_helpers.dart';
part 'emitters/dart_record_ffi_helpers.dart';
part 'emitters/dart_async_helpers.dart';
part 'emitters/dart_callback_helpers.dart';

/// Record types shipped in package:nitro that define their own codec methods.
/// For these types the generator skips the *RecordExt extension.
const _nitroLibraryRecordTypes = {
  'NitroNullableInt',
  'NitroNullableDouble',
  'NitroNullableBool',
  // NitroOpt* are Dart FFI Struct subclasses — no RecordExt needed.
  'NitroOptInt64',
  'NitroOptFloat64',
  'NitroOptBool',
};

/// Extension carrying a record's static `fromNative` — `RecordFfiExt` in the
/// 0.7.0 web-split layout (targetsWeb), the classic `RecordExt` otherwise.
String _recordDecodeExtName(BridgeSpec spec, String name) => spec.targetsWeb ? '${name}RecordFfiExt' : '${name}RecordExt';

/// Extension carrying a variant's static `fromNative` — see [_recordDecodeExtName].
String _variantDecodeExtName(BridgeSpec spec, String name) => spec.targetsWeb ? '${name}VariantFfiExt' : '${name}VariantExt';

class DartFfiGenerator {
  /// Generates and returns the Dart source for a pair of int-key map
  /// encode/decode helpers (Gap #3).
  ///
  /// Exposed publicly for unit testing; normally invoked internally by
  /// [generate] via [_emitMapAndFactory].
  ///
  /// Example:
  /// ```dart
  /// final src = DartFfiGenerator.generateIntKeyMapHelpers('int', 'String', spec);
  /// expect(src, contains('setInt64'));   // 8-byte key for `int`
  /// ```
  static String generateIntKeyMapHelpers(
    String keyType,
    String valueType,
    BridgeSpec spec,
  ) {
    final w = CodeWriter();
    _emitIntKeyMapBinaryHelpers(w, keyType, valueType, spec);
    return w.toString();
  }

  static String generate(BridgeSpec spec) {
    _assertSupportedFunctionTypes(spec);

    // 0.7.0 web split: for web-targeting specs the part keeps only the
    // platform-neutral codec sections (compiled into web builds too); all
    // dart:ffi content moves to the standalone library from
    // [generateFfiLibrary], reached through [generatePlatformShim].
    if (spec.targetsWeb) return _generateWebSplitPart(spec);

    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    // unused_element/unused_field: _nitroFree/_nitroFreePtr are emitted
    // unconditionally but only referenced when the spec has native-owned
    // returns (strings, records, structs, ...) to free.
    writer.line('// ignore_for_file: no_leading_underscores_for_local_identifiers, prefer_typing_uninitialized_variables, non_constant_identifier_names, unused_element, unused_field');
    writer.line("part of '${spec.sourceUri.split('/').last}';");
    writer.blankLine();

    // Enum & struct extensions (class bodies live in .native.dart)
    final enumExt = EnumGenerator.generateDartExtensions(spec);
    if (enumExt.isNotEmpty) writer.raw(enumExt);
    final structExt = StructGenerator.generateDartExtensions(spec);
    if (structExt.isNotEmpty) writer.raw(structExt);

    // Zero-copy native proxies for @HybridStruct (used by streams)
    final proxyExt = StructGenerator.generateDartProxies(spec);
    if (proxyExt.isNotEmpty) writer.raw(proxyExt);

    // @HybridRecord fromJson / toJson extensions
    final recordExt = RecordGenerator.generateDartExtensions(spec);
    if (recordExt.isNotEmpty) writer.raw(recordExt);

    // @NitroVariant binary extensions
    final variantExt = VariantGenerator.generateDartExtensions(spec);
    if (variantExt.isNotEmpty) writer.raw(variantExt);

    // Type-only files have no bridge implementation — only type declarations.
    if (spec.isTypeOnly) return writer.toString();

    _emitImplClassSetup(writer, spec);
    _emitFunctionImpls(writer, spec);
    _emitPropertyImpls(writer, spec);
    _emitStreamImpls(writer, spec);
    _emitMapAndFactory(writer, spec);
    _emitNativeRefExtension(writer, spec);
    return writer.toString();
  }

  /// The spec file's basename without `.native.dart` — the {{file}} stem the
  /// build extensions key outputs on.
  static String _fileStem(BridgeSpec spec) => spec.sourceUri.split('/').last.replaceFirst('.native.dart', '');

  /// The `.g.dart` part for a web-targeting spec: platform-neutral codec
  /// sections only (enum int mapping, record/variant reader-writer codecs).
  /// Everything dart:ffi lives in the `.ffi.g.dart` library instead.
  static String _generateWebSplitPart(BridgeSpec spec) {
    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('// ignore_for_file: no_leading_underscores_for_local_identifiers, prefer_typing_uninitialized_variables, non_constant_identifier_names, unused_element, unused_field');
    writer.line("part of '${spec.sourceUri.split('/').last}';");
    writer.blankLine();
    writer.line('// Web-split layout (this spec targets web): this part holds only the');
    writer.line('// platform-neutral codecs. The dart:ffi implementation lives in');
    writer.line("// generated/native/${_fileStem(spec)}.ffi.g.dart; construct instances via the");
    writer.line("// conditional factory in ${_fileStem(spec)}.platform.g.dart.");
    writer.blankLine();

    final enumExt = EnumGenerator.generateDartExtensions(spec);
    if (enumExt.isNotEmpty) writer.raw(enumExt);
    final recordExt = RecordGenerator.generateDartExtensions(spec, slice: DartCodecSlice.pure);
    if (recordExt.isNotEmpty) writer.raw(recordExt);
    final variantExt = VariantGenerator.generateDartExtensions(spec, slice: DartCodecSlice.pure);
    if (variantExt.isNotEmpty) writer.raw(variantExt);
    return writer.toString();
  }

  /// The standalone dart:ffi implementation library for a web-targeting spec
  /// (`generated/native/<file>.ffi.g.dart`). Never compiled into a web build —
  /// the platform shim conditionally exports the web bridge there instead.
  static String generateFfiLibrary(BridgeSpec spec) {
    if (!spec.targetsWeb) {
      return '// Web not targeted — the dart:ffi implementation lives in the .g.dart part.\n';
    }
    _assertSupportedFunctionTypes(spec);

    final specFile = spec.sourceUri.split('/').last;
    final className = spec.dartClassName;
    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('// ignore_for_file: no_leading_underscores_for_local_identifiers, prefer_typing_uninitialized_variables, non_constant_identifier_names, unused_element, unused_field, unused_import');
    writer.line('/// Native (dart:ffi) implementation of [$className]. Web builds never');
    writer.line('/// compile this library — the platform shim resolves to the web bridge.');
    writer.line('library;');
    writer.blankLine();
    writer.line("import 'package:nitro/nitro.dart';");
    writer.blankLine();
    writer.line("import '../../$specFile';");
    writer.blankLine();

    // FFI struct representations, zero-copy proxies, and the pointer edges of
    // the record/variant codecs (their reader/writer cores live in the part).
    final structExt = StructGenerator.generateDartExtensions(spec);
    if (structExt.isNotEmpty) writer.raw(structExt);
    final proxyExt = StructGenerator.generateDartProxies(spec);
    if (proxyExt.isNotEmpty) writer.raw(proxyExt);
    final recordExt = RecordGenerator.generateDartExtensions(spec, slice: DartCodecSlice.ffi);
    if (recordExt.isNotEmpty) writer.raw(recordExt);
    final variantExt = VariantGenerator.generateDartExtensions(spec, slice: DartCodecSlice.ffi);
    if (variantExt.isNotEmpty) writer.raw(variantExt);

    if (spec.isTypeOnly) return writer.toString();

    _emitImplClassSetup(writer, spec);
    _emitFunctionImpls(writer, spec);
    _emitPropertyImpls(writer, spec);
    _emitStreamImpls(writer, spec);
    _emitMapAndFactory(writer, spec);
    _emitNativeRefExtension(writer, spec);

    // Canonical platform-neutral factory names, re-exported by the shim. The
    // web bridge emits the same two under identical signatures.
    writer.blankLine();
    writer.line('/// Creates the native implementation of [$className]. A distinct [key]');
    writer.line('/// creates an independent native instance; the default key returns the');
    writer.line('/// shared singleton. On web the platform shim resolves this to the WASM');
    writer.line('/// bridge factory instead.');
    writer.line("$className create${className}Instance([String key = 'default']) => _${className}Impl(key);");
    writer.blankLine();
    writer.line('/// No-op on native (the dynamic library loads synchronously). On web this');
    writer.line('/// resolves to the WASM module loader and MUST be awaited before');
    writer.line('/// [create${className}Instance].');
    writer.line('Future<void> ensure${className}Ready({String? jsUrl}) async {}');
    return writer.toString();
  }

  /// The conditional-export platform shim (`<file>.platform.g.dart`): resolves
  /// [generateFfiLibrary]'s factory on native and the web bridge's on web.
  static String generatePlatformShim(BridgeSpec spec) {
    if (!spec.targetsWeb) {
      return '// Web not targeted — no platform shim generated.\n';
    }
    final stem = _fileStem(spec);
    final className = spec.dartClassName;
    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    if (spec.isTypeOnly) {
      writer.line('// Type-only file — no factories to route.');
      return writer.toString();
    }
    writer.line('/// Platform-conditional factory for [$className]:');
    writer.line('///');
    writer.line('/// ```dart');
    writer.line("/// import '$stem.platform.g.dart';");
    writer.line('///');
    writer.line('/// await ensure${className}Ready();               // no-op on native');
    writer.line('/// final api = create${className}Instance();');
    writer.line('/// ```');
    writer.line('library;');
    writer.blankLine();
    writer.line("export 'generated/native/$stem.ffi.g.dart'");
    writer.line("    if (dart.library.js_interop) 'generated/web/$stem.web.bridge.g.dart'");
    writer.line('    show create${className}Instance, ensure${className}Ready;');
    return writer.toString();
  }
}
