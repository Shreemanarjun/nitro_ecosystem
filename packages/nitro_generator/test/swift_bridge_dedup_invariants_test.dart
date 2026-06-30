// Tests that verify the structural invariants of generated Swift bridge files
// that the nitrogen CLI relies on when stripping duplicate shared-type
// declarations from multi-spec plugins.
//
// If these tests fail, the `stripSharedSwiftPreamble` function in
// nitrogen_cli/lib/commands/generate_command.dart must be updated to match
// the structural change.
import 'package:nitro_annotations/nitro_annotations.dart' show NativeImpl;
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

// ── Spec helpers ──────────────────────────────────────────────────────────────

/// Minimal spec with a scalar return — generates NitroEncodable but not record types.
BridgeSpec _scalarSpec({String name = 'Camera', String lib = 'camera'}) => BridgeSpec(
      dartClassName: name,
      lib: lib,
      namespace: lib,
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: '$lib.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'getValue',
          cSymbol: '${lib}_get_value',
          isAsync: false,
          returnType: BridgeType(name: 'double'),
          params: [],
        ),
      ],
    );

/// Spec with a record return — generates NitroNullableInt, NitroRecordWriter, etc.
BridgeSpec _recordSpec({String name = 'Data', String lib = 'data'}) => BridgeSpec(
      dartClassName: name,
      lib: lib,
      namespace: lib,
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: '$lib.native.dart',
      recordTypes: [
        BridgeRecordType(
          name: 'Reading',
          fields: [
            BridgeRecordField(
              name: 'v',
              dartType: 'double',
              kind: RecordFieldKind.primitive,
            ),
          ],
        ),
      ],
      functions: [
        BridgeFunction(
          dartName: 'read',
          cSymbol: '${lib}_read',
          isAsync: false,
          returnType: BridgeType(name: 'Reading', isRecord: true),
          params: [],
        ),
      ],
    );

