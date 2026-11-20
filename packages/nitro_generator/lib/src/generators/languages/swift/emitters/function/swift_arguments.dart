part of '../swift_function_emitter.dart';

// C arguments → the values the implementation is called with: the call
// argument list and the conversions emitted at the top of every stub.

String _buildCallArgs(BridgeFunction func, BridgeSpec spec, SwiftTypeMapper mapper) {
  return func.params
      .map((p) {
        final isStr = p.type.name == 'String' || p.type.name == 'String?';
        final isBool = p.type.name == 'bool' || p.type.name == 'bool?';
        if (isStr) return '${p.name}: ${p.name}Str';
        // A map in any position: decoded at the top of the stub.
        if (p.type.isMap || p.type.isAnyMap) return '${p.name}: ${SwiftMapEmitter.argName(p)}';
        // Byte-safe decode: byte[0]=hasValue; bytes[1..8]=value via copyMemory (avoids withMemoryRebound alignment crash).
        if (p.type.name == 'int?') {
          return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()';
        }
        if (p.type.name == 'uint64?') {
          return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: UInt64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()';
        }
        if (p.type.name == 'double?') {
          return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Double = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()';
        }
        if (p.type.name == 'bool?') return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; return _p[1] != 0 }()';
        if (p.type.name == 'DateTime') return '${p.name}: Date(timeIntervalSince1970: Double(${p.name})/1000.0)';
        if (p.type.name == 'DateTime?') {
          return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return Date(timeIntervalSince1970: Double(_rv)/1000.0) }()';
        }
        if (isBool) return '${p.name}: ${p.name} != 0';
        if (p.type.isTypedData) return '${p.name}: ${p.name}Arr';
        if (p.type.isRecord && p.type.name.startsWith('List<')) return '${p.name}: ${p.name}Decoded';
        if (p.type.isFunction) return '${p.name}: ${mapper.callbackWrapper(p)}';
        if (spec.isStructName(bareTypeName(p.type.name))) {
          final sn = bareTypeName(p.type.name);
          final opt = p.type.name.endsWith('?');
          return opt ? '${p.name}: ${p.name}.map { \$0.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift() }' : '${p.name}: ${p.name}!.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift()';
        }
        if (spec.isRecordName(bareTypeName(p.type.name))) {
          final rn = bareTypeName(p.type.name);
          final opt = p.type.name.endsWith('?') || p.type.isNullable;
          return opt ? '${p.name}: ${p.name}.map { $rn.fromNative(\$0.assumingMemoryBound(to: UInt8.self)) }' : '${p.name}: $rn.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self))';
        }
        if (spec.isVariantName(bareTypeName(p.type.name))) {
          // @NitroVariant param: decode from [4B len][1B tag][fields] buffer.
          // NitroRecordReader skips the 4-byte prefix internally.
          final vn = bareTypeName(p.type.name);
          return '${p.name}: $vn.fromReader(NitroRecordReader(ptr: ${p.name}!.assumingMemoryBound(to: UInt8.self)))';
        }
        if (p.type.isAnyNativeObject) {
          // AnyNativeObject: raw Int64 instanceId; nullable: -1 = null
          final opt = p.type.isNullable || p.type.name.endsWith('?');
          return opt ? '${p.name}: ${p.name} == -1 ? nil : ${p.name}' : '${p.name}: ${p.name}';
        }
        final customBase = bareTypeName(p.type.name);
        if (spec.isCustomTypeName(customBase)) {
          // @NitroCustomType: pass raw UnsafeMutablePointer<UInt8>? to impl
          return '${p.name}: ${p.name}';
        }
        final isEnum = spec.isEnumName(bareTypeName(p.type.name));
        if (isEnum) {
          final en = bareTypeName(p.type.name);
          final opt = p.type.name.endsWith('?');
          return opt ? '${p.name}: $en(rawValue: ${p.name})' : '${p.name}: $en(rawValue: ${p.name})!';
        }
        return '${p.name}: ${p.name}';
      })
      .join(', ');
}

void _emitParamConversions(
  CodeWriter writer,
  List<BridgeParam> stringParams,
  List<BridgeParam> typedListParams,
  List<BridgeParam> recordListParams,
  BridgeFunction func,
) {
  for (final p in stringParams) {
    if (p.type.name == 'String?') {
      writer.line('    let ${p.name}Str: String? = _nitroStringOptFromCString(${p.name})');
    } else {
      writer.line('    let ${p.name}Str = _nitroStringFromCString(${p.name})');
    }
  }
  for (final p in typedListParams) {
    final isData = p.type.name.startsWith('Uint8List') || p.type.name.startsWith('Int8List');
    if (isData) {
      writer.line('    let ${p.name}Arr = ${p.name}.map { Data(bytes: \$0, count: Int(${p.name}_length)) }${p.type.name.endsWith('?') ? '' : ' ?? Data()'}');
    } else {
      writer.line('    let ${p.name}Arr = ${p.name}.map { Array(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) }${p.type.name.endsWith('?') ? '' : ' ?? []'}');
    }
  }
  for (final p in recordListParams) {
    writer.line('    let ${p.name}Ptr = ${p.name}?.assumingMemoryBound(to: UInt8.self)');
    // List<@HybridEnum> / List<@HybridEnum?>
    if (p.type.isEnumList) {
      final itemType = p.type.recordListItemType!;
      if (p.type.recordListItemIsNullable) {
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeNullableList(\$0) { r in $itemType(rawValue: r.readInt())! } } ?? []');
      } else {
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeList(\$0) { r in $itemType(rawValue: r.readInt())! } } ?? []');
      }
      continue;
    }
    // List<@NitroVariant> / List<@NitroVariant?>
    if (p.type.isVariantList) {
      final itemType = p.type.recordListItemType!;
      if (p.type.recordListItemIsNullable) {
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeNullableList(\$0) { r in $itemType.fromReader(r) } } ?? []');
      } else {
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeList(\$0) { r in $itemType.fromReader(r) } } ?? []');
      }
      continue;
    }
    final itemType = p.type.name.substring(5, p.type.name.length - 1);
    final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
    if (isPrim) {
      final base = itemType.replaceAll('?', '');
      final readCall = switch (base) {
        'double' => 'r.readDouble()',
        'bool' => 'r.readBool()',
        'String' => 'r.readString()',
        _ => 'r.readInt()',
      };
      writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeIndexedList(\$0) { r in $readCall } } ?? []');
    } else {
      writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeIndexedList(\$0) { r in $itemType.fromReader(r) } } ?? []');
    }
  }
}
