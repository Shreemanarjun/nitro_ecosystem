import 'package:nitro_annotations/nitro_annotations.dart';

/// Discriminated kind for a [BridgeType], derived from its boolean flags.
///
/// Use `BridgeType.kind` in switch statements instead of chaining `isRecord &&
/// recordListItemType != null && ...`. Adding a new kind here forces a single
/// `case` in each generator switch, eliminating silent fall-throughs.
enum BridgeTypeKind {
  primitive,      // int, double, bool, String, void
  enumValue,      // @HybridEnum
  struct_,        // @HybridStruct (FFI memory layout)
  record,         // @HybridRecord (binary codec, single instance)
  recordList,     // List<@HybridRecord>
  primitiveList,  // List<int|double|bool|String>
  enumList,       // List<@HybridEnum> — [4B len][4B count][8B×N nativeValues]
  variantList,    // List<@NitroVariant> — [4B len][4B count][sequential tag+fields]
  typedData,      // Uint8List, Float64List, etc.
  map,            // Map<String, T>
  anyMap,         // NitroAnyMap — heterogeneous typed map (RN Nitro AnyMap equiv.)
  function_,      // T Function(...) — callback
  nativeHandle,      // NativeHandle<T> — opaque raw pointer
  pointer,           // Pointer<T> — explicit FFI pointer
  stream,            // Stream<T>
  future,            // Future<T>
  variant,           // @NitroVariant sealed class
  anyNativeObject,   // AnyNativeObject — opaque int64_t instance ID (RN Nitro AnyHybridObject)
  customType,        // @NitroCustomType — user-codec uint8_t* type (RN Nitro CustomType<T>)
  tuple,             // @NitroTuple positional record — Dart 3 (A, B, C) — same wire as @HybridRecord
}

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
  final List<BridgeVariant> variants;
  final List<BridgeCustomType> customTypes;

  /// True when this spec was extracted from a type-only `.native.dart` file
  /// (no `@NitroModule` annotation). Generators emit only type declarations,
  /// no bridge scaffolding (no `_Impl` class, no FFI method pointers).
  final bool isTypeOnly;

  /// Relative C++ `#include` paths for types imported from other `.native.dart`
  /// files. The C++ generators emit `#include "<path>"` for each entry so that
  /// shared types are not re-declared in every bridge header.
  final List<String> importedTypeFiles;

  /// Types defined in THIS file (not imported from another `.native.dart`).
  /// Use for type DECLARATION in generators — imported types must not be
  /// redeclared because they already appear in their own bridge file.
  List<BridgeEnum> get localEnums => enums.where((e) => !e.isImported).toList();
  List<BridgeStruct> get localStructs => structs.where((s) => !s.isImported).toList();
  List<BridgeRecordType> get localRecordTypes => recordTypes.where((r) => !r.isImported).toList();
  List<BridgeVariant> get localVariants => variants.where((v) => !v.isImported).toList();

  // ── O(1) type index — lazy, cached ─────────────────────────────────────────
  // Generators historically use `spec.enums.any(e => e.name == name)` in tight
  // loops — O(n) per lookup, O(m×n) total. These lazily-built maps provide
  // O(1) lookup and are computed at most once per BridgeSpec instance.
  late final Map<String, BridgeEnum>       _enumIndex       = { for (final e in enums)       e.name: e };
  late final Map<String, BridgeStruct>     _structIndex     = { for (final s in structs)     s.name: s };
  late final Map<String, BridgeRecordType> _recordIndex     = { for (final r in recordTypes) r.name: r };
  late final Map<String, BridgeVariant>    _variantIndex    = { for (final v in variants)    v.name: v };
  late final Map<String, BridgeCustomType> _customTypeIndex = { for (final c in customTypes) c.name: c };

  BridgeEnum?       enumByName(String n)       => _enumIndex[n];
  BridgeStruct?     structByName(String n)     => _structIndex[n];
  BridgeRecordType? recordByName(String n)     => _recordIndex[n];
  BridgeVariant?    variantByName(String n)    => _variantIndex[n];
  BridgeCustomType? customTypeByName(String n) => _customTypeIndex[n];

  bool isEnumName(String n)       => _enumIndex.containsKey(n);
  bool isStructName(String n)     => _structIndex.containsKey(n);
  bool isRecordName(String n)     => _recordIndex.containsKey(n);
  bool isVariantName(String n)    => _variantIndex.containsKey(n);
  bool isCustomTypeName(String n) => _customTypeIndex.containsKey(n);

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
    this.variants = const [],
    this.customTypes = const [],
    this.isTypeOnly = false,
    this.importedTypeFiles = const [],
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

  /// True when the type is `List<@HybridEnum>` — encoded as [4B len][4B count][8B×N nativeValues].
  /// [recordListItemType] holds the enum class name.
  final bool isEnumList;

  /// True when the type is `List<@NitroVariant>` — encoded as [4B len][4B count][sequential tag+fields].
  /// [recordListItemType] holds the variant class name.
  final bool isVariantList;

  /// True when the list item type is nullable (e.g. `List<Status?>` or `List<GestureEvent?>`).
  /// Only meaningful when [isEnumList] or [isVariantList] is true.
  /// Nullable items use presence-flag wire format: [1B hasValue][value (if hasValue)].
  final bool recordListItemIsNullable;

  /// True when the type is `Map<String, V>` — bridges as a JSON object string.
  final bool isMap;

  /// True when the type is `NitroAnyMap` — bridges as a type-tagged binary buffer.
  /// Like [isMap] but uses the full [NitroAnyValue] variant codec instead of JSON.
  final bool isAnyMap;

  /// True when this type is a `@NitroTuple` positional record typedef.
  /// Wire format is identical to @HybridRecord (4B length prefix + sequential fields).
  /// Dart type is a positional record `(T1, T2, ...)` accessed via `$1`, `$2`, etc.
  /// [isRecord] is also true for tuples — all existing record guards apply.
  final bool isTuple;

  /// The type name with the nullable `?` suffix stripped.
  /// `'int?'.baseName == 'int'`, `'String'.baseName == 'String'`.
  /// Always strips a trailing `?` regardless of the [isNullable] field —
  /// this ensures correct behaviour for BridgeType instances created in tests
  /// where [isNullable] may default to `false` even when the name ends with `?`.
  String get baseName => name.endsWith('?') ? name.substring(0, name.length - 1) : name;

  /// Discriminated kind — use in switch instead of chained boolean checks.
  ///
  /// Derived purely from the existing flag fields so no existing code breaks.
  /// Enum/struct membership must be checked by the caller against the spec's
  /// name sets (BridgeType itself has no access to the spec).
  /// For enum/struct disambiguation, see [KotlinTypeMapper.type] and [SwiftTypeMapper.swiftType].
  BridgeTypeKind get kind {
    if (isAnyNativeObject)    return BridgeTypeKind.anyNativeObject;
    if (isNativeHandle)       return BridgeTypeKind.nativeHandle;
    if (isPointer)            return BridgeTypeKind.pointer;
    if (isFunction)           return BridgeTypeKind.function_;
    if (isStream)             return BridgeTypeKind.stream;
    if (isFuture)             return BridgeTypeKind.future;
    if (isAnyMap)             return BridgeTypeKind.anyMap;
    if (isMap)                return BridgeTypeKind.map;
    if (isTuple)              return BridgeTypeKind.tuple;
    if (isRecord) {
      if (isEnumList)    return BridgeTypeKind.enumList;
      if (isVariantList) return BridgeTypeKind.variantList;
      if (recordListItemType != null) {
        return recordListItemIsPrimitive
            ? BridgeTypeKind.primitiveList
            : BridgeTypeKind.recordList;
      }
      return BridgeTypeKind.record;
    }
    if (isTypedData)          return BridgeTypeKind.typedData;
    return BridgeTypeKind.primitive; // int, double, bool, String, void — NOT enum/struct
  }

  /// Like [kind] but resolves `primitive` into [BridgeTypeKind.enumValue] or
  /// [BridgeTypeKind.struct_] when the type name is registered in [spec].
  ///
  /// Requires a [BridgeSpec] because enum/struct membership is a spec-level
  /// concept — the type name alone is ambiguous (could be an external class).
  BridgeTypeKind resolvedKind(BridgeSpec spec) {
    final k = kind;
    if (k != BridgeTypeKind.primitive) return k;
    final bare = name.endsWith('?') ? name.substring(0, name.length - 1) : name;
    if (spec.isEnumName(bare))       return BridgeTypeKind.enumValue;
    if (spec.isStructName(bare))     return BridgeTypeKind.struct_;
    if (spec.isVariantName(bare))    return BridgeTypeKind.variant;
    if (spec.isCustomTypeName(bare)) return BridgeTypeKind.customType;
    return BridgeTypeKind.primitive;
  }

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

  /// True when this type is a function type (callback).
  /// E.g., `void Function(TorchState)` or `Future<void> Function(int)`.
  final bool isFunction;

  /// Return type name for function types (null if not a function).
  final String? functionReturnType;

  /// Parameter types for function types (empty list if not a function).
  final List<BridgeType> functionParams;

  /// True when this type is `NativeHandle<T>` — a raw opaque pointer that
  /// crosses the bridge with zero codec overhead.
  final bool isNativeHandle;

  /// The type parameter T in `NativeHandle<T>` (e.g. 'Void', 'CameraFrame').
  /// Used for documentation only; the wire format is always `void*` / `Long`.
  final String? nativeHandleTypeParam;

  /// True when this type is `AnyNativeObject` — an opaque `int64_t` instance ID
  /// referencing any registered native implementation. RN Nitro equivalent:
  /// `AnyHybridObject`. Wire: same as `int64_t`; nullable uses `-1` as null sentinel.
  final bool isAnyNativeObject;

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
    this.isEnumList = false,
    this.isVariantList = false,
    this.recordListItemIsNullable = false,
    this.isMap = false,
    this.isAnyMap = false,
    this.isTuple = false,
    this.isFunction = false,
    this.functionReturnType,
    this.functionParams = const [],
    this.isNativeHandle = false,
    this.nativeHandleTypeParam,
    this.isAnyNativeObject = false,
  });
}

