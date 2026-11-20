part of '../swift_function_emitter.dart';

// Return values every dispatch mode shares: map blocks, @NitroResult blobs,
// record lists and typed-data copies.

/// Swift expression for the `[4B len][payload]` block of [value], the map or
/// any-map [func] returns; nil for a nil map.
String _mapBlock(BridgeFunction func, BridgeSpec spec, String value) {
  final t = func.returnType;
  String encode(String v) => t.isAnyMap ? '_nitroEncodeAnyMapBinary($v)' : SwiftMapEmitter.encodeExpr(t, spec, v);
  return t.isNullable || t.name.endsWith('?') ? '$value.flatMap { m in ${encode('m')} }' : encode(value);
}

/// Emits the statements that turn [value], the ok value of a `@NitroResult`
/// method, into its result blob and return it. [indent] is the indentation
/// of the block they go into.
void _emitResultOk(CodeWriter writer, BridgeFunction func, BridgeSpec spec, String value, String indent) {
  switch (spec.resultCarrier(func)) {
    case ScalarCarrier(:final kind):
      final encode = switch (kind) {
        ScalarKind.int64 => '_nitroEncodeResultInt64($value)',
        ScalarKind.float64 => '_nitroEncodeResultFloat64($value)',
        ScalarKind.boolean => '_nitroEncodeResultBool($value)',
        ScalarKind.string => '_nitroEncodeResultString($value)',
        // `enum X: Int64` does not convert to Int64 on its own.
        ScalarKind.enumValue => '_nitroEncodeResultInt64($value.rawValue)',
      };
      writer.line('${indent}return $encode');
    // A @HybridRecord or @NitroVariant through the record codec. (A type the
    // validator rejects falls here too, as it always did.)
    case RecordCarrier() || NoCarrier():
      writer.line('${indent}return _nitroEncodeResultRecord($value)');
    // A value with no encoding of its own travels as a one-field record.
    case WrappedCarrier(:final wrapper, :final wire):
      final isNullable = wrapper.fields.single.isNullable;
      // Date and UInt64 cross as an int64, as on every other path.
      final field = switch (wire) {
        WrappedWire.asIs => value,
        WrappedWire.dateTime when isNullable => '$value.map { Int64((\$0.timeIntervalSince1970 * 1000).rounded()) }',
        WrappedWire.dateTime => 'Int64(($value.timeIntervalSince1970 * 1000).rounded())',
        WrappedWire.uint64 when isNullable => '$value.map { Int64(bitPattern: \$0) }',
        WrappedWire.uint64 => 'Int64(bitPattern: $value)',
      };
      writer.line('${indent}return _nitroEncodeResultRecord(${wrapper.name}(value: $field))');
    // The value's usual block behind the tag. Tag 2: ok, and it is nil.
    case BlockCarrier(:final kind, :final isNullable):
      if (isNullable) {
        writer.line('${indent}guard let result = $value else { return _nitroWriteResultTag(2, nil) }');
      } else if (value != 'result') {
        writer.line('${indent}let result = $value');
      }
      final blob = switch (kind) {
        BlockKind.map => SwiftMapEmitter.encodeExpr(func.returnType, spec, 'result'),
        BlockKind.anyMap => '_nitroEncodeAnyMapBinary(result)',
        BlockKind.variantList =>
          'NitroRecordWriter.${func.returnType.recordListItemIsNullable ? 'encodeNullableList' : 'encodeList'}(result) { w, e in e.writeFields(to: w) }',
        BlockKind.variant => 'result.toNative()',
      };
      writer.line('${indent}return _nitroWriteResultTag(0, $blob)');
  }
}

void _emitRecordListEncode(CodeWriter writer, BridgeType returnType) {
  // List<@HybridEnum> / List<@HybridEnum?>
  if (returnType.isEnumList) {
    if (returnType.recordListItemIsNullable) {
      writer.line('    return NitroRecordWriter.encodeNullableList(r) { w, e in w.writeInt(Int64(e.rawValue)) }.map { UnsafeMutableRawPointer(\$0) }');
    } else {
      writer.line('    return NitroRecordWriter.encodeList(r) { w, e in w.writeInt(Int64(e.rawValue)) }.map { UnsafeMutableRawPointer(\$0) }');
    }
    return;
  }
  // List<@NitroVariant> / List<@NitroVariant?>
  if (returnType.isVariantList) {
    if (returnType.recordListItemIsNullable) {
      writer.line('    return NitroRecordWriter.encodeNullableList(r) { w, e in e.writeFields(to: w) }.map { UnsafeMutableRawPointer(\$0) }');
    } else {
      writer.line('    return NitroRecordWriter.encodeList(r) { w, e in e.writeFields(to: w) }.map { UnsafeMutableRawPointer(\$0) }');
    }
    return;
  }
  final returnTypeName = returnType.name;
  final itemType = returnTypeName.substring(5, returnTypeName.length - 1);
  final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
  if (isPrim) {
    final base = itemType.replaceAll('?', '');
    final writeCall = switch (base) {
      'double' => 'writeDouble(e)',
      'bool' => 'writeBool(e)',
      'String' => 'writeString(e)',
      _ => 'writeInt(e)',
    };
    writer.line('    return NitroRecordWriter.encodeList(r) { w, e in w.$writeCall }.map { UnsafeMutableRawPointer(\$0) }');
  } else {
    writer.line('    return NitroRecordWriter.encodeIndexedList(r) { w, e in e.writeFields(w) }.map { UnsafeMutableRawPointer(\$0) }');
  }
}

void _emitTypedDataReturn(CodeWriter writer, BridgeFunction func) {
  if (SwiftTypeMapper.isDataBackedTypedData(func.returnType.name)) {
    final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataReturn' : '_nitroCopyTypedDataReturn';
    writer.line('    return r.withUnsafeBytes { $helper(\$0) }');
  } else {
    final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataArrayReturn' : '_nitroCopyTypedDataArrayReturn';
    writer.line('    return $helper(r)');
  }
}
