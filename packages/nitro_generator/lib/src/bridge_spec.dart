import 'package:nitro_annotations/nitro_annotations.dart';

class BridgeSpec {
  final String dartClassName;
  final String lib;
  final String namespace;
  final NativeImpl iosImpl;
  final NativeImpl androidImpl;
  final String sourceUri;

  /// True when both platforms use a direct C++ implementation (no JNI / Swift bridge).
  bool get isCppImpl => iosImpl == NativeImpl.cpp && androidImpl == NativeImpl.cpp;

  final List<BridgeStruct> structs;
  final List<BridgeEnum> enums;
  final List<BridgeFunction> functions;
  final List<BridgeStream> streams;
  final List<BridgeProperty> properties;
  final List<BridgeRecordType> recordTypes;

  BridgeSpec({
    required this.dartClassName,
    required this.lib,
    required this.namespace,
    required this.iosImpl,
    required this.androidImpl,
    required this.sourceUri,
    this.structs = const [],
    this.enums = const [],
    this.functions = const [],
    this.streams = const [],
    this.properties = const [],
    this.recordTypes = const [],
  });
}

class BridgeType {
  final String name;
  final bool isNullable;
  final bool isFuture;
  final bool isStream;

  /// True when this type requires UTF-8 JSON bridging.
  /// Covers: `@HybridRecord` classes, `List<T>` (primitives or `@HybridRecord`),
  /// and `Map<String, T>`.
  final bool isRecord;

  /// True when the type is a raw FFI `Pointer<T>`
  final bool isPointer;

  /// The inner type of a `Pointer<T>` (e.g. 'Uint8', 'Void')
  final String? pointerInnerType;

  /// Non-null when [isRecord] is true AND the Dart type is `List<T>`.
  /// Holds the item type name T (e.g. 'CameraDevice', 'String', 'int').
  /// Use [recordListItemIsPrimitive] to distinguish primitive vs. record items.
  final String? recordListItemType;

  /// True when [recordListItemType] is a Dart primitive (int, double, bool,
  /// String) rather than a @HybridRecord class.
  final bool recordListItemIsPrimitive;

  /// True when the type is `Map<String, V>` — bridges as a JSON object string.
  final bool isMap;

  /// True when the type is a Dart TypedData (Uint8List, Float32List, etc.)
  bool get isTypedData =>
      name.startsWith('Uint8List') ||
      name.startsWith('Int8List') ||
      name.startsWith('Int16List') ||
      name.startsWith('Int32List') ||
      name.startsWith('Uint16List') ||
      name.startsWith('Uint32List') ||
      name.startsWith('Float32List') ||
      name.startsWith('Float64List') ||
      name.startsWith('Int64List') ||
      name.startsWith('Uint64List');

  BridgeType({
    required this.name,
    this.isNullable = false,
    this.isFuture = false,
    this.isStream = false,
    this.isRecord = false,
    this.isPointer = false,
    this.pointerInnerType,
    this.recordListItemType,
    this.recordListItemIsPrimitive = false,
    this.isMap = false,
  });
}

class BridgeStruct {
  final String name;
  final bool packed;
  final List<BridgeField> fields;

  BridgeStruct({
    required this.name,
    required this.packed,
    required this.fields,
  });
}

class BridgeField {
  final String name;
  final BridgeType type;
  final bool zeroCopy;

  BridgeField({required this.name, required this.type, this.zeroCopy = false});
}

class BridgeEnum {
  final String name;
  final int startValue;
  final List<String> values;

  BridgeEnum({
    required this.name,
    required this.startValue,
    required this.values,
  });
}

class BridgeFunction {
  final String dartName;
  final String cSymbol;
  final bool isAsync;
  final BridgeType returnType;
  final List<BridgeParam> params;

  BridgeFunction({
    required this.dartName,
    required this.cSymbol,
    required this.isAsync,
    required this.returnType,
    required this.params,
  });
}

class BridgeParam {
  final String name;
  final BridgeType type;
  final bool zeroCopy;

  BridgeParam({required this.name, required this.type, this.zeroCopy = false});
}

class BridgeStream {
  final String dartName;
  final String registerSymbol;
  final String releaseSymbol;
  final BridgeType itemType;
  final Backpressure backpressure;

  BridgeStream({
    required this.dartName,
    required this.registerSymbol,
    required this.releaseSymbol,
    required this.itemType,
    required this.backpressure,
  });
}

class BridgeProperty {
  final String dartName;
  final BridgeType type;
  final String? getSymbol;
  final String? setSymbol;
  final bool hasGetter;
  final bool hasSetter;

  BridgeProperty({
    required this.dartName,
    required this.type,
    this.getSymbol,
    this.setSymbol,
    this.hasGetter = true,
    this.hasSetter = false,
  });
}

// ── @HybridRecord support ─────────────────────────────────────────────────────

/// Describes how a field of a @HybridRecord class maps to/from JSON.
enum RecordFieldKind {
  primitive, // int, double, bool, String (and nullable variants)
  recordObject, // another @HybridRecord type
  listPrimitive, // List<primitive>
  listRecordObject, // List<@HybridRecord type>
}

class BridgeRecordField {
  final String name;

  /// Full Dart type string, e.g. "String?", "`List<Resolution>`", "int".
  final String dartType;

  final RecordFieldKind kind;

  /// For listPrimitive / listRecordObject: the T in `List<T>`.
  final String? itemTypeName;

  final bool isNullable;

  BridgeRecordField({
    required this.name,
    required this.dartType,
    required this.kind,
    this.itemTypeName,
    this.isNullable = false,
  });
}

/// Metadata for a @HybridRecord annotated class, used to generate
/// fromJson / toJson extensions in the .g.dart part file.
class BridgeRecordType {
  final String name;
  final List<BridgeRecordField> fields;

  BridgeRecordType({required this.name, required this.fields});
}
