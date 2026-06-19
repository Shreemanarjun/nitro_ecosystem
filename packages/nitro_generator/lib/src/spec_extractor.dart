// ignore_for_file: deprecated_member_use
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:source_gen/source_gen.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'bridge_spec.dart';

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
  /// shared types (`@HybridEnum`, `@HybridStruct`, `@HybridRecord`) without a
  /// `@NitroModule` class. Returns `null` when no relevant types are found.
  static BridgeSpec? extractTypesOnly(LibraryReader library) {
    final enums = _extractEnums(library);
    final structs = _extractStructs(library);
    final records = _extractRecordTypes(library);
    if (enums.isEmpty && structs.isEmpty && records.isEmpty) return null;

    final sourcePath = library.element.uri.toString();
    final sourceFile = sourcePath.split('/').last.replaceFirst('.native.dart', '');
    return BridgeSpec(
      dartClassName: '',
      lib: sourceFile.replaceAll('-', '_'),
      namespace: '',
      sourceUri: sourcePath,
      enums: enums,
      structs: structs,
      recordTypes: records,
      isTypeOnly: true,
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
    final localRecordTypes = _extractRecordTypes(library);
    final localStructs = _extractStructs(library);
    final localEnums = _extractEnums(library);

    // Also scan directly imported libraries for shared type annotations.
    // Types found in imported .native.dart files are marked isImported: true so
    // generators skip re-declaring them (they appear in the other bridge file).
    final imported = _extractFromImports(library.element, sourcePath);

    final allRecordTypes = [...localRecordTypes, ...imported.records];
    final allStructs = [...localStructs, ...imported.structs];
    final allEnums = [...localEnums, ...imported.enums];

    final recordTypeNames = allRecordTypes.map((r) => r.name).toSet();
    final structNames = allStructs.map((s) => s.name).toSet();
    final enumNames = allEnums.map((e) => e.name).toSet();
    final knownTypeNames = {...structNames, ...enumNames, ...recordTypeNames};

    final (:properties, :streams) = _extractPropertiesAndStreams(element, ns, recordTypeNames, knownTypeNames, structTypeNames: structNames);
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
      functions: _extractFunctions(element, ns, recordTypeNames, knownTypeNames, structTypeNames: structNames),
      properties: properties,
      streams: streams,
      structs: allStructs,
      enums: allEnums,
      recordTypes: allRecordTypes,
      importedTypeFiles: imported.cppIncludes,
    );
  }

  // ─── Cross-library type scanning ────────────────────────────────────────────

  /// Scans directly imported libraries of [libraryElement] for `@HybridEnum`,
  /// `@HybridStruct`, and `@HybridRecord` annotations.
  ///
  /// Only non-SDK imports are scanned (`dart:` URIs are skipped). Types found
  /// in `.native.dart` imports are marked [isImported]=true (a bridge file is
  /// generated for them separately) and contribute a C++ `#include` path.
  /// Types from regular `.dart` imports are treated as local (included as-is).
  static ({
    List<BridgeEnum> enums,
    List<BridgeStruct> structs,
    List<BridgeRecordType> records,
    List<String> cppIncludes,
  })
  _extractFromImports(LibraryElement libraryElement, String currentSourceUri) {
    final enums = <BridgeEnum>[];
    final structs = <BridgeStruct>[];
    final records = <BridgeRecordType>[];
    final cppIncludes = <String>[];

    for (final imported in libraryElement.firstFragment.importedLibraries) {
      final uri = imported.uri.toString();
      // Skip Dart SDK and the nitro annotation packages (no user types there).
      if (uri.startsWith('dart:')) continue;
      if (uri.contains('nitro_annotations')) continue;

      final importedReader = LibraryReader(imported);
      final importedEnums = _extractEnums(importedReader);
      final importedStructs = _extractStructs(importedReader);
      final importedRecords = _extractRecordTypes(importedReader);

      if (importedEnums.isEmpty && importedStructs.isEmpty && importedRecords.isEmpty) continue;

      final isNativeFile = uri.endsWith('.native.dart');

      enums.addAll(
        importedEnums.map(
          (e) => BridgeEnum(
            name: e.name,
            startValue: e.startValue,
            values: e.values,
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
            isImported: isNativeFile,
          ),
        ),
      );

      // Compute C++ #include path only for .native.dart imports (those have
      // a generated bridge header file in generated/cpp/).
      if (isNativeFile) {
        cppIncludes.add(_cppIncludePath(currentSourceUri, uri));
      }
    }

    return (enums: enums, structs: structs, records: records, cppIncludes: cppIncludes);
  }

  /// Computes the relative `#include` path from [fromUri]'s generated C++
  /// header to [toUri]'s generated C++ header.
  ///
  /// Both URIs are `.native.dart` source paths. The generated headers live at
  /// `lib/{dir}/generated/cpp/{stem}.bridge.g.h`.
  static String _cppIncludePath(String fromUri, String toUri) {
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

  static NativeImpl _getNativeImpl(
    DartObject object, {
    String? fieldName,
    String? sourcePath,
  }) {
    // Reconstruct by runtime type name — robust against class reordering.
    // Each NativeImpl subclass (SwiftImpl, KotlinImpl, CppImpl, WasmImpl) has a
    // unique name that the analyzer preserves in the DartObject type element.
    //
    // Per-platform sealed class constants (e.g. AppleNativeImpl.swift) share
    // the same compile-time objects as NativeImpl.* — they are identical Dart
    // const values. The analyzer should return the concrete type (SwiftImpl,
    // CppImpl, etc.) rather than the sealed class type. The platform-type
    // entries below act as a safety-net in case a future analyzer version
    // returns the declared type of the constant instead of its value type.
    final typeName = object.type?.element?.name;

    // Fast path: unambiguous names handled by the shared helper in
    // nitro_annotations. Keeps the mapping co-located with the annotations so
    // any tool (nitrogen_cli, docs generator) can reuse it.
    final shared = NativeImpl.fromTypeName(typeName);
    if (shared != null) return shared;

    // Slow path: ambiguous sealed markers require analyzer-level supertype
    // inspection to pick between the language-specific impl and CppImpl.
    switch (typeName) {
      case 'AppleNativeImpl':
        if (fieldName == 'ios' || fieldName == 'macos') {
          return _inferAppleImpl(object);
        }
        throw InvalidGenerationSource(
          'Cannot infer AppleNativeImpl kind for field "$fieldName"'
          '${sourcePath != null ? " in $sourcePath" : ""}. '
          'Use AppleNativeImpl.swift or AppleNativeImpl.cpp explicitly.',
        );
      case 'AndroidNativeImpl':
        return _inferAndroidImpl(object);
    }
    throw InvalidGenerationSource(
      'Unknown NativeImpl subclass: "$typeName" '
      '(field: "${fieldName ?? '<unknown>'}"'
      '${sourcePath != null ? ", source: $sourcePath" : ""}). '
      'Use AppleNativeImpl.swift/.cpp, AndroidNativeImpl.kotlin/.cpp, '
      'WindowsNativeImpl.cpp, LinuxNativeImpl.cpp, WebNativeImpl.wasm, '
      'or the NativeImpl.* shorthands.',
    );
  }

  /// Disambiguates [AppleNativeImpl] by inspecting the constant's supertype
  /// chain for [SwiftImpl] vs [CppImpl].
  static NativeImpl _inferAppleImpl(DartObject object) {
    final element = object.type?.element;
    final names = (element is InterfaceElement) ? element.allSupertypes.map((t) => t.element.name).whereType<String>().toSet() : <String>{};
    if (names.contains('SwiftImpl')) return NativeImpl.swift;
    if (names.contains('CppImpl')) return NativeImpl.cpp;
    throw InvalidGenerationSource(
      'Cannot determine AppleNativeImpl kind from type hierarchy. '
      'Use AppleNativeImpl.swift or AppleNativeImpl.cpp.',
    );
  }

  /// Disambiguates [AndroidNativeImpl] by inspecting the constant's supertype
  /// chain for [KotlinImpl] vs [CppImpl].
  static NativeImpl _inferAndroidImpl(DartObject object) {
    final element = object.type?.element;
    final names = (element is InterfaceElement) ? element.allSupertypes.map((t) => t.element.name).whereType<String>().toSet() : <String>{};
    if (names.contains('KotlinImpl')) return NativeImpl.kotlin;
    if (names.contains('CppImpl')) return NativeImpl.cpp;
    throw InvalidGenerationSource(
      'Cannot determine AndroidNativeImpl kind from type hierarchy. '
      'Use AndroidNativeImpl.kotlin or AndroidNativeImpl.cpp.',
    );
  }

  // ─── @HybridRecord ────────────────────────────────────────────────────────

  static List<BridgeRecordType> _extractRecordTypes(LibraryReader library) {
    const checker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridRecord');
    const structChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridStruct');
    const enumChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridEnum');

    // Single pass: collect annotated ClassElements, then reuse the list.
    final classes = library.annotatedWith(checker).where((ann) => ann.element is ClassElement).map((ann) => ann.element as ClassElement).toList();

    final recordTypeNames = classes.map((c) => c.name!).toSet();
    // Also collect @HybridStruct names so that List<@HybridStruct T> fields
    // inside @HybridRecord classes are classified as listRecordObject (not
    // listPrimitive), enabling binary codec generation for struct items.
    final structTypeNames = library.annotatedWith(structChecker).where((ann) => ann.element is ClassElement).map((ann) => (ann.element as ClassElement).name!).toSet();
    final enumTypeNames = library.annotatedWith(enumChecker).where((ann) => ann.element is EnumElement).map((ann) => (ann.element as EnumElement).name!).toSet();

    return classes.map((cls) {
      final fields = cls.fields.where((f) => !f.isStatic && !f.isSynthetic).map((f) {
        final displayType = f.type.getDisplayString();
        final isNullable = displayType.endsWith('?');
        final kind = _recordFieldKind(f.type, recordTypeNames, structTypeNames, enumTypeNames);
        final itemTypeName = _listItemTypeName(f.type);
        return BridgeRecordField(
          name: f.name!,
          dartType: displayType,
          kind: kind,
          itemTypeName: itemTypeName,
          isNullable: isNullable,
        );
      }).toList();
      return BridgeRecordType(name: cls.name!, fields: fields);
    }).toList();
  }

  static RecordFieldKind _recordFieldKind(
    DartType type,
    Set<String> recordTypeNames, [
    Set<String> structTypeNames = const {},
    Set<String> enumTypeNames = const {},
  ]) {
    if (type is InterfaceType) {
      if (type.element.name == 'List' && type.typeArguments.isNotEmpty) {
        final itemName = type.typeArguments.first.getDisplayString(withNullability: false);
        if (recordTypeNames.contains(itemName) || structTypeNames.contains(itemName)) {
          return RecordFieldKind.listRecordObject;
        }
        if (enumTypeNames.contains(itemName)) {
          return RecordFieldKind.listEnumValue;
        }
        return RecordFieldKind.listPrimitive;
      }
      if (recordTypeNames.contains(type.element.name) || structTypeNames.contains(type.element.name)) {
        return RecordFieldKind.recordObject;
      }
      if (enumTypeNames.contains(type.element.name)) {
        return RecordFieldKind.enumValue;
      }
    }
    return RecordFieldKind.primitive;
  }

  static String? _listItemTypeName(DartType type) {
    if (type is InterfaceType && type.element.name == 'List' && type.typeArguments.isNotEmpty) {
      return type.typeArguments.first.getDisplayString(withNullability: false);
    }
    return null;
  }

  static const _primitiveNames = {
    'int',
    'double',
    'bool',
    'String',
    'void',
    'Uint8List',
    'Int8List',
    'Int16List',
    'Int32List',
    'Uint16List',
    'Uint32List',
    'Float32List',
    'Float64List',
    'Int64List',
    'Uint64List',
    'Pointer',
  };

  /// Converts a [DartType] to a [BridgeType], marking JSON-bridged types:
  /// - `@HybridRecord` class  → `isRecord: true`
  /// - `List<@HybridRecord T>` → `isRecord: true, recordListItemType: T`
  /// - `List<@HybridStruct T>` → `isRecord: true, recordListItemType: T`
  /// - `List<primitive T>`    → `isRecord: true, recordListItemType: T, recordListItemIsPrimitive: true`
  /// - `Map<String, T>`       → `isRecord: true, isMap: true`
  static BridgeType _makeBridgeType(
    DartType type,
    Set<String> recordTypeNames, {
    bool isFuture = false,
    Set<String> knownTypeNames = const {},
    Set<String> structTypeNames = const {},
  }) {
    final displayName = type.getDisplayString();
    final isNullable = type.nullabilitySuffix == NullabilitySuffix.question;

    // Handle function types (callbacks)
    if (type is FunctionType) {
      final returnType = type.returnType;
      final returnTypeName = returnType.getDisplayString(withNullability: false);
      final params = <BridgeType>[];

      for (final param in type.formalParameters) {
        params.add(
          _makeBridgeType(
            param.type,
            recordTypeNames,
            knownTypeNames: knownTypeNames,
            structTypeNames: structTypeNames,
          ),
        );
      }

      return BridgeType(
        name: displayName,
        isNullable: isNullable,
        isFuture: isFuture,
        isFunction: true,
        functionReturnType: returnTypeName,
        functionParams: params,
      );
    }

    if (type is InterfaceType) {
      final elName = type.element.name;

      // List<T> — record, struct, or primitive items
      if (elName == 'List' && type.typeArguments.isNotEmpty) {
        final itemType = type.typeArguments.first;
        final itemName = itemType.getDisplayString(withNullability: false);
        if (recordTypeNames.contains(itemName)) {
          return BridgeType(
            name: displayName,
            isRecord: true,
            isNullable: isNullable,
            recordListItemType: itemName,
            isFuture: isFuture,
          );
        }
        if (structTypeNames.contains(itemName)) {
          return BridgeType(
            name: displayName,
            isRecord: true,
            isNullable: isNullable,
            recordListItemType: itemName,
            isFuture: isFuture,
          );
        }
        if (_primitiveNames.contains(itemName)) {
          return BridgeType(
            name: displayName,
            isRecord: true,
            isNullable: isNullable,
            recordListItemType: itemName,
            recordListItemIsPrimitive: true,
            isFuture: isFuture,
          );
        }
      }

      // Map<String, T> — JSON object bridge
      if (elName == 'Map' && type.typeArguments.length == 2 && type.typeArguments.first.getDisplayString(withNullability: false) == 'String') {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isNullable: isNullable,
          isMap: true,
          isFuture: isFuture,
        );
      }

      // Direct @HybridRecord class
      if (recordTypeNames.contains(elName)) {
        return BridgeType(name: displayName, isRecord: true, isNullable: isNullable, isFuture: isFuture);
      }

      // Pointer<T> — raw FFI bridge
      if (elName == 'Pointer' && type.typeArguments.isNotEmpty) {
        final inner = type.typeArguments.first.getDisplayString(withNullability: false);
        return BridgeType(
          name: displayName,
          isPointer: true,
          isNullable: isNullable,
          pointerInnerType: inner,
          isFuture: isFuture,
        );
      }

      // Known type from @HybridEnum or @HybridStruct (but NOT @HybridRecord)
      if (knownTypeNames.contains(elName) && !recordTypeNames.contains(elName)) {
        return BridgeType(name: displayName, isNullable: isNullable, isFuture: isFuture);
      }
    }

    return BridgeType(name: displayName, isNullable: isNullable, isFuture: isFuture);
  }

  // ─── Functions ───────────────────────────────────────────────────────────────

  static List<BridgeFunction> _extractFunctions(
    ClassElement element,
    String ns,
    Set<String> recordTypeNames,
    Set<String> knownTypeNames, {
    Set<String> structTypeNames = const {},
  }) {
    const asyncChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroAsync');
    const nativeAsyncChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroNativeAsync');
    const zeroCopyChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#ZeroCopy');

    // Skip abstract getters annotated with @NitroStream or abstract getters/setters
    return element.methods.where((m) => m.isAbstract && !_isStreamType(m.returnType)).map((m) {
      final isAsync = asyncChecker.hasAnnotationOf(m);
      final isNativeAsync = nativeAsyncChecker.hasAnnotationOf(m);

      if (isAsync && isNativeAsync) {
        throw InvalidGenerationSource(
          '@NitroAsync and @NitroNativeAsync cannot both be applied to "${m.name!}". '
          'Use @NitroNativeAsync when the native implementation posts the result '
          'directly via Dart_PostCObject_DL.',
        );
      }

      DartType returnDartType = m.returnType;
      if ((isAsync || isNativeAsync) && returnDartType.isDartAsyncFuture) {
        final it = returnDartType as InterfaceType;
        if (it.typeArguments.isNotEmpty) returnDartType = it.typeArguments.first;
      }

      return BridgeFunction(
        dartName: m.name!,
        cSymbol: '${ns}_${_toSnakeCase(m.name!)}',
        isAsync: isAsync,
        isNativeAsync: isNativeAsync,
        returnType: _makeBridgeType(
          returnDartType,
          recordTypeNames,
          isFuture: isAsync || isNativeAsync,
          knownTypeNames: knownTypeNames,
          structTypeNames: structTypeNames,
        ),
        params: m.formalParameters.map((p) {
          return BridgeParam(
            name: p.name!,
            type: _makeBridgeType(p.type, recordTypeNames, knownTypeNames: knownTypeNames, structTypeNames: structTypeNames),
            zeroCopy: zeroCopyChecker.hasAnnotationOf(p),
            isNamed: p.isNamed,
            isOptional: p.isOptional,
            defaultLiteral: p.defaultValueCode,
          );
        }).toList(),
        lineNumber: _lineOf(m),
      );
    }).toList();
  }

  // ─── Properties + Streams (two passes: getters then setters) ────────────────

  static ({List<BridgeProperty> properties, List<BridgeStream> streams}) _extractPropertiesAndStreams(
    ClassElement element,
    String ns,
    Set<String> recordTypeNames,
    Set<String> knownTypeNames, {
    Set<String> structTypeNames = const {},
  }) {
    const streamChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroStream');

    // Accumulate properties grouped by accessor name.
    final propMap = <String, Map<String, dynamic>>{};
    final streams = <BridgeStream>[];

    // ── Stream methods — `Stream<T> name()` style ────────────────────────────
    for (final m in element.methods) {
      if (!m.isAbstract) continue;
      if (!_isStreamType(m.returnType)) continue;

      final retType = m.returnType as InterfaceType;
      final itemDartType = retType.typeArguments.isNotEmpty ? retType.typeArguments.first : null;

      Backpressure backpressure = Backpressure.dropLatest;
      final ann = streamChecker.firstAnnotationOf(m);
      if (ann != null) {
        final bpField = ann.getField('backpressure');
        final bpIndex = bpField?.getField('index')?.toIntValue() ?? 0;
        backpressure = Backpressure.values[bpIndex];
      }

      final name = m.name!;
      streams.add(
        BridgeStream(
          dartName: name,
          registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
          releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
          itemType: itemDartType != null ? _makeBridgeType(itemDartType, recordTypeNames, knownTypeNames: knownTypeNames, structTypeNames: structTypeNames) : BridgeType(name: 'dynamic'),
          backpressure: backpressure,
          isMethodStyle: true,
          isAnnotated: ann != null,
        ),
      );
    }

    // ── Getters ──────────────────────────────────────────────────────────────
    for (final ac in element.getters) {
      if (!ac.isAbstract) continue;

      // Stream getters are handled separately; skip them for properties.
      if (_isStreamType(ac.returnType)) {
        final retType = ac.returnType as InterfaceType;
        final itemDartType = retType.typeArguments.isNotEmpty ? retType.typeArguments.first : null;

        Backpressure backpressure = Backpressure.dropLatest;
        final ann = streamChecker.firstAnnotationOf(ac);
        if (ann != null) {
          final bpField = ann.getField('backpressure');
          final bpIndex = bpField?.getField('index')?.toIntValue() ?? 0;
          backpressure = Backpressure.values[bpIndex];
        }

        final name = ac.displayName;
        streams.add(
          BridgeStream(
            dartName: name,
            registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
            releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
            itemType: itemDartType != null ? _makeBridgeType(itemDartType, recordTypeNames, knownTypeNames: knownTypeNames, structTypeNames: structTypeNames) : BridgeType(name: 'dynamic'),
            backpressure: backpressure,
            isAnnotated: ann != null,
          ),
        );
        continue;
      }

      final name = ac.displayName;
      final type = ac.returnType;

      final entry = propMap.putIfAbsent(name, () => {'name': name, 'getter': false, 'setter': false});
      entry['getter'] = true;
      entry['dartType'] = type;
    }

    // ── Setters ──────────────────────────────────────────────────────────────
    for (final ac in element.setters) {
      if (!ac.isAbstract) continue;

      // Setter displayName includes '=' suffix (e.g. "myProp="); strip it.
      final name = ac.displayName.replaceFirst('=', '');
      final type = ac.formalParameters.first.type;

      final entry = propMap.putIfAbsent(name, () => {'name': name, 'getter': false, 'setter': false});
      entry['setter'] = true;
      entry['dartType'] ??= type;
    }

    final properties = propMap.values.where((e) => e['dartType'] != null).map((e) {
      final name = e['name'] as String;
      final dartType = e['dartType'] as DartType;
      return BridgeProperty(
        dartName: name,
        type: _makeBridgeType(dartType, recordTypeNames, knownTypeNames: knownTypeNames, structTypeNames: structTypeNames),
        getSymbol: '${ns}_get_${_toSnakeCase(name)}',
        setSymbol: '${ns}_set_${_toSnakeCase(name)}',
        hasGetter: e['getter'] as bool,
        hasSetter: e['setter'] as bool,
      );
    }).toList();

    return (properties: properties, streams: streams);
  }

  static bool _isStreamType(DartType type) {
    if (type is InterfaceType) {
      return type.element.name == 'Stream';
    }
    return false;
  }

  /// Returns the 1-based line number of [e] in its source file.
  /// Returns null on any failure (e.g. synthetic elements, missing source).
  static int? _lineOf(Element e) {
    try {
      final fragment = e.firstFragment;
      final source = fragment.libraryFragment?.source;
      if (source == null) return null;
      final text = source.contents.data;
      final offset = fragment.nameOffset;
      if (offset == null || offset < 0 || offset >= text.length) return null;
      return text.substring(0, offset).split('\n').length;
    } catch (_) {
      return null;
    }
  }

  // ─── Structs ─────────────────────────────────────────────────────────────────

  static List<BridgeStruct> _extractStructs(LibraryReader library) {
    const checker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridStruct');
    final results = <BridgeStruct>[];

    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! ClassElement) {
        continue;
      }

      final packed = ann.annotation.read('packed').literalValue as bool? ?? false;
      final zeroCopyFields = ann.annotation.read('zeroCopy').listValue.map((v) => v.toStringValue() ?? '').toSet();

      // Build a map from field name → constructor param metadata so we can
      // record isNamed / isRequired on each BridgeField.
      // Use the unnamed generative constructor (the primary one). If there is
      // none, fall back to treating every field as named-required.
      final primaryCtor = cls.unnamedConstructor;
      final paramInfo = <String, ({bool isNamed, bool isRequired})>{};
      if (primaryCtor != null) {
        for (final p in primaryCtor.formalParameters) {
          paramInfo[p.name!] = (
            isNamed: p.isNamed,
            isRequired: p.isRequired,
          );
        }
      }

      const fieldZeroCopyChecker = TypeChecker.fromUrl(
        'package:nitro_annotations/src/annotations.dart#ZeroCopy',
      );

      final fields = cls.fields.where((f) => !f.isStatic && !f.isSynthetic).map(
        (f) {
          final info = paramInfo[f.name!];
          // Accept zero-copy declared either on the struct annotation
          // (@HybridStruct(zeroCopy: ['field'])) or directly on the field
          // (@ZeroCopy()). Both forms are equivalent.
          final isZeroCopy = zeroCopyFields.contains(f.name) || fieldZeroCopyChecker.hasAnnotationOf(f);
          return BridgeField(
            name: f.name!,
            type: BridgeType(
              name: f.type.getDisplayString(),
              isNullable: f.type.nullabilitySuffix == NullabilitySuffix.question,
            ),
            zeroCopy: isZeroCopy,
            isNamed: info?.isNamed ?? true,
            isRequired: info?.isRequired ?? true,
          );
        },
      ).toList();

      results.add(BridgeStruct(name: cls.name!, packed: packed, fields: fields));
    }
    return results;
  }

  // ─── Enums ───────────────────────────────────────────────────────────────────

  static List<BridgeEnum> _extractEnums(LibraryReader library) {
    const checker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridEnum');
    final results = <BridgeEnum>[];

    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! EnumElement) {
        continue;
      }

      final startValue = ann.annotation.read('startValue').literalValue as int? ?? 0;

      results.add(
        BridgeEnum(
          name: cls.name!,
          startValue: startValue,
          values: cls.fields.where((f) => f.isEnumConstant).map((f) => f.name!).toList(),
        ),
      );
    }
    return results;
  }

  static String _toSnakeCase(String text) {
    return text
        .replaceAllMapped(
          RegExp('([a-z0-9])([A-Z])'),
          (m) => '${m.group(1)}_${m.group(2)}',
        )
        .toLowerCase();
  }
}
