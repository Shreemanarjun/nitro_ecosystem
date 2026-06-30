import 'dart:io';

import 'package:nitro_generator/src/spec_extractor.dart';
import 'package:test/test.dart';

String _specExtractorSource() {
  final packageRoot = File('lib/src/spec_extractor.dart');
  final source = packageRoot.existsSync() ? packageRoot.readAsStringSync() : File('packages/nitro_generator/lib/src/spec_extractor.dart').readAsStringSync();
  return source.replaceAll('\r\n', '\n');
}

void main() {
  group('SpecExtractor error reporting', () {
    test('SpecParseException includes message, source, and cause', () {
      final error = SpecParseException(
        'Failed to parse module.',
        sourceUri: 'package:demo/lib/camera.native.dart',
        cause: StateError('bad annotation'),
        stackTrace: StackTrace.empty,
      );

      expect(error.message, equals('Failed to parse module.'));
      expect(error.sourceUri, equals('package:demo/lib/camera.native.dart'));
      expect(error.cause, isA<StateError>());
      expect(error.stackTrace, same(StackTrace.empty));
      expect(error.toString(), contains('SpecParseException: Failed to parse module.'));
      expect(error.toString(), contains('source: package:demo/lib/camera.native.dart'));
      expect(error.toString(), contains('Caused by: Bad state: bad annotation'));
    });

    test('spec_extractor.dart does not silently swallow extractor failures', () {
      final source = _specExtractorSource();
      expect(source, isNot(contains('catch (_)')));
      expect(source, contains('throw SpecParseException('));
    });

    test('module members are classified once before extraction', () {
      final source = _specExtractorSource();
      expect(source, contains('class _ModuleMembers'));
      expect(source, contains('final members = _ModuleMembers.from(element);'));
      expect(
        source,
        contains('static ({List<BridgeProperty> properties, List<BridgeStream> streams}) _extractPropertiesAndStreams(\n    _ModuleMembers members,'),
      );
      expect(
        RegExp(r'_extractPropertiesAndStreams\([^)]*ClassElement element', dotAll: true).hasMatch(source),
        isFalse,
      );
    });

    test('annotated local types use a single collector', () {
      final source = _specExtractorSource();
      expect(source, contains('static _ExtractedTypes _extractAnnotatedTypes(LibraryReader library)'));
      expect(source, contains('final localTypes = _extractAnnotatedTypes(library);'));
      expect(source, contains('final importedTypes = _extractAnnotatedTypes(importedReader);'));
      expect(source, isNot(contains('library.annotatedWith(structChecker)')));
      expect(source, isNot(contains('library.annotatedWith(enumChecker)')));
    });
  });

  group('L13 uint64 spec_extractor support', () {
    test('uint64 alias check is present in _makeBridgeType', () {
      final source = _specExtractorSource();
      expect(source, contains("aliasName == 'uint64'"));
    });

    test('uint64 displayName fallback check is present', () {
      final source = _specExtractorSource();
      expect(source, contains("displayName == 'uint64'"));
    });

    test('uint64 name includes ? suffix when nullable', () {
      final source = _specExtractorSource();
      expect(source, contains("isNullable ? 'uint64?' : 'uint64'"));
    });

    test('uint64 check precedes InterfaceType dispatch inside _makeBridgeType', () {
      final source = _specExtractorSource();
      // Scope the ordering check to the _makeBridgeType function body only.
      final fnStart = source.indexOf('static BridgeType _makeBridgeType(');
      final fnEnd = source.indexOf('\n  static ', fnStart + 1);
      final fnBody = source.substring(fnStart, fnEnd);
      final aliasIdx = fnBody.indexOf("aliasName == 'uint64'");
      final ifaceIdx = fnBody.indexOf('if (type is InterfaceType)');
      expect(aliasIdx, greaterThan(0), reason: 'uint64 alias check must be present in _makeBridgeType');
      expect(aliasIdx, lessThan(ifaceIdx), reason: 'uint64 alias check must come before InterfaceType dispatch');
    });
  });

  group('L12 @NitroTuple spec_extractor support', () {
    test('NitroTuple TypeChecker is declared', () {
      final source = _specExtractorSource();
      expect(source, contains("TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroTuple')"));
    });

    test('typeAliases are scanned for @NitroTuple', () {
      final source = _specExtractorSource();
      expect(source, contains('library.element.typeAliases'));
      expect(source, contains('tupleChecker.hasAnnotationOf(alias)'));
    });

    test('_buildTupleRecord method exists', () {
      final source = _specExtractorSource();
      expect(source, contains('static BridgeRecordType _buildTupleRecord('));
    });

    test('_buildTupleRecord validates aliasedType is RecordType', () {
      final source = _specExtractorSource();
      expect(source, contains('aliasedType is! RecordType'));
      expect(source, contains('@NitroTuple requires a positional record typedef'));
    });

    test('_buildTupleRecord names fields field0, field1, ...', () {
      final source = _specExtractorSource();
      expect(source, contains("name: 'field\$i'"));
    });

    test('_buildTupleRecord emits BridgeRecordType with isTuple: true', () {
      final source = _specExtractorSource();
      expect(source, contains('BridgeRecordType(name: alias.name!, isTuple: true, fields: fields)'));
    });

    test('tupleTypeNames set is computed in extract()', () {
      final source = _specExtractorSource();
      expect(source, contains('final tupleTypeNames = allRecordTypes.where((r) => r.isTuple)'));
    });

    test('tupleTypeNames is passed to _extractFunctions', () {
      final source = _specExtractorSource();
      expect(source, contains('tupleTypeNames: tupleTypeNames'));
    });

    test('_makeBridgeType accepts tupleTypeNames parameter', () {
      final source = _specExtractorSource();
      expect(source, contains('Set<String> tupleTypeNames = const {}'));
    });

    test('_makeBridgeType emits isTuple: true for matched tuple type', () {
      final source = _specExtractorSource();
      expect(source, contains('isTuple: true,'));
    });

    test('isTuple preserved when importing records from other libraries', () {
      final source = _specExtractorSource();
      expect(source, contains('isTuple: r.isTuple,'));
    });
  });
}
