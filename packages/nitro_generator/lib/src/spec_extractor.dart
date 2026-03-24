import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';
import 'package:nitro/nitro.dart';
import 'bridge_spec.dart';

class SpecExtractor {
  static BridgeSpec extract(LibraryReader library) {
    final modules = library.annotatedWith(const TypeChecker.fromRuntime(NitroModule));
    if (modules.isEmpty) {
      throw InvalidGenerationSourceError(
        'No @NitroModule annotated classes found.',
      );
    }

    final module = modules.first;
    final element = module.element as ClassElement;
    final annotation = module.annotation;

    final iosImpl = _getNativeImpl(annotation.read('ios').objectValue);
    final androidImpl = _getNativeImpl(annotation.read('android').objectValue);
    final cSymbolPrefix = annotation.read('cSymbolPrefix').isNull
        ? null
        : annotation.read('cSymbolPrefix').stringValue;
    final lib = annotation.read('lib').isNull
        ? null
        : annotation.read('lib').stringValue;
    final sourceFile = library.element.source.uri.pathSegments.last
        .replaceFirst('.native.dart', '');
    final libName = lib ?? sourceFile.replaceAll('-', '_');
    final ns = cSymbolPrefix ?? _toSnakeCase(element.name);

    // Extract @HybridRecord types first so we know which type names are records
    // when classifying function/property/stream types.
    final recordTypes = _extractRecordTypes(library);
    final recordTypeNames = recordTypes.map((r) => r.name).toSet();

    return BridgeSpec(
      dartClassName: element.name,
      lib: libName,
      namespace: ns,
      iosImpl: iosImpl,
      androidImpl: androidImpl,
      sourceUri: library.element.source.uri.toString(),
      functions: _extractFunctions(element, ns, recordTypeNames),
      properties: _extractProperties(element, ns, recordTypeNames),
      streams: _extractStreams(element, ns, recordTypeNames),
      structs: _extractStructs(library),
      enums: _extractEnums(library),
      recordTypes: recordTypes,
    );
  }

  static NativeImpl _getNativeImpl(DartObject object) {
    final index =
        object.getField('index')?.toIntValue() ?? NativeImpl.cpp.index;
    return NativeImpl.values[index];
  }

  // ─── @HybridRecord ────────────────────────────────────────────────────────

  static List<BridgeRecordType> _extractRecordTypes(LibraryReader library) {
    const checker = TypeChecker.fromRuntime(HybridRecord);

    // First pass: collect all @HybridRecord class names for nested detection.
    final recordTypeNames = <String>{};
    for (final ann in library.annotatedWith(checker)) {
      if (ann.element is ClassElement) {
        recordTypeNames.add((ann.element as ClassElement).name);
      }
    }

    // Second pass: build BridgeRecordType with fully-classified fields.
    final results = <BridgeRecordType>[];
    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! ClassElement) continue;

      final fields = cls.fields
          .where((f) => !f.isStatic && !f.isSynthetic)
          .map((f) {
            final displayType = f.type.getDisplayString(withNullability: true);
            final isNullable = displayType.endsWith('?');
            final kind = _recordFieldKind(f.type, recordTypeNames);
            final itemTypeName = _listItemTypeName(f.type);
            return BridgeRecordField(
              name: f.name,
              dartType: displayType,
              kind: kind,
              itemTypeName: itemTypeName,
              isNullable: isNullable,
            );
          })
          .toList();