/// A user-defined type registered with [@NitroCustomType] and encoded via a
/// [NitroFfiCodec] subclass. The generator emits `const [codecClass]().encode()`
/// / `.decode()` on the Dart side; native sides see raw `ByteArray` /
/// `UnsafePointer<UInt8>?` / `uint8_t*`.
class BridgeCustomType {
  /// Dart type name as it appears in the spec file (e.g. `'Color'`).
  final String name;
  /// Name of the [NitroFfiCodec] subclass (e.g. `'ColorCodec'`).
  final String codecClass;
  /// Byte length of the encoded representation — must equal `codec.encodedSize`.
  final int encodedSize;
  /// True when this type was imported from another `.native.dart` file.
  final bool isImported;

  const BridgeCustomType({
    required this.name,
    required this.codecClass,
    required this.encodedSize,
    this.isImported = false,
  });
}

class BridgeStruct {
  final String name;
  final bool packed;
  final List<BridgeField> fields;

  /// True when this struct is defined in another `.native.dart` file.
  /// Generators skip re-declaring it — it appears in the other file's bridge.
  final bool isImported;

  BridgeStruct({
    required this.name,
    required this.packed,
    required this.fields,
    this.isImported = false,
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

  /// Optional explicit native integer values for each enum case.
  /// When set, `rawValues[i]` is the wire value for `values[i]` — allows
  /// non-contiguous mappings (e.g. OS enums with gaps like 0, 50, 100).
  /// When null, values are contiguous starting at [startValue].
  final List<int>? rawValues;

  /// True when this enum is defined in another `.native.dart` file and imported
  /// into the current module. Generators use [localEnums] to skip re-declaring
  /// imported types — they already appear in the other file's bridge output.
  final bool isImported;

  BridgeEnum({
    required this.name,
    required this.startValue,
    required this.values,
    this.rawValues,
    this.isImported = false,
  }) : assert(rawValues == null || rawValues.length == values.length,
             'rawValues.length must equal values.length');

  /// Returns the native integer value for the enum case at [index].
  int nativeValueAt(int index) {
    if (rawValues != null) return rawValues![index];
    return startValue + index;
  }
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

  /// True when the method is annotated with @ZeroCopy and returns TypedData.
  ///
  /// The generated bridge returns a native-backed typed-list view instead of
  /// copying the native buffer into a new Dart list.
  final bool zeroCopyReturn;

  /// 1-based line number of this function in the source .native.dart file.
  /// Populated by the spec extractor; null when constructed manually.
  final int? lineNumber;

  /// True when the function is annotated with @NitroOwned.
  ///
  /// Only valid when [returnType.isNativeHandle] is true. The generator
  /// emits a `NativeFinalizer` that calls `${cSymbol}_release(void*)` when
  /// the returned [NativeHandle] is garbage-collected.
  final bool isOwned;

  /// Optional timeout in milliseconds from @NitroAsync(timeout: N).
  /// When non-null, the Kotlin/Swift generator wraps the async call in a
  /// timeout block that throws after [asyncTimeout] ms.
  /// Only meaningful when [isAsync] is true.
  final int? asyncTimeout;

  /// True when the method is annotated with `@NitroResult()`.
  ///
  /// The native implementation can write either a success payload or an error
  /// string. The Dart return type is wrapped in [NitroResultValue<T>] — either
  /// [NitroOk<T>] (success) or [NitroErr] (native-side failure).
  ///
  /// Wire format: `[1B tag: 0=ok, 1=err][payload]`
  final bool isResult;

  BridgeFunction({
    required this.dartName,
    required this.cSymbol,
    required this.isAsync,
    this.isNativeAsync = false,
    required this.returnType,
    required this.params,
    this.zeroCopyReturn = false,
    this.lineNumber,
    this.isOwned = false,
    this.asyncTimeout,
    this.isResult = false,
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

  /// The default value literal to emit verbatim in the generated Dart signature,
  /// e.g. `'5'`, `'true'`, `'Quality.normal'`, `'PrintSettings()'`.
  /// When set, the generator emits `{Type name = defaultLiteral}`.
  /// When null on a non-nullable named param, the generated `{Type name}` is
  /// invalid Dart (Bug 5.1). Use nullable types (`int?`) as the workaround.
  final String? defaultLiteral;

  BridgeParam({
    required this.name,
    required this.type,
    this.zeroCopy = false,
    this.isNamed = false,
    this.isOptional = false,
    this.defaultLiteral,
  });
}

class BridgeStream {
  final String dartName;
  final String registerSymbol;
  final String releaseSymbol;
  final BridgeType itemType;
  final Backpressure backpressure;
  /// Max items per batch when [backpressure] == [Backpressure.batch].
  final int batchMaxSize;
  // true when declared as a method (`Stream<T> name()`), false for a getter.
  final bool isMethodStyle;

  /// True when the stream was explicitly annotated with @NitroStream.
  /// False means default backpressure (dropLatest) was used silently.
  final bool isAnnotated;

  bool get isBatch => backpressure == Backpressure.batch;
  bool get isBufferDrop => backpressure == Backpressure.bufferDrop;
  bool get isBlock => backpressure == Backpressure.block;

  BridgeStream({
    required this.dartName,
    required this.registerSymbol,
    required this.releaseSymbol,
    required this.itemType,
    required this.backpressure,
    this.batchMaxSize = 64,
    this.isMethodStyle = false,
    this.isAnnotated = true,
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
  primitive,       // int, double, bool, String (and nullable variants)
  enumValue,       // @HybridEnum serialized as its native int value
  recordObject,    // another @HybridRecord type
  listPrimitive,   // List<primitive>
  listEnumValue,   // List<@HybridEnum>
  listRecordObject, // List<@HybridRecord type>
  typedData,       // Uint8List, Int8List, Int16List, Int32List, Int64List, Float32List, Float64List
                   // Wire: [4B element_count][element_bytes] — same as writeBlob/readBlob
  struct,          // @HybridStruct embedded inline — each field written as primitives
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

  /// True when this record type is defined in another `.native.dart` file.
  /// Generators skip re-declaring it — it appears in the other file's bridge.
  final bool isImported;

  /// True when this is a `@NitroTuple` positional record typedef.
  /// Fields are named `field0`, `field1`, ... (positional, not semantic).
  /// Dart encode/decode uses standalone free functions (not extension methods)
  /// since Dart typedefs cannot have extension methods.
  final bool isTuple;

  BridgeRecordType({required this.name, required this.fields, this.isImported = false, this.isTuple = false});
}

// ── @NitroVariant ─────────────────────────────────────────────────────────────

/// One concrete case of a [@NitroVariant] sealed class.
///
/// [name] is the Dart class name (e.g. `FilterAccepted`).
/// [label] is the camelCase case identifier for Kotlin `sealed class` /
///   Swift `enum` (e.g. `accepted`).
/// [fields] are the fields of the case class — empty for unit cases.
class BridgeVariantCase {
  final String name;
  final String label;
  final List<BridgeRecordField> fields;

  BridgeVariantCase({required this.name, required this.label, required this.fields});

  bool get isUnit => fields.isEmpty;
}

/// IR model for a `@NitroVariant`-annotated sealed class.
///
/// Wire format: `[1B tag 0..N] [optional payload — record codec]`
/// The case at index 0 has tag 0, index 1 has tag 1, etc.
class BridgeVariant {
  final String name;
  final List<BridgeVariantCase> cases;
  final bool isImported;

  BridgeVariant({required this.name, required this.cases, this.isImported = false});

  List<BridgeVariant> get localVariants => isImported ? [] : [this];
}
