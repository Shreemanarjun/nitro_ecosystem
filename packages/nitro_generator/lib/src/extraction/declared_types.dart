// ignore_for_file: deprecated_member_use
part of '../spec_extractor.dart';

// The annotated types of a spec file: `@HybridStruct`, `@HybridRecord`,
// `@NitroTuple`, `@NitroVariant`, `@HybridEnum`, `@NitroCustomType`, and how a
// record field is classified.

_ExtractedTypes _extractAnnotatedTypes(LibraryReader library) {
  const recordChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridRecord');
  const structChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridStruct');
  const enumChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#HybridEnum');
  const variantChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroVariant');
  const customTypeChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroCustomType');
  const tupleChecker = TypeChecker.fromUrl('package:nitro_annotations/src/annotations.dart#NitroTuple');

  final recordClasses = <ClassElement>[];
  final structClasses = <({ClassElement cls, ConstantReader annotation})>[];
  final enumClasses = <({EnumElement cls, ConstantReader annotation})>[];
  final variantClasses = <ClassElement>[];
  final customTypeClasses = <({ClassElement cls, ConstantReader annotation})>[];
  final tupleAliases = <TypeAliasElement>[];

  for (final cls in library.classes) {
    if (recordChecker.hasAnnotationOf(cls)) {
      recordClasses.add(cls);
    }

    final structAnnotation = structChecker.firstAnnotationOf(cls);
    if (structAnnotation != null) {
      structClasses.add((cls: cls, annotation: ConstantReader(structAnnotation)));
    }

    if (variantChecker.hasAnnotationOf(cls)) {
      variantClasses.add(cls);
    }

    final customTypeAnnotation = customTypeChecker.firstAnnotationOf(cls);
    if (customTypeAnnotation != null) {
      customTypeClasses.add((cls: cls, annotation: ConstantReader(customTypeAnnotation)));
    }
  }

  for (final cls in library.enums) {
    final enumAnnotation = enumChecker.firstAnnotationOf(cls);
    if (enumAnnotation != null) {
      enumClasses.add((cls: cls, annotation: ConstantReader(enumAnnotation)));
    }
  }

  // L12: scan type aliases for @NitroTuple — `typedef MyPair = (int, String)`
  for (final alias in library.element.typeAliases) {
    if (tupleChecker.hasAnnotationOf(alias)) {
      tupleAliases.add(alias);
    }
  }

  // Include built-in library record types (NitroNullableInt etc.) so that
  // fields whose type is a built-in record get RecordFieldKind.recordObject.
  const builtinLibraryRecordNames = {
    'NitroNullableInt',
    'NitroNullableDouble',
    'NitroNullableBool',
    'NitroOptInt64',
    'NitroOptFloat64',
    'NitroOptBool',
  };
  final recordTypeNames = {...recordClasses.map((c) => c.name!), ...builtinLibraryRecordNames};
  final structTypeNames = structClasses.map((entry) => entry.cls.name!).toSet();
  final enumTypeNames = enumClasses.map((entry) => entry.cls.name!).toSet();

  final tupleRecords = tupleAliases.map((alias) => _buildTupleRecord(alias, recordTypeNames, structTypeNames, enumTypeNames)).toList();
  return _ExtractedTypes(
    records: [
      ...recordClasses.map((cls) => _buildRecordType(cls, recordTypeNames, structTypeNames, enumTypeNames)),
      ...tupleRecords,
    ],
    structs: structClasses.map((entry) => _buildStruct(entry.cls, entry.annotation)).toList(),
    enums: enumClasses.map((entry) => _buildEnum(entry.cls, entry.annotation)).toList(),
    variants: variantClasses.map((cls) => _buildVariant(cls, library, recordTypeNames, structTypeNames, enumTypeNames)).toList(),
    customTypes: customTypeClasses.map((entry) {
      final codecType = entry.annotation.read('codec').typeValue;
      final codecClass = codecType.element!.name!;
      final encodedSize = entry.annotation.read('encodedSize').intValue;
      return BridgeCustomType(
        name: entry.cls.name!,
        codecClass: codecClass,
        encodedSize: encodedSize,
      );
    }).toList(),
  );
}

