// ignore_for_file: deprecated_member_use
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:source_gen/source_gen.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'bridge_spec.dart';

part 'extraction/imported_types.dart';
part 'extraction/platform_impls.dart';
part 'extraction/declared_types.dart';
part 'extraction/bridge_types.dart';
part 'extraction/members.dart';

class SpecParseException implements Exception {
  final String message;
  final String? sourceUri;
  final Object? cause;
  final StackTrace? stackTrace;

  SpecParseException(
    this.message, {
    this.sourceUri,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() {
    final source = sourceUri == null ? '' : ' (source: $sourceUri)';
    final causedBy = cause == null ? '' : '\nCaused by: $cause';
    return 'SpecParseException: $message$source$causedBy';
  }
}

class _ModuleMembers {
  /// Methods, plus getters that take the method path (see [_isMethodGetter]).
  final List<ExecutableElement> functions;
  final List<MethodElement> streamMethods;
  final List<PropertyAccessorElement> propertyGetters;
  final List<PropertyAccessorElement> streamGetters;
  final List<PropertyAccessorElement> setters;

  _ModuleMembers._({
    required this.functions,
    required this.streamMethods,
    required this.propertyGetters,
    required this.streamGetters,
    required this.setters,
  });

  factory _ModuleMembers.from(ClassElement element) {
    final functions = <ExecutableElement>[];
    final streamMethods = <MethodElement>[];
    final propertyGetters = <PropertyAccessorElement>[];
    final streamGetters = <PropertyAccessorElement>[];
    final setters = <PropertyAccessorElement>[];

    for (final method in element.methods) {
      if (!method.isAbstract) continue;
      if (_isStreamType(method.returnType)) {
        streamMethods.add(method);
      } else {
        functions.add(method);
      }
    }

    final setterNames = {
      for (final s in element.setters)
        if (s.isAbstract) s.displayName.replaceFirst('=', ''),
    };
    for (final getter in element.getters) {
      if (!getter.isAbstract) continue;
      if (_isStreamType(getter.returnType)) {
        streamGetters.add(getter);
      } else if (setterNames.contains(getter.displayName)) {
        // Read/write property: only per-accessor @nitroFast / @mainThread fit
        // (Swift/Kotlin have no async or throwing settable property).
        _rejectAccessorAnnotations(getter);
        propertyGetters.add(getter);
      } else if (_isMethodGetter(getter)) {
        functions.add(getter);
      } else {
        propertyGetters.add(getter);
      }
    }

    for (final setter in element.setters) {
      if (!setter.isAbstract) continue;
      _rejectAccessorAnnotations(setter);
      setters.add(setter);
    }

    return _ModuleMembers._(
      functions: functions,
      streamMethods: streamMethods,
      propertyGetters: propertyGetters,
      streamGetters: streamGetters,
      setters: setters,
    );
  }
}

/// Method annotations that, on a getter, route it through the method path.
const _methodAnnotations = ['NitroAsync', 'NitroNativeAsync', 'NitroFast', 'MainThread', 'ZeroCopy', 'NitroOwned', 'NitroResult'];

/// Annotations a read/write property's accessors may carry.
const _accessorAnnotations = ['NitroFast', 'MainThread'];

bool _hasAnnotation(Element e, String name) => TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#$name').hasAnnotationOf(e);

void _rejectAccessorAnnotations(PropertyAccessorElement accessor) {
  final bad = _methodAnnotations.where((a) => !_accessorAnnotations.contains(a) && _hasAnnotation(accessor, a)).toList();
  if (bad.isEmpty) return;
  throw InvalidGenerationSource(
    '"${accessor.displayName.replaceFirst('=', '')}" is a read/write property: only @nitroFast and @mainThread apply to its '
    'accessors (found @${bad.join(', @')}). Async, zero-copy, owned and result getters must be read-only.',
    element: accessor,
  );
}

/// A getter carrying a method annotation takes the method path, so the
/// annotation means exactly what it means on a method.
bool _isMethodGetter(PropertyAccessorElement getter) => _methodAnnotations.any((a) => _hasAnnotation(getter, a));

class _ExtractedTypes {
  final List<BridgeEnum> enums;
  final List<BridgeStruct> structs;
  final List<BridgeRecordType> records;
  final List<BridgeVariant> variants;
  final List<BridgeCustomType> customTypes;

  const _ExtractedTypes({
    required this.enums,
    required this.structs,
    required this.records,
    this.variants = const [],
    this.customTypes = const [],
  });
}

/// Turns a resolved `.native.dart` library into a [BridgeSpec].
///
/// This file orchestrates; the steps live in `extraction/`: `platform_impls`
/// (which language implements each platform), `declared_types` (structs,
/// records, variants, enums), `imported_types` (types from other spec files),
/// `bridge_types` (Dart type → `BridgeType`) and `members` (methods,
/// properties, streams, entry points).
class SpecExtractor {
  /// Extracts a [BridgeSpec] from [library].
  ///
  /// If the library has a `@NitroModule` annotation a full spec is returned.
  /// If it only contains type annotations (`@HybridEnum`, `@HybridStruct`,
  /// `@HybridRecord`) a type-only spec is returned (no bridge scaffolding).
  /// Returns `null` when the library has nothing Nitrogen-relevant.
  static BridgeSpec? extractAny(LibraryReader library) {
    final modules = library.annotatedWith(const TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroModule'));
    if (modules.isEmpty) return extractTypesOnly(library);
    return extract(library);
  }

  /// Extracts a type-only [BridgeSpec] for `.native.dart` files that declare
  /// shared types (`@HybridEnum`, `@HybridStruct`, `@HybridRecord`, `@NitroVariant`)
  /// without a `@NitroModule` class. Returns `null` when no relevant types are found.
  static BridgeSpec? extractTypesOnly(LibraryReader library) {
    final types = _extractAnnotatedTypes(library);
    final enums = types.enums;
    final structs = types.structs;
    final records = types.records;
    final variants = types.variants;
    if (enums.isEmpty && structs.isEmpty && records.isEmpty && variants.isEmpty) return null;

    final sourcePath = library.element.uri.toString();
    final sourceFile = sourcePath.split('/').last.replaceFirst('.native.dart', '');
    // Types this file builds on (another type file): needed to encode them
    // inside local records; marked imported so they are not redeclared.
    final imported = _extractFromImports(library.element, sourcePath);
    return BridgeSpec(
      dartClassName: '',
      lib: sourceFile.replaceAll('-', '_'),
      namespace: '',
      sourceUri: sourcePath,
      enums: [...enums, ...imported.enums],
      structs: [...structs, ...imported.structs],
      recordTypes: [...records, ...imported.records],
      variants: [...variants, ...imported.variants],
      isTypeOnly: true,
      importedTypeFiles: imported.cppIncludes,
      importedSpecs: imported.dartImports,
      importedTypeLibs: imported.typeLibs,
    );
  }

  static BridgeSpec extract(LibraryReader library) {
    final modules = library.annotatedWith(const TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroModule'));
    if (modules.isEmpty) {
      throw InvalidGenerationSource(
        'No @NitroModule annotated classes found.',
      );
    }

    final module = modules.first;
    final element = module.element as ClassElement;
    final annotation = module.annotation;

    final sourcePath = library.element.uri.toString();
    final iosImpl = annotation.read('ios').isNull ? null : _getNativeImpl(annotation.read('ios').objectValue, fieldName: 'ios', sourcePath: sourcePath);
    final androidImpl = annotation.read('android').isNull ? null : _getNativeImpl(annotation.read('android').objectValue, fieldName: 'android', sourcePath: sourcePath);
    final macosImpl = annotation.read('macos').isNull ? null : _getNativeImpl(annotation.read('macos').objectValue, fieldName: 'macos', sourcePath: sourcePath);
    final windowsImpl = annotation.read('windows').isNull ? null : _getNativeImpl(annotation.read('windows').objectValue, fieldName: 'windows', sourcePath: sourcePath);
    final linuxImpl = annotation.read('linux').isNull ? null : _getNativeImpl(annotation.read('linux').objectValue, fieldName: 'linux', sourcePath: sourcePath);
    final webImpl = annotation.read('web').isNull ? null : _getNativeImpl(annotation.read('web').objectValue, fieldName: 'web', sourcePath: sourcePath);
    final cSymbolPrefix = annotation.read('cSymbolPrefix').isNull ? null : annotation.read('cSymbolPrefix').stringValue;
    final lib = annotation.read('lib').isNull ? null : annotation.read('lib').stringValue;
    final sourceFile = library.element.uri.pathSegments.last.replaceFirst('.native.dart', '');
    final libName = lib ?? sourceFile.replaceAll('-', '_');
    final ns = cSymbolPrefix ?? _toSnakeCase(element.name!);

    // Extract local types first so we know which type names are records/structs/enums.
    final localTypes = _extractAnnotatedTypes(library);
    final localRecordTypes = localTypes.records;
    final localStructs = localTypes.structs;
    final localEnums = localTypes.enums;
    final localVariants = localTypes.variants;
    final localCustomTypes = localTypes.customTypes;

    // Also scan directly imported libraries for shared type annotations.
    // Types found in imported .native.dart files are marked isImported: true so
    // generators skip re-declaring them (they appear in the other bridge file).
    final imported = _extractFromImports(library.element, sourcePath);

    // ── Built-in library record types (from package:nitro) ──────────────────
    // isImported: false — Kotlin/Swift data class + codec MUST be generated
    // (there is no shared native equivalent of package:nitro on Android/iOS).
    // The Dart RecordExt extension is suppressed separately in record_generator.dart
    // via _nitroLibraryRecordTypes, because the Dart codec already lives on the
    // class itself in package:nitro/src/nitro_nullable.dart.
    final builtinNitroRecords = <BridgeRecordType>[
      BridgeRecordType(
        name: 'NitroNullableInt',
        fields: [
          BridgeRecordField(name: 'hasValue', dartType: 'bool', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'value', dartType: 'int', kind: RecordFieldKind.primitive),
        ],
      ),
      BridgeRecordType(
        name: 'NitroNullableDouble',
        fields: [
          BridgeRecordField(name: 'hasValue', dartType: 'bool', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
        ],
      ),
      BridgeRecordType(
        name: 'NitroNullableBool',
        fields: [
          BridgeRecordField(name: 'hasValue', dartType: 'bool', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'value', dartType: 'bool', kind: RecordFieldKind.primitive),
        ],
      ),
      // NitroOpt* — packed 2-field structs for nullable primitive bridge transport.
      // Wire: [1B hasValue][N bytes value] — NO RecordWriter 4-byte length prefix.
      // Used for int?/double?/bool? params and returns in all bridge generators.
      BridgeRecordType(
        name: 'NitroOptInt64',
        fields: [
          BridgeRecordField(name: 'hasValue', dartType: 'bool', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'value', dartType: 'int', kind: RecordFieldKind.primitive),
        ],
      ),
      BridgeRecordType(
        name: 'NitroOptFloat64',
        fields: [
          BridgeRecordField(name: 'hasValue', dartType: 'bool', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
        ],
      ),
      BridgeRecordType(
        name: 'NitroOptBool',
        fields: [
          BridgeRecordField(name: 'hasValue', dartType: 'bool', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'value', dartType: 'bool', kind: RecordFieldKind.primitive),
        ],
      ),
    ];
    final allRecordTypes = [...localRecordTypes, ...imported.records, ...builtinNitroRecords];
    final allStructs = [...localStructs, ...imported.structs];
    final allEnums = [...localEnums, ...imported.enums];
    final allVariants = [...localVariants, ...imported.variants];
    final allCustomTypes = [...localCustomTypes];

    final recordTypeNames = allRecordTypes.map((r) => r.name).toSet();
    final structNames = allStructs.map((s) => s.name).toSet();
    final enumNames = allEnums.map((e) => e.name).toSet();
    final variantNames = allVariants.map((v) => v.name).toSet();
    final customTypeNames = allCustomTypes.map((c) => c.name).toSet();
    final tupleTypeNames = allRecordTypes.where((r) => r.isTuple).map((r) => r.name).toSet();
    final knownTypeNames = {...structNames, ...enumNames, ...recordTypeNames, ...variantNames, ...customTypeNames};

    final members = _ModuleMembers.from(element);
    final (:properties, :streams) = _extractPropertiesAndStreams(
      members,
      ns,
      recordTypeNames,
      knownTypeNames,
      structTypeNames: structNames,
      enumTypeNames: enumNames,
      variantTypeNames: variantNames,
      tupleTypeNames: tupleTypeNames,
    );
    return BridgeSpec(
      dartClassName: element.name!,
      lib: libName,
      namespace: ns,
      iosImpl: iosImpl,
      androidImpl: androidImpl,
      macosImpl: macosImpl,
      windowsImpl: windowsImpl,
      linuxImpl: linuxImpl,
      webImpl: webImpl,
      sourceUri: sourcePath,
      functions: _extractFunctions(members.functions, ns, recordTypeNames, knownTypeNames, structTypeNames: structNames, enumTypeNames: enumNames, variantTypeNames: variantNames, tupleTypeNames: tupleTypeNames),
      properties: properties,
      streams: streams,
      entryPoints: _extractEntryPoints(library, recordTypeNames, knownTypeNames, structNames, enumNames, variantNames, tupleTypeNames),
      structs: allStructs,
      enums: allEnums,
      recordTypes: allRecordTypes,
      variants: allVariants,
      customTypes: allCustomTypes,
      importedTypeFiles: imported.cppIncludes,
      importedSpecs: imported.dartImports,
      importedTypeLibs: imported.typeLibs,
    );
  }

  // ─── Cross-library type scanning ────────────────────────────────────────────

  // ─── @HybridRecord / @NitroVariant ───────────────────────────────────────────

  // ─── Functions ───────────────────────────────────────────────────────────────

  // ─── Properties + Streams ───────────────────────────────────────────────────

  // ─── Structs ─────────────────────────────────────────────────────────────────

  // ─── Enums ───────────────────────────────────────────────────────────────────

}
