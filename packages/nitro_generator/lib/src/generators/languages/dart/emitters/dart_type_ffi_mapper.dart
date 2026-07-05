part of '../dart_ffi_generator.dart';

// ── Library-private FFI helpers ────────────────────────────────────────────
// All functions below were originally static members of DartFfiGenerator.
// They are library-private (`_` prefix) and accessible from all `part` files.

String _paramList(List<BridgeParam> params) {
  final positional = params.where((p) => !p.isNamed).map((p) => '${p.type.name} ${p.name}').join(', ');
  final named = params.where((p) => p.isNamed).toList();
  if (named.isEmpty) return positional;
  final namedStr = named
      .map((p) {
        if (p.defaultLiteral != null) return '${p.type.name} ${p.name} = ${p.defaultLiteral}';
        return '${p.type.name} ${p.name}';
      })
      .join(', ');
  final sep = positional.isEmpty ? '' : ', ';
  return '$positional$sep{$namedStr}';
}

String _cap(String name) => name[0].toUpperCase() + name.substring(1);

String _toNativeType(BridgeFunction func, BridgeSpec spec) {
  // NativeAsync: C function returns void and takes an extra Int64 dart_port.
  // @NitroResult: C function always returns Pointer<Uint8> (tagged buffer).
  // Nullable prims: C returns uint8_t* pointer (malloc'd); Dart receives Pointer<NitroOptXxx>.
  final ret = func.isNativeAsync
      ? 'Void'
      : func.isResult
      ? 'Pointer<Uint8>'
      : _typeToFFI(func.returnType, spec);
  final effectiveRet = func.returnType.isTypedData ? 'Pointer<Uint8>' : ret;
  final params = [
    'Int64', // instanceId (Point 13 per-instance dispatch)
    ...func.params.expand((p) {
      if (p.type.isTypedData) return [_typeToFFI(p.type, spec), 'Size']; // size_t on native side
      return [_typeToFFI(p.type, spec)];
    }),
    if (func.isNativeAsync) 'Int64', // dart_port
    // S8: sync functions receive a NitroError* out-param instead of using
    // the two-call get_error()/clear_error() pattern.
    if (!func.isAsync && !func.isNativeAsync) 'Pointer<NitroErrorFfi>',
  ].join(', ');
  return '$effectiveRet Function($params)';
}

String _toDartType(BridgeFunction func, BridgeSpec spec) {
  // NativeAsync: Dart callable returns void and takes an extra int dart_port.
  // @NitroResult: Dart callable returns Pointer<Uint8> (tagged result buffer).
  // Nullable prims: C returns uint8_t* pointer; Dart receives Pointer<NitroOptXxx>.
  final ret = func.isNativeAsync
      ? 'void'
      : func.isResult
      ? 'Pointer<Uint8>'
      : _typeToDartFFI(func.returnType, spec);
  final effectiveRet = func.returnType.isTypedData ? 'Pointer<Uint8>' : ret;
  final params = [
    'int', // instanceId (Point 13 per-instance dispatch)
    ...func.params.expand((p) {
      if (p.type.isTypedData) return [_typeToDartFFI(p.type, spec), 'int'];
      return [_typeToDartFFI(p.type, spec)];
    }),
    if (func.isNativeAsync) 'int', // dart_port
    // S8: sync functions receive a Pointer<NitroErrorFfi> out-param.
    if (!func.isAsync && !func.isNativeAsync) 'Pointer<NitroErrorFfi>',
  ].join(', ');
  return '$effectiveRet Function($params)';
}