/// Builds a [BridgeVariant] from a `@NitroVariant`-annotated sealed class.
///
/// Discovers concrete subclasses within the same library by scanning all
/// classes whose direct supertype matches [variantClass].
BridgeVariant _buildVariant(
  ClassElement variantClass,
  LibraryReader library,
  Set<String> recordTypeNames,
  Set<String> structTypeNames,
  Set<String> enumTypeNames,
) {
  final parentName = variantClass.name!;

  // Collect all concrete (non-abstract, non-sealed) subclasses in the same library.
  final caseClasses = library.classes.where((cls) => !cls.isAbstract && cls.supertype?.element.name == parentName).toList();

  final cases = <BridgeVariantCase>[];
  for (final cls in caseClasses) {
    final fields = cls.fields.where((f) => !f.isStatic && f.isOriginDeclaration).map((f) {
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

    // label: 'FilterAccepted' → 'filterAccepted' (lowerCamelCase, strip parent prefix)
    final rawName = cls.name!;
    final stripped = rawName.startsWith(parentName) ? rawName.substring(parentName.length) : rawName;
    final label = stripped.isEmpty ? rawName[0].toLowerCase() + rawName.substring(1) : stripped[0].toLowerCase() + stripped.substring(1);

    cases.add(BridgeVariantCase(name: rawName, label: label, fields: fields));
  }

  return BridgeVariant(name: parentName, cases: cases);
}

BridgeRecordType _buildRecordType(
  ClassElement cls,
  Set<String> recordTypeNames,
  Set<String> structTypeNames,
  Set<String> enumTypeNames,
) {
  final fields = cls.fields.where((f) => !f.isStatic && f.isOriginDeclaration).map((f) {
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
}

/// Builds a [BridgeRecordType] with `isTuple: true` from a `@NitroTuple`-annotated
/// type alias. The aliased type must be a Dart 3 positional record `(A, B, ...)`.
/// Fields are named `field0`, `field1`, etc., matching the generator convention.
BridgeRecordType _buildTupleRecord(
  TypeAliasElement alias,
  Set<String> recordTypeNames,
  Set<String> structTypeNames,
  Set<String> enumTypeNames,
) {
  final aliasedType = alias.aliasedType;
  if (aliasedType is! RecordType) {
    throw SpecParseException(
      '@NitroTuple requires a positional record typedef, '
      'e.g. `typedef ${alias.name} = (int, String)`. '
      'Got: ${aliasedType.getDisplayString()}.',
    );
  }
  final fields = <BridgeRecordField>[];
  for (var i = 0; i < aliasedType.positionalFields.length; i++) {
    final fieldType = aliasedType.positionalFields[i].type;
    final isNullable = fieldType.nullabilitySuffix == NullabilitySuffix.question;
    fields.add(
      BridgeRecordField(
        name: 'field$i',
        dartType: fieldType.getDisplayString(),
        kind: _recordFieldKind(fieldType, recordTypeNames, structTypeNames, enumTypeNames),
        isNullable: isNullable,
      ),
    );
  }
  return BridgeRecordType(name: alias.name!, isTuple: true, fields: fields);
}

RecordFieldKind _recordFieldKind(
  DartType type,
  Set<String> recordTypeNames, [
  Set<String> structTypeNames = const {},
  Set<String> enumTypeNames = const {},
]) {
  if (type is InterfaceType) {
    // Name sets cover this file's types; the annotation check covers types
    // imported from another .native.dart (shared type files, other modules).
    bool isA(DartType t, Set<String> names, String annotation) =>
        names.contains(t.getDisplayString(withNullability: false)) ||
        (t.element != null && _hasAnnotation(t.element!, annotation));
    if (type.element.name == 'List' && type.typeArguments.isNotEmpty) {
      final item = type.typeArguments.first;
      if (isA(item, recordTypeNames, 'HybridRecord') || isA(item, structTypeNames, 'HybridStruct')) {
        return RecordFieldKind.listRecordObject;
      }
      if (isA(item, enumTypeNames, 'HybridEnum')) {
        return RecordFieldKind.listEnumValue;
      }
      return RecordFieldKind.listPrimitive;
    }
    if (isA(type, recordTypeNames, 'HybridRecord')) {
      return RecordFieldKind.recordObject;
    }
    // @HybridStruct embedded inline in a @HybridRecord — each field written as primitives.
    if (isA(type, structTypeNames, 'HybridStruct')) {
      return RecordFieldKind.struct;
    }
    if (isA(type, enumTypeNames, 'HybridEnum')) {
      return RecordFieldKind.enumValue;
    }
    // TypedData — binary blob encoding: [4B element_count][element_bytes]
    const typedDataNames = {
      'Uint8List',
      'Int8List',
      'Int16List',
      'Uint16List',
      'Int32List',
      'Uint32List',
      'Float32List',
      'Int64List',
      'Uint64List',
      'Float64List',
    };
    if (typedDataNames.contains(type.element.name)) {
      return RecordFieldKind.typedData;
    }
  }
  return RecordFieldKind.primitive;
}

String? _listItemTypeName(DartType type) {
  if (type is InterfaceType && type.element.name == 'List' && type.typeArguments.isNotEmpty) {
    return type.typeArguments.first.getDisplayString(withNullability: false);
  }
  return null;
}

BridgeStruct _buildStruct(ClassElement cls, ConstantReader annotation) {
  final packed = annotation.read('packed').literalValue as bool? ?? false;
  final zeroCopyFields = annotation.read('zeroCopy').listValue.map((v) => v.toStringValue() ?? '').toSet();

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

  final fields = cls.fields.where((f) => !f.isStatic && f.isOriginDeclaration).map(
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

  return BridgeStruct(name: cls.name!, packed: packed, fields: fields);
}

BridgeEnum _buildEnum(EnumElement cls, ConstantReader annotation) {
  final startValue = annotation.read('startValue').literalValue as int? ?? 0;
  final enumValues = cls.fields.where((f) => f.isEnumConstant).map((f) => f.name!).toList();

  // Read optional nativeValues list from @HybridEnum(nativeValues: [0, 50, 100]).
  List<int>? rawValues;
  try {
    final nativeValuesReader = annotation.read('nativeValues');
    if (!nativeValuesReader.isNull) {
      final list = nativeValuesReader.listValue;
      rawValues = list.map((e) => e.toIntValue() ?? 0).toList();
    }
  } on ArgumentError {
    // nativeValues field absent in older annotations — fall back to startValue.
  } on StateError {
    // nativeValues field absent in older annotations — fall back to startValue.
  }

  return BridgeEnum(
    name: cls.name!,
    startValue: startValue,
    values: enumValues,
    rawValues: rawValues,
  );
}
