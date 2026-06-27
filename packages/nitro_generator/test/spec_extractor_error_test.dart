import 'dart:io';

import 'package:nitro_generator/src/spec_extractor.dart';
import 'package:test/test.dart';

String _specExtractorSource() {
  final packageRoot = File('lib/src/spec_extractor.dart');
  if (packageRoot.existsSync()) return packageRoot.readAsStringSync();
  return File('packages/nitro_generator/lib/src/spec_extractor.dart').readAsStringSync();
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
}
