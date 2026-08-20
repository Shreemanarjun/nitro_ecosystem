import '../bridge_spec.dart';
import 'code_writer.dart';

part 'record/dart_record_generator.dart';
part 'record/cpp_record_generator.dart';
part 'record/kotlin_record_generator.dart';
part 'record/swift_record_generator.dart';

/// Record types whose Dart codec lives in package:nitro — skip RecordExt for these.
const _nitroLibraryRecordTypes = {
  'NitroNullableInt',
  'NitroNullableDouble',
  'NitroNullableBool',
  // NitroOpt* packed structs (Dart FFI Struct subclasses from package:nitro)
  'NitroOptInt64',
  'NitroOptFloat64',
  'NitroOptBool',
};

/// Which members of the generated Dart codecs to emit — the 0.7.0 web split.
///
/// [all] is the historical single-part layout (non-web specs, byte-identical).
/// For web-targeting specs the part keeps [pure] (reader/writer members shared
/// by the FFI impl and the web bridge) and the standalone ffi library gets
/// [ffi] (Pointer-based members, emitted into `*RecordFfiExt` extensions so
/// the names never collide with the part's).
enum DartCodecSlice { all, pure, ffi }

/// Generates binary encode/decode extension methods for @HybridRecord types.
/// Orchestrates language-specific generators in `record/`.
class RecordGenerator {
  static String generateDartExtensions(BridgeSpec spec, {DartCodecSlice slice = DartCodecSlice.all}) => _generateDartRecordExtensions(spec, slice);

  static String generateCpp(BridgeSpec spec) => _generateCppRecords(spec);

  static String generateKotlin(BridgeSpec spec) => _generateKotlinRecords(spec);

  static String generateSwift(BridgeSpec spec, {bool emitBoilerplate = true}) => _generateSwiftRecords(spec, emitBoilerplate: emitBoilerplate);

  /// Returns a byte-size estimate for one serialized [BridgeRecordType] instance.
  /// Used by Kotlin generators to pre-size ByteArrayOutputStream buffers.
  static int recordBytesHint(BridgeRecordType rt) => _recordBytesHint(rt);
}
