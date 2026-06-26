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
};

/// Generates binary encode/decode extension methods for @HybridRecord types.
/// Orchestrates language-specific generators in `record/`.
class RecordGenerator {
  static String generateDartExtensions(BridgeSpec spec) =>
      _generateDartRecordExtensions(spec);

  static String generateCpp(BridgeSpec spec) =>
      _generateCppRecords(spec);

  static String generateKotlin(BridgeSpec spec) =>
      _generateKotlinRecords(spec);

  static String generateSwift(BridgeSpec spec, {bool emitBoilerplate = true}) =>
      _generateSwiftRecords(spec, emitBoilerplate: emitBoilerplate);

  /// Returns a byte-size estimate for one serialized [BridgeRecordType] instance.
  /// Used by Kotlin generators to pre-size ByteArrayOutputStream buffers.
  static int recordBytesHint(BridgeRecordType rt) => _recordBytesHint(rt);
}
