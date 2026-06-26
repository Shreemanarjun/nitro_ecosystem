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

    // Emit @NitroVariant type declarations in the bridge file (same as type-only).
    if (spec.localVariants.isNotEmpty) {
      final varWriter = CodeWriter();
      for (final variant in spec.localVariants) {
        SwiftVariantEmitter.emit(varWriter, variant, mapper);
      }
      writer.raw(varWriter.toString());
    }

    _emitSwiftMapHelpers(writer, spec);
    _emitSwiftTypedDataHelpers(writer, spec);
    // Emit @NitroResult helper functions when any function uses @NitroResult.
    if (spec.functions.any((f) => f.isResult)) {
      _emitSwiftResultHelpers(writer);
    }
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

  /// Emits Swift helper functions for @NitroResult encoding.
  ///
  /// Wire format: [1B tag: 0=ok, 1=err][record-codec payload]
  /// All success payloads are wrapped in a NitroRecordWriter so the
  /// Dart side can uniformly call `RecordReader.fromNative(res + 1)`.
  static void _emitSwiftResultHelpers(CodeWriter writer) {
    writer.line('// MARK: - @NitroResult encoding helpers');
    writer.blankLine();
    writer.line('private func _nitroWriteResultTag(_ tag: UInt8, _ payload: UnsafeMutablePointer<UInt8>?, _ payloadLen: Int) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let total = 1 + payloadLen');
    writer.line('    guard let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: total) as UnsafeMutablePointer<UInt8>? else { return nil }');
    writer.line('    buf[0] = tag');
    writer.line('    if payloadLen > 0, let payload = payload {');
    writer.line('        buf.advanced(by: 1).initialize(from: payload, count: payloadLen)');
    writer.line('    }');
    writer.line('    return buf');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroEncodeResultInt64(_ v: Int64) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let w = NitroRecordWriter()');
    writer.line('    w.writeInt(v)');
    writer.line('    guard let payload = w.toNative() else { return _nitroWriteResultTag(0, nil, 0) }');
    writer.line('    let payloadLen = 4 + Int(payload.pointee)  // 4B prefix + payload bytes');
    writer.line('    return _nitroWriteResultTag(0, payload, payloadLen)');
    writer.line('}');
    writer.blankLine();
    writer.line('// Overload for plain Int (non-nullable) convenience');
    writer.line('private func _nitroEncodeResultInt64(_ v: Int) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    return _nitroEncodeResultInt64(Int64(v))');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroEncodeResultFloat64(_ v: Double) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let w = NitroRecordWriter()');
    writer.line('    w.writeDouble(v)');
    writer.line('    guard let payload = w.toNative() else { return _nitroWriteResultTag(0, nil, 0) }');
    writer.line('    let payloadLen = 4 + Int(payload.pointee)');
    writer.line('    return _nitroWriteResultTag(0, payload, payloadLen)');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroEncodeResultBool(_ v: Bool) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let w = NitroRecordWriter()');
    writer.line('    w.writeBool(v)');
    writer.line('    guard let payload = w.toNative() else { return _nitroWriteResultTag(0, nil, 0) }');
    writer.line('    let payloadLen = 4 + Int(payload.pointee)');
    writer.line('    return _nitroWriteResultTag(0, payload, payloadLen)');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroEncodeResultString(_ v: String) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let w = NitroRecordWriter()');
    writer.line('    w.writeString(v)');
    writer.line('    guard let payload = w.toNative() else { return _nitroWriteResultTag(0, nil, 0) }');
    writer.line('    let payloadLen = 4 + Int(payload.pointee)');
    writer.line('    return _nitroWriteResultTag(0, payload, payloadLen)');
    writer.line('}');
    writer.blankLine();
    writer.line('// For @HybridRecord / @NitroVariant result types — encode via toNative()/writeFields');
    writer.line('private func _nitroEncodeResultRecord<T: NitroEncodable>(_ v: T) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    guard let payload = v.toNative() else { return _nitroWriteResultTag(0, nil, 0) }');
    writer.line('    let payloadLen = 4 + Int(payload.pointee)');
    writer.line('    return _nitroWriteResultTag(0, payload, payloadLen)');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroEncodeResultError(_ error: Error) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let msg = error.localizedDescription');
    writer.line('    let w = NitroRecordWriter()');
    writer.line('    w.writeString(msg)');
    writer.line('    guard let payload = w.toNative() else { return _nitroWriteResultTag(1, nil, 0) }');
    writer.line('    let payloadLen = 4 + Int(payload.pointee)');
    writer.line('    return _nitroWriteResultTag(1, payload, payloadLen)');
    writer.line('}');
    writer.blankLine();
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
