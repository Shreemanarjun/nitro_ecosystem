import 'package:nitro_annotations/nitro_annotations.dart';

class BridgeSpec {
  final String dartClassName;
  final String lib;
  final String namespace;
  final NativeImpl? iosImpl;
  final NativeImpl? androidImpl;
  final NativeImpl? macosImpl;
  final NativeImpl? windowsImpl;
  final NativeImpl? linuxImpl;
  final NativeImpl? webImpl;
  final String sourceUri;

  /// True when iOS is a targeted platform.
  bool get targetsIos => iosImpl != null;

  /// True when Android is a targeted platform.
  bool get targetsAndroid => androidImpl != null;

  /// True when macOS is a targeted platform.
  bool get targetsMacos => macosImpl != null;

  /// True when Windows is a targeted platform.
  bool get targetsWindows => windowsImpl != null;

  /// True when Linux is a targeted platform.
  bool get targetsLinux => linuxImpl != null;

  /// True when Web is a targeted platform.
  bool get targetsWeb => webImpl != null;

  /// True when the iOS platform uses a direct C++ implementation.
  bool get iosIsCpp => iosImpl is CppImpl;

  /// True when the macOS platform uses a direct C++ implementation.
  bool get macosIsCpp => macosImpl is CppImpl;

  /// True when any Apple platform (iOS and/or macOS) is targeted with C++.
  bool get targetsAppleCpp => (iosImpl is CppImpl || macosImpl is CppImpl);

  /// True when any desktop C++ platform (Windows and/or Linux) is targeted.
  bool get targetsDesktopCpp => (windowsImpl is CppImpl || linuxImpl is CppImpl);

  /// True when at least one native platform uses direct C++ (no JNI / Swift
  /// bridge). Web is intentionally excluded — it is never a dart:ffi target.
  ///
  /// Use this to decide whether to emit C++ headers / mocks that are needed
  /// by any C++ platform target, even in mixed-impl modules (e.g. android=kotlin,
  /// ios=cpp).
  bool get hasCppImpl => iosImpl is CppImpl || androidImpl is CppImpl || macosImpl is CppImpl || windowsImpl is CppImpl || linuxImpl is CppImpl;

  /// True when all targeted native platforms use direct C++ (no JNI / Swift
  /// bridge). Web is intentionally excluded — it is never a dart:ffi target.
  bool get isCppImpl =>
      (iosImpl == null || iosImpl is CppImpl) &&
      (androidImpl == null || androidImpl is CppImpl) &&
      (macosImpl == null || macosImpl is CppImpl) &&
      (windowsImpl == null || windowsImpl is CppImpl) &&
      (linuxImpl == null || linuxImpl is CppImpl) &&
      // webImpl intentionally excluded — web is never a dart:ffi C++ target
      (iosImpl != null || androidImpl != null || macosImpl != null || windowsImpl != null || linuxImpl != null);

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
    this.iosImpl,
    this.androidImpl,
    this.macosImpl,
    this.windowsImpl,
    this.linuxImpl,
    this.webImpl,
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

  /// True when the matching primary-constructor parameter is a **named**
  /// parameter (`{required this.x}` / `{this.x = val}`).
  /// False for positional parameters (`this.x` / `[this.x = val]`).
  ///
  /// Defaults to `true` so manually constructed specs (and all pre-existing
  /// test helpers) keep the named-arg style without any code changes.
  final bool isNamed;

  /// True when the parameter is required — either a positional required param
  /// or a named param with the `required` keyword.
  ///
  /// False for optional parameters (positional `[this.x]` or named `{this.x = val}`).
  final bool isRequired;

  BridgeField({
    required this.name,
    required this.type,
    this.zeroCopy = false,
    this.isNamed = true,
    this.isRequired = true,
  });
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

  /// True when the method is annotated with @NitroNativeAsync.
  ///
  /// Mutually exclusive with [isAsync]: the native side posts the result
  /// directly via Dart_PostCObject_DL — no Dart isolate is ever spawned.
  final bool isNativeAsync;

  final BridgeType returnType;
  final List<BridgeParam> params;

  BridgeFunction({
    required this.dartName,
    required this.cSymbol,
    required this.isAsync,
    this.isNativeAsync = false,
    required this.returnType,
    required this.params,
  });
}

class BridgeParam {
  final String name;
  final BridgeType type;
  final bool zeroCopy;

  /// True when the parameter is a named parameter (`{...}`).
  final bool isNamed;

  /// True when the named parameter is optional (no `required` keyword).
  /// Always false for positional parameters.
  final bool isOptional;

  BridgeParam({
    required this.name,
    required this.type,
    this.zeroCopy = false,
    this.isNamed = false,
    this.isOptional = false,
  });
}

class BridgeStream {
  final String dartName;
  final String registerSymbol;
  final String releaseSymbol;
  final BridgeType itemType;
  final Backpressure backpressure;
  // true when declared as a method (`Stream<T> name()`), false for a getter.
  final bool isMethodStyle;

  BridgeStream({
    required this.dartName,
    required this.registerSymbol,
    required this.releaseSymbol,
    required this.itemType,
    required this.backpressure,
    this.isMethodStyle = false,
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
