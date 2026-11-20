part of '../spec_extractor.dart';

// Types a spec uses from another `.native.dart` file: collected through the
// library's imports, with the C++ include path that reaches their header.

/// Scans directly imported libraries of [libraryElement] for `@HybridEnum`,
/// `@HybridStruct`, and `@HybridRecord` annotations.
///
/// Only non-SDK imports are scanned (`dart:` URIs are skipped). Types found
/// in `.native.dart` imports are marked [isImported]=true (a bridge file is
/// generated for them separately) and contribute a C++ `#include` path.
/// Types from regular `.dart` imports are treated as local (included as-is).
({
  List<BridgeEnum> enums,
  List<BridgeStruct> structs,
  List<BridgeRecordType> records,
  List<BridgeVariant> variants,
  List<String> cppIncludes,
  List<ImportedSpec> dartImports,
  Map<String, String> typeLibs,
})
_extractFromImports(LibraryElement libraryElement, String currentSourceUri) {
  final dartImports = <ImportedSpec>[];
  final typeLibs = <String, String>{};
  final enums = <BridgeEnum>[];
  final structs = <BridgeStruct>[];
  final records = <BridgeRecordType>[];
  final variants = <BridgeVariant>[];
  final cppIncludes = <String>[];

  for (final imported in libraryElement.firstFragment.importedLibraries) {
    final uri = imported.uri.toString();
    // Skip Dart SDK and the nitro annotation packages (no user types there).
    if (uri.startsWith('dart:')) continue;
    if (uri.contains('nitro_annotations')) continue;

    final importedReader = LibraryReader(imported);
    final importedTypes = _extractAnnotatedTypes(importedReader);
    final importedEnums = importedTypes.enums;
    final importedStructs = importedTypes.structs;
    final importedRecords = importedTypes.records;
    final importedVariants = importedTypes.variants;

    if (importedEnums.isEmpty && importedStructs.isEmpty && importedRecords.isEmpty && importedVariants.isEmpty) continue;

    final isNativeFile = uri.endsWith('.native.dart');

    enums.addAll(
      importedEnums.map(
        (e) => BridgeEnum(
          name: e.name,
          startValue: e.startValue,
          values: e.values,
          // rawValues MUST be carried across: dropping them makes a
          // non-contiguous imported enum fall back to index-based values in
          // every downstream lookup table, silently mapping cases to the
          // wrong wire value across module boundaries.
          rawValues: e.rawValues,
          isImported: isNativeFile,
        ),
      ),
    );
    structs.addAll(
      importedStructs.map(
        (s) => BridgeStruct(
          name: s.name,
          packed: s.packed,
          fields: s.fields,
          isImported: isNativeFile,
        ),
      ),
    );
    records.addAll(
      importedRecords.map(
        (r) => BridgeRecordType(
          name: r.name,
          fields: r.fields,
          isTuple: r.isTuple,
          isImported: isNativeFile,
        ),
      ),
    );
    variants.addAll(
      importedVariants.map(
        (v) => BridgeVariant(
          name: v.name,
          cases: v.cases,
          isImported: isNativeFile,
        ),
      ),
    );

    // Compute C++ #include path only for .native.dart imports (those have
    // a generated bridge header file in generated/cpp/).
    if (isNativeFile) {
      cppIncludes.add(_cppIncludePath(currentSourceUri, uri));
      // Split layout: a type-only file is split whenever a web module
      // imports it (the builder's rule); a module file when it targets web.
      final modules = importedReader.annotatedWith(const TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroModule'));
      final stem = uri.split('/').last.replaceFirst('.native.dart', '');
      final lib = modules.map((m) => m.annotation.peek('lib')?.stringValue).whereType<String>().firstOrNull ?? stem;
      dartImports.add((uri: uri, lib: lib.replaceAll('-', '_'), isTypeOnly: modules.isEmpty, targetsWeb: modules.any((m) => m.annotation.peek('web') != null)));
      for (final n in [...importedEnums.map((e) => e.name), ...importedStructs.map((e) => e.name), ...importedRecords.map((e) => e.name), ...importedVariants.map((e) => e.name)]) {
        typeLibs[n] = lib.replaceAll('-', '_');
      }
    }
  }

  return (enums: enums, structs: structs, records: records, variants: variants, cppIncludes: cppIncludes, dartImports: dartImports, typeLibs: typeLibs);
}

/// Computes the relative `#include` path from [fromUri]'s generated C++
/// header to [toUri]'s generated C++ header.
///
/// Both URIs are `.native.dart` source paths. The generated headers live at
/// `lib/{dir}/generated/cpp/{stem}.bridge.g.h`.
String _cppIncludePath(String fromUri, String toUri) {
  // Extract the lib-relative directory portion of a .native.dart source URI.
  // e.g. "package:pkg/lib/src/camera.native.dart" → "src"
  String libRelDir(String uri) {
    final segs = uri.split('/');
    final li = segs.lastIndexOf('lib');
    if (li < 0 || li >= segs.length - 1) return '';
    return segs.sublist(li + 1, segs.length - 1).join('/');
  }

  final fromDir = libRelDir(fromUri);
  final toDir = libRelDir(toUri);
  final toStem = toUri.split('/').last.replaceFirst('.native.dart', '');

  // Same directory: just the filename.
  if (fromDir == toDir) return '$toStem.bridge.g.h';

  // Different directories: go up from lib/{fromDir}/generated/cpp/ to lib/,
  // then descend to lib/{toDir}/generated/cpp/{toStem}.bridge.g.h.
  final fromParts = fromDir.isEmpty ? <String>[] : fromDir.split('/');
  final upCount = fromParts.length + 2; // +2 for 'generated/cpp' depth
  final upStr = List.filled(upCount, '..').join('/');
  final toPart = toDir.isEmpty ? '' : '$toDir/';
  return '$upStr/${toPart}generated/cpp/$toStem.bridge.g.h';
}