      results.add(BridgeRecordType(name: cls.name, fields: fields));
    }
    return results;
  }

  static RecordFieldKind _recordFieldKind(
    DartType type,
    Set<String> recordTypeNames,
  ) {
    if (type is InterfaceType) {
      if (type.element.name == 'List' && type.typeArguments.isNotEmpty) {
        final itemName =
            type.typeArguments.first.getDisplayString(withNullability: false);
        return recordTypeNames.contains(itemName)
            ? RecordFieldKind.listRecordObject
            : RecordFieldKind.listPrimitive;
      }
      if (recordTypeNames.contains(type.element.name)) {
        return RecordFieldKind.recordObject;
      }
    }
    return RecordFieldKind.primitive;
  }

  static String? _listItemTypeName(DartType type) {
    if (type is InterfaceType &&
        type.element.name == 'List' &&
        type.typeArguments.isNotEmpty) {
      return type.typeArguments.first.getDisplayString(withNullability: false);
    }
    return null;
  }

  static const _primitiveNames = {
    'int', 'double', 'bool', 'String',
    'Uint8List', 'Int8List', 'Int16List', 'Int32List',
    'Uint16List', 'Uint32List', 'Float32List', 'Float64List',
    'Int64List', 'Uint64List',
  };

  /// Converts a [DartType] to a [BridgeType], marking JSON-bridged types:
  /// - `@HybridRecord` class  → `isRecord: true`
  /// - `List<@HybridRecord T>` → `isRecord: true, recordListItemType: T`
  /// - `List<primitive T>`    → `isRecord: true, recordListItemType: T, recordListItemIsPrimitive: true`
  /// - `Map<String, T>`       → `isRecord: true, isMap: true`
  static BridgeType _makeBridgeType(
    DartType type,
    Set<String> recordTypeNames, {
    bool isFuture = false,
  }) {
    final displayName = type.getDisplayString(withNullability: true);

    if (type is InterfaceType) {
      final elName = type.element.name;

      // List<T> — record or primitive items
      if (elName == 'List' && type.typeArguments.isNotEmpty) {
        final itemType = type.typeArguments.first;
        final itemName = itemType.getDisplayString(withNullability: false);
        if (recordTypeNames.contains(itemName)) {
          return BridgeType(
            name: displayName,
            isRecord: true,
            recordListItemType: itemName,
            isFuture: isFuture,
          );
        }
        if (_primitiveNames.contains(itemName)) {
          return BridgeType(
            name: displayName,
            isRecord: true,
            recordListItemType: itemName,
            recordListItemIsPrimitive: true,
            isFuture: isFuture,
          );
        }
      }

      // Map<String, T> — JSON object bridge
      if (elName == 'Map' &&
          type.typeArguments.length == 2 &&
          type.typeArguments.first.getDisplayString(withNullability: false) ==
              'String') {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isMap: true,
          isFuture: isFuture,
        );
      }

      // Direct @HybridRecord class
      if (recordTypeNames.contains(elName)) {
        return BridgeType(name: displayName, isRecord: true, isFuture: isFuture);
      }
    }

    return BridgeType(name: displayName, isFuture: isFuture);
  }

  // ─── Functions ───────────────────────────────────────────────────────────────

  static List<BridgeFunction> _extractFunctions(
    ClassElement element,
    String ns,
    Set<String> recordTypeNames,
  ) {
    const asyncChecker = TypeChecker.fromUrl(
      'package:nitro/src/annotations.dart#NitroAsync',
    );
    const zeroCopyChecker = TypeChecker.fromUrl(
      'package:nitro/src/annotations.dart#ZeroCopy',
    );

    // Skip abstract getters annotated with @NitroStream or abstract getters/setters
    return element.methods.where((m) => m.isAbstract).map((m) {
      final isAsync = asyncChecker.hasAnnotationOf(m);

      DartType returnDartType = m.returnType;
      if (isAsync && returnDartType.isDartAsyncFuture) {
        final it = returnDartType as InterfaceType;
        if (it.typeArguments.isNotEmpty) returnDartType = it.typeArguments.first;
      }

      return BridgeFunction(
        dartName: m.name,
        cSymbol: '${ns}_${_toSnakeCase(m.name)}',
        isAsync: isAsync,
        returnType: _makeBridgeType(
          returnDartType,
          recordTypeNames,
          isFuture: isAsync,
        ),
        params: m.parameters.map((p) {
          return BridgeParam(
            name: p.name,
            type: _makeBridgeType(p.type, recordTypeNames),
            zeroCopy: zeroCopyChecker.hasAnnotationOf(p),
          );
        }).toList(),
      );
    }).toList();
  }

  // ─── Properties ──────────────────────────────────────────────────────────────

  static List<BridgeProperty> _extractProperties(
    ClassElement element,
    String ns,
    Set<String> recordTypeNames,
  ) {
    // Group accessors by name, storing the DartType for later classification.
    final map = <String, Map<String, dynamic>>{};

    for (final ac in element.accessors) {
      if (!ac.isAbstract) {
        continue;
      }
      final name = ac.displayName.replaceFirst('=', '');
      final entry = map.putIfAbsent(
        name,
        () => {'name': name, 'getter': false, 'setter': false},
      );

      if (ac.isGetter) {
        final type = ac.returnType;
        if (type.isDartCoreFunction || _isStreamType(type)) continue;
        entry['getter'] = true;
        entry['dartType'] = type;
      } else {
        final type = ac.parameters.first.type;
        if (type.isDartCoreFunction || _isStreamType(type)) continue;
        entry['setter'] = true;
        entry['dartType'] ??= type;
      }
    }

    return map.values.where((e) => e['dartType'] != null).map((e) {
      final name = e['name'] as String;
      final dartType = e['dartType'] as DartType;
      return BridgeProperty(
        dartName: name,
        type: _makeBridgeType(dartType, recordTypeNames),
        getSymbol: '${ns}_get_${_toSnakeCase(name)}',
        setSymbol: '${ns}_set_${_toSnakeCase(name)}',
        hasGetter: e['getter'] as bool,
        hasSetter: e['setter'] as bool,
      );
    }).toList();
  }

  // ─── Streams ─────────────────────────────────────────────────────────────────

  static List<BridgeStream> _extractStreams(
    ClassElement element,
    String ns,
    Set<String> recordTypeNames,
  ) {
    const streamChecker = TypeChecker.fromUrl(
      'package:nitro/src/annotations.dart#NitroStream',
    );
    final results = <BridgeStream>[];

    for (final accessor in element.accessors) {
      if (!accessor.isAbstract || !accessor.isGetter) {
        continue;
      }
      final retType = accessor.returnType;
      if (!_isStreamType(retType)) {
        continue;
      }

      // Get item type T from Stream<T>
      final streamType = retType as InterfaceType;
      final itemDartType = streamType.typeArguments.isNotEmpty
          ? streamType.typeArguments.first
          : null;

      // Read backpressure from @NitroStream annotation, default dropLatest
      Backpressure backpressure = Backpressure.dropLatest;
      final ann = streamChecker.firstAnnotationOf(accessor);
      if (ann != null) {
        final bpField = ann.getField('backpressure');
        final bpIndex = bpField?.getField('index')?.toIntValue() ?? 0;
        backpressure = Backpressure.values[bpIndex];
      }

      final name = accessor.displayName;
      final bridgeItemType = itemDartType != null
          ? _makeBridgeType(itemDartType, recordTypeNames)
          : BridgeType(name: 'dynamic');

      results.add(
        BridgeStream(
          dartName: name,
          registerSymbol: '${ns}_register_${_toSnakeCase(name)}_stream',
          releaseSymbol: '${ns}_release_${_toSnakeCase(name)}_stream',
          itemType: bridgeItemType,
          backpressure: backpressure,
        ),
      );
    }

    return results;
  }

  static bool _isStreamType(DartType type) {
    if (type is InterfaceType) {
      return type.element.name == 'Stream';
    }
    return false;
  }

  // ─── Structs ─────────────────────────────────────────────────────────────────

  static List<BridgeStruct> _extractStructs(LibraryReader library) {
    const checker = TypeChecker.fromRuntime(HybridStruct);
    final results = <BridgeStruct>[];

    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! ClassElement) {
        continue;
      }

      final packed =
          ann.annotation.read('packed').literalValue as bool? ?? false;
      final zeroCopyFields = ann.annotation
          .read('zeroCopy')
          .listValue
          .map((v) => v.toStringValue() ?? '')
          .toSet();

      final fields = cls.fields
          .where((f) => !f.isStatic && !f.isSynthetic)
          .map(
            (f) => BridgeField(
              name: f.name,
              type: BridgeType(
                name: f.type.getDisplayString(withNullability: true),
              ),
              zeroCopy: zeroCopyFields.contains(f.name),
            ),
          )
          .toList();

      results.add(BridgeStruct(name: cls.name, packed: packed, fields: fields));
    }
    return results;
  }

  // ─── Enums ───────────────────────────────────────────────────────────────────

  static List<BridgeEnum> _extractEnums(LibraryReader library) {
    const checker = TypeChecker.fromRuntime(HybridEnum);
    final results = <BridgeEnum>[];

    for (final ann in library.annotatedWith(checker)) {
      final cls = ann.element;
      if (cls is! EnumElement) {
        continue;
      }

      final startValue =
          ann.annotation.read('startValue').literalValue as int? ?? 0;

      results.add(
        BridgeEnum(
          name: cls.name,
          startValue: startValue,
          values: cls.fields
              .where((f) => f.isEnumConstant)
              .map((f) => f.name)
              .toList(),
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