String _typeToFFI(BridgeType bt, BridgeSpec spec) {
  if (bt.isFunction) {
    return 'Pointer<NativeFunction<${_callbackNativeSignature(bt, spec)}>>';
  }
  if (bt.isAnyMap || bt.isRecord) {
    // NitroAnyMap and Maps use binary encoding → same Pointer<Uint8> wire as @HybridRecord.
    return 'Pointer<Uint8>';
  }
  if (bt.isPointer) {
    return 'Pointer<${bt.pointerInnerType}>';
  }
  if (bt.isNativeHandle) return 'Pointer<Void>';
  if (bt.isAnyNativeObject) return 'Int64';
  final name = bt.name.replaceFirst('?', '');
  if (spec.isCustomTypeName(name)) return 'Pointer<Uint8>';
  if (spec.isVariantName(name)) return 'Pointer<Uint8>';
  // Nullable primitives: typed Pointer<NitroOptXxx> (struct layout, full value domain).
  if (bt.name == 'int?') return 'Pointer<NitroOptInt64>';
  if (bt.name == 'double?') return 'Pointer<NitroOptFloat64>';
  if (bt.name == 'bool?') return 'Pointer<NitroOptBool>';
  if (bt.name == 'DateTime?') return 'Pointer<NitroOptInt64>';
  // AnyNativeObject? uses -1 as null sentinel; wire type is still Int64.
  if (bt.name == 'AnyNativeObject?') return 'Int64';
  // uint64? uses the same NitroOptInt64 struct (bits identical, different C signedness).
  if (bt.name == 'uint64?') return 'Pointer<NitroOptInt64>';
  // Narrow integer nullable types reuse NitroOptInt64 (same 9-byte wire layout).
  if (bt.name == 'int8?' || bt.name == 'int16?' || bt.name == 'int32?' || bt.name == 'uint8?' || bt.name == 'uint16?' || bt.name == 'uint32?' || bt.name == 'intptr?' || bt.name == 'size?') {
    return 'Pointer<NitroOptInt64>';
  }
  if (bt.name == 'float?') return 'Pointer<NitroOptFloat64>';
  switch (name) {
    case 'int':
      return 'Int64';
    case 'uint64':
      return 'Uint64';
    case 'DateTime':
      return 'Int64';
    case 'double':
      return 'Double';
    case 'bool':
      return 'Bool'; // dart:ffi Bool ↔ C _Bool; same 1-byte ABI as int8_t on all Nitro targets
    case 'String':
      return 'Pointer<Utf8>';
    case 'Uint8List':
      return 'Pointer<Uint8>';
    case 'Int8List':
      return 'Pointer<Int8>';
    case 'Int16List':
      return 'Pointer<Int16>';
    case 'Int32List':
      return 'Pointer<Int32>';
    case 'Uint16List':
      return 'Pointer<Uint16>';
    case 'Uint32List':
      return 'Pointer<Uint32>';
    case 'Float32List':
      return 'Pointer<Float>';
    case 'Float64List':
      return 'Pointer<Double>';
    case 'Int64List':
      return 'Pointer<Int64>';
    case 'Uint64List':
      return 'Pointer<Uint64>';
    case 'void':
      return 'Void';
    case 'int8':
      return 'Int8';
    case 'int16':
      return 'Int16';
    case 'int32':
      return 'Int32';
    case 'uint8':
      return 'Uint8';
    case 'uint16':
      return 'Uint16';
    case 'uint32':
      return 'Uint32';
    case 'float':
      return 'Float';
    case 'intptr':
      return 'IntPtr';
    case 'size':
      return 'Size';
  }
  if (spec.isEnumName(name)) return 'Int64';
  return 'Pointer<Void>';
}

String _typeToDartFFI(BridgeType bt, BridgeSpec spec) {
  if (bt.isFunction) {
    return 'Pointer<NativeFunction<${_callbackNativeSignature(bt, spec)}>>';
  }
  if (bt.isAnyMap || bt.isRecord) {
    // NitroAnyMap and Maps use binary encoding → same Pointer<Uint8> wire as @HybridRecord.
    return 'Pointer<Uint8>';
  }
  if (bt.isPointer) {
    return 'Pointer<${bt.pointerInnerType}>';
  }
  if (bt.isNativeHandle) return 'Pointer<Void>';
  if (bt.isAnyNativeObject) return 'int';
  final name = bt.name.replaceFirst('?', '');
  if (spec.isCustomTypeName(name)) return 'Pointer<Uint8>';
  if (spec.isVariantName(name)) return 'Pointer<Uint8>';
  // Nullable primitives: typed Pointer<NitroOptXxx> for async/param paths.
  if (bt.name == 'int?') return 'Pointer<NitroOptInt64>';
  if (bt.name == 'double?') return 'Pointer<NitroOptFloat64>';
  if (bt.name == 'bool?') return 'Pointer<NitroOptBool>';
  if (bt.name == 'DateTime?') return 'Pointer<NitroOptInt64>';
  if (bt.name == 'AnyNativeObject?') return 'int';
  if (bt.name == 'uint64?') return 'Pointer<NitroOptInt64>';
  // Narrow integer nullable types reuse NitroOptInt64 (same 9-byte wire layout).
  if (bt.name == 'int8?' || bt.name == 'int16?' || bt.name == 'int32?' || bt.name == 'uint8?' || bt.name == 'uint16?' || bt.name == 'uint32?' || bt.name == 'intptr?' || bt.name == 'size?') {
    return 'Pointer<NitroOptInt64>';
  }
  if (bt.name == 'float?') return 'Pointer<NitroOptFloat64>';
  switch (name) {
    case 'int':
      return 'int';
    case 'uint64':
      return 'int';
    case 'DateTime':
      return 'int';
    case 'double':
      return 'double';
    case 'bool':
      return 'bool'; // Bool FFI type maps to Dart bool directly
    case 'String':
      return 'Pointer<Utf8>';
    case 'Uint8List':
      return 'Pointer<Uint8>';
    case 'Int8List':
      return 'Pointer<Int8>';
    case 'Int16List':
      return 'Pointer<Int16>';
    case 'Int32List':
      return 'Pointer<Int32>';
    case 'Uint16List':
      return 'Pointer<Uint16>';
    case 'Uint32List':
      return 'Pointer<Uint32>';
    case 'Float32List':
      return 'Pointer<Float>';
    case 'Float64List':
      return 'Pointer<Double>';
    case 'Int64List':
      return 'Pointer<Int64>';
    case 'Uint64List':
      return 'Pointer<Uint64>';
    case 'void':
      return 'void';
    case 'int8':
    case 'int16':
    case 'int32':
    case 'uint8':
    case 'uint16':
    case 'uint32':
    case 'intptr':
    case 'size':
      return 'int';
    case 'float':
      return 'double';
  }
  if (spec.isEnumName(name)) return 'int';
  return 'Pointer<Void>';
}

/// Returns true when any function or property uses `Map<String, double>`.