void main() {
  group('SwiftGenerator — structural invariants for multi-spec deduplication', () {
    // ── NitroEncodable is always present ────────────────────────────────────

    test('NitroEncodable is always emitted in the bridge preamble', () {
      final out = SwiftGenerator.generate(_scalarSpec());

      expect(out, contains('public protocol NitroEncodable'));
    });

    test('record-using spec emits NitroRecordWriter and NitroRecordReader', () {
      final out = SwiftGenerator.generate(_recordSpec());

      // These are always emitted when any @HybridRecord is used.
      expect(out, contains('public class NitroRecordWriter'));
      expect(out, contains('public class NitroRecordReader'));
    });

    test('record-using spec emits user-defined record struct before NitroRecordWriter', () {
      final out = SwiftGenerator.generate(_recordSpec());

      final recordIdx = out.indexOf('public struct Reading: NitroEncodable');
      final writerIdx = out.indexOf('public class NitroRecordWriter');

      expect(recordIdx, greaterThan(-1));
      expect(writerIdx, greaterThan(-1));
      // Record type is defined before the writer/reader utilities.
      expect(recordIdx, lessThan(writerIdx));
    });

    // ── NitroEncodable comes before the Hybrid protocol ────────────────────

    test('NitroEncodable appears before the spec-specific Hybrid protocol', () {
      final out = SwiftGenerator.generate(_scalarSpec());

      final encodableIdx = out.indexOf('public protocol NitroEncodable');
      final hybridIdx = out.indexOf('public protocol HybridCameraProtocol');

      expect(encodableIdx, greaterThan(-1), reason: 'NitroEncodable must be present');
      expect(hybridIdx, greaterThan(-1), reason: 'HybridCameraProtocol must be present');
      expect(encodableIdx, lessThan(hybridIdx),
          reason: 'Shared preamble must come before spec-specific content');
    });

    // ── /** doc-comment precedes the Hybrid protocol ───────────────────────
    // `stripSharedSwiftPreamble` resumes at the FIRST `/**` after the shared
    // block. The generator MUST emit a `/**` doc-comment immediately before
    // the Hybrid protocol.

    test('Hybrid protocol is preceded by a /** doc-comment', () {
      final out = SwiftGenerator.generate(_scalarSpec());
      final lines = out.split('\n');

      final hybridIdx = lines.indexWhere((l) => l.startsWith('public protocol HybridCameraProtocol'));
      expect(hybridIdx, greaterThan(0), reason: 'HybridCameraProtocol must exist');

      final docCommentIdx = lines.lastIndexWhere(
        (l) => l.startsWith('/**'),
        hybridIdx,
      );
      expect(docCommentIdx, greaterThan(-1),
          reason: 'A /** doc-comment must appear before the Hybrid protocol');
      expect(docCommentIdx, lessThan(hybridIdx),
          reason: '/** must precede the protocol declaration');
    });

    test('/** doc-comment is positioned between NitroEncodable and the Hybrid protocol', () {
      final out = SwiftGenerator.generate(_scalarSpec());

      final encodableIdx = out.indexOf('public protocol NitroEncodable');
      final hybridIdx = out.indexOf('public protocol HybridCameraProtocol');
      final docCommentIdx = out.lastIndexOf('/**', hybridIdx);

      expect(encodableIdx, lessThan(docCommentIdx),
          reason: 'Shared block ends before the /** marker');
      expect(docCommentIdx, lessThan(hybridIdx),
          reason: '/** marker is between shared block and Hybrid protocol');
    });

    // ── NitroEncodable line starts at column 0 ────────────────────────────
    // `stripSharedSwiftPreamble` uses `line.startsWith("public protocol NitroEncodable")`.
    // If the declaration ever gets indented, the stripping will break.

    test('NitroEncodable declaration is unindented (starts at column 0)', () {
      final out = SwiftGenerator.generate(_scalarSpec());
      final lines = out.split('\n');

      final encodableLine = lines.firstWhere(
        (l) => l.contains('public protocol NitroEncodable'),
        orElse: () => '',
      );
      expect(encodableLine, startsWith('public protocol NitroEncodable'),
          reason: 'Must not be indented — stripSharedSwiftPreamble matches line.startsWith(...)');
    });

    // ── Private helpers come BEFORE the shared block ───────────────────────

    test('file-private string helpers appear before NitroEncodable', () {
      final out = SwiftGenerator.generate(_scalarSpec());

      final helperIdx = out.indexOf('private func _nitroStringFromCString');
      final encodableIdx = out.indexOf('public protocol NitroEncodable');

      expect(helperIdx, greaterThan(-1), reason: 'String helpers must be present');
      expect(helperIdx, lessThan(encodableIdx),
          reason: 'Private helpers must precede the shared type declarations');
    });

    // ── Spec-specific content is present ───────────────────────────────────

    test('spec-specific Hybrid protocol is present', () {
      final out = SwiftGenerator.generate(_scalarSpec());
      expect(out, contains('public protocol HybridCameraProtocol'));
    });

    test('spec-specific Registry class is present', () {
      final out = SwiftGenerator.generate(_scalarSpec());
      expect(out, contains('public class CameraRegistry'));
    });

    test('@_cdecl bridge stubs are emitted after the protocol', () {
      final out = SwiftGenerator.generate(_scalarSpec());
      // The cSymbol is used in the @_cdecl stub name with a leading underscore prefix.
      expect(out, contains('_camera_call_getValue'));
    });

    // ── Deduplication correctness across specs ────────────────────────────

    test('NitroEncodable appears exactly once after stripping 2nd file', () {
      final spec1 = SwiftGenerator.generate(_scalarSpec(name: 'NitroView', lib: 'nitro_view'));
      final spec2 = SwiftGenerator.generate(_scalarSpec(name: 'NitroUI', lib: 'nitro_ui'));

      final stripped2 = _stripPreamble(spec2);

      final countIn1 = 'public protocol NitroEncodable'.allMatches(spec1).length;
      final countIn2 = 'public protocol NitroEncodable'.allMatches(stripped2).length;

      expect(countIn1, equals(1), reason: 'First file: one declaration');
      expect(countIn2, equals(0), reason: 'Second file (stripped): zero declarations');
    });

    test('three-spec plugin: NitroEncodable appears exactly once across all files after stripping', () {
      final files = [
        SwiftGenerator.generate(_scalarSpec(name: 'NitroView', lib: 'nitro_view')),
        SwiftGenerator.generate(_scalarSpec(name: 'NitroUI', lib: 'nitro_ui')),
        SwiftGenerator.generate(_scalarSpec(name: 'NitroSystem', lib: 'nitro_system')),
      ]..sort(); // alphabetical, same as CLI

      var encodableCount = 0;
      for (var i = 0; i < files.length; i++) {
        final content = i == 0 ? files[i] : _stripPreamble(files[i]);
        encodableCount += 'public protocol NitroEncodable'.allMatches(content).length;
      }

      expect(encodableCount, equals(1),
          reason: 'After stripping 2nd and 3rd files, NitroEncodable must appear exactly once');
    });

    test('stripped file still has its Hybrid protocol', () {
      final spec2 = SwiftGenerator.generate(_scalarSpec(name: 'NitroUI', lib: 'nitro_ui'));
      final stripped = _stripPreamble(spec2);

      expect(stripped, isNot(contains('public protocol NitroEncodable')),
          reason: 'Shared type must be gone');
      expect(stripped, contains('public protocol HybridNitroUIProtocol'),
          reason: 'Spec-specific protocol must survive stripping');
      expect(stripped, contains('public class NitroUIRegistry'),
          reason: 'Registry must survive stripping');
    });

    test('stripping is idempotent when applied to already-stripped content', () {
      final spec = SwiftGenerator.generate(_scalarSpec());
      final once = _stripPreamble(spec);
      final twice = _stripPreamble(once);

      expect(once, equals(twice));
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Mirrors `stripSharedSwiftPreamble` from nitrogen_cli — keeping this a
/// local copy so the generator tests remain independent of the CLI package.
String _stripPreamble(String content) {
  final lines = content.split('\n');
  final result = <String>[];
  var inSharedBlock = false;
  for (final line in lines) {
    if (!inSharedBlock && line.startsWith('public protocol NitroEncodable')) {
      inSharedBlock = true;
      continue;
    }
    if (inSharedBlock) {
      if (line.startsWith('/**')) {
        inSharedBlock = false;
        result.add(line);
      }
      continue;
    }
    result.add(line);
  }
  return result.join('\n');
}
