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
/// For these types the generator skips the *RecordExt extension and calls
/// the class methods directly (e.g. NitroNullableInt.fromNative).
const _nitroLibraryRecordTypes = {
  'NitroNullableInt',
  'NitroNullableDouble',
  'NitroNullableBool',
};


class DartFfiGenerator {
  static String generate(BridgeSpec spec) {
    _assertSupportedFunctionTypes(spec);

    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
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
    return writer.toString();
  }
}
