import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';
import '../../struct_generator.dart';
import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl;
import 'emitters/swift_function_emitter.dart';
import 'emitters/swift_property_emitter.dart';
import 'emitters/swift_stream_emitter.dart';
import 'emitters/swift_type_mapper.dart';
import 'emitters/swift_variant_emitter.dart';

part 'emitters/swift_protocol_registry_emitter.dart';
part 'emitters/swift_map_typed_data_emitter.dart';
part 'emitters/swift_cpp_module_generator.dart';

class SwiftGenerator {
  static String generate(BridgeSpec spec) {
    if (spec.isTypeOnly) return _generateTypeOnly(spec);
    if (spec.iosImpl == null) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri)}\n'
          '// iOS not targeted — no Swift bridge generated.\n';
    }

    // For NativeImpl.cpp (CppImpl) modules, the C++ .mm shim calls the
    // native C functions directly (e.g. benchmark_cpp_add). It does NOT
    // use @_cdecl Swift stubs. Emitting @_cdecl stubs here would cause
    // duplicate-symbol linker errors when both a Swift and a C++ module
    // are compiled into the same target — they share the same symbol names.
    //
    // Shared types (structs, NitroRecordWriter, NitroRecordReader) are
    // declared by the Swift module's .bridge.g.swift, which is compiled
    // in the same module. Do NOT redeclare them here.
    final isCppModule = spec.iosImpl is CppImpl;
    if (isCppModule) {
      return _generateCppModuleBridge(spec);
    }

    final writer = CodeWriter();
    final mapper = SwiftTypeMapper(spec);
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('import Foundation');
    writer.line('import Combine');
    // @nitroNativeAsync stubs use Dart_CObject / Dart_PostCObject_DL, which are
    // C types from dart_api.h — exposed by the sibling SPM C++ target.
    final hasNativeAsync = spec.functions.any((f) => f.isNativeAsync);
    if (hasNativeAsync) {
      writer.line('import ${spec.dartClassName}Cpp');
    }
    writer.blankLine();

    final swiftEnums = EnumGenerator.generateSwift(spec);
    if (swiftEnums.isNotEmpty) writer.raw(swiftEnums);

    final swiftStructs = StructGenerator.generateSwift(spec);
    if (swiftStructs.isNotEmpty) writer.raw(swiftStructs);

    final swiftRecords = RecordGenerator.generateSwift(spec);
    if (swiftRecords.isNotEmpty) writer.raw(swiftRecords);


    _emitSwiftMapHelpers(writer, spec);
    _emitSwiftTypedDataHelpers(writer, spec);
    _emitSwiftProtocol(writer, spec, mapper);
    _emitSwiftRegistry(writer, spec);
    // ── @_cdecl C bridge stubs ─────────────────────────────────────────────
    // These are exported as plain C symbols and called by the generated .cpp
    // shim via `extern "C"` declarations. @objc is NOT used because Swift
    // structs and Swift-only protocols cannot cross the ObjC boundary.
    writer.line(
      '// MARK: - C bridge stubs — exported as C symbols called by the generated .cpp shim',
    );
    writer.blankLine();

    // Delegate to per-concern emitters (extracted from the original monolith).
    for (final func in spec.functions) {
      SwiftFunctionEmitter.emit(writer, func, spec, mapper);
    }
    for (final prop in spec.properties) {
      SwiftPropertyEmitter.emit(writer, prop, spec, mapper);
    }
    for (final stream in spec.streams) {
      SwiftStreamEmitter.emit(writer, stream, spec, mapper);
    }

    return writer.toString();
  }

  /// Emits only enum/struct/record declarations — no protocol, registry, or @_cdecl stubs.
  static String _generateTypeOnly(BridgeSpec spec) {
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      const CodeLine('import Foundation'),
      const BlankLine(),
    ];

    final swiftEnums = EnumGenerator.generateSwift(spec);
    if (swiftEnums.isNotEmpty) nodes.add(CodeSnippet(swiftEnums));

    final swiftStructs = StructGenerator.generateSwift(spec);
    if (swiftStructs.isNotEmpty) nodes.add(CodeSnippet(swiftStructs));

    final swiftRecords = RecordGenerator.generateSwift(spec);
    if (swiftRecords.isNotEmpty) nodes.add(CodeSnippet(swiftRecords));

    if (spec.localVariants.isNotEmpty) {
      final mapper = SwiftTypeMapper(spec);
      final varWriter = CodeWriter();
      for (final variant in spec.localVariants) {
        SwiftVariantEmitter.emit(varWriter, variant, mapper);
      }
      nodes.add(CodeSnippet(varWriter.toString()));
    }

    return CodeFile(nodes).render();
  }

}
