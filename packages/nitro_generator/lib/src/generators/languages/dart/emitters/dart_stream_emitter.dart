part of '../dart_ffi_generator.dart';

/// Emits `@override` stream getter implementations for all [BridgeStream]s,
/// plus the closing brace of the generated `_Impl` class.
void _emitStreamImpls(CodeWriter writer, BridgeSpec spec) {
  // ── Stream implementations ───────────────────────────────────────────────
  for (final stream in spec.streams) {
    final cap = _cap(stream.dartName);
    final itemType = stream.itemType.name;
    final isRecord = stream.itemType.isRecord;
    final isStruct = spec.isStructName(itemType);

    final String unpackExpr;
    final String streamItemType;
    // Strip nullable suffix before type checks; isNullable covers the rest.
    final baseItemType = bareTypeName(itemType);
    final bool isVariant = spec.isVariantName(baseItemType);
    // Re-evaluate isStruct with base type (covers nullable struct streams).
    final isStructBase = spec.isStructName(baseItemType);

    switch (baseItemType) {
      case _ when isRecord:
        final decodeExpr = _decodeRecordExpr(stream.itemType, 'rawPtr', spec);
        final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
        unpackExpr = '(message) { if (message == null) { $nullAction; } final rawPtr = Pointer<Uint8>.fromAddress(message as int); try { return $decodeExpr; } finally { _nitroFree(rawPtr); } }';
        streamItemType = baseItemType; // nullable suffix added by isNullable check at stream signature
      case _ when isStruct || isStructBase:
        // Zero-copy path: ${baseItemType}Proxy extends ${baseItemType} and overrides every
        // getter to read lazily from native memory.  Because the proxy IS-A value
        // type, Stream<${baseItemType}Proxy> satisfies Stream<${baseItemType}> via Dart's
        // covariant generics — no .map() or eager field copy required.
        final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
        unpackExpr = '(message) { if (message == null) { $nullAction; } return ${baseItemType}Proxy(Pointer<${baseItemType}Ffi>.fromAddress(message as int)); }';
        streamItemType = baseItemType;
      case _ when isVariant:
        // @NitroVariant stream: native posts address of [4B len][1B tag][fields] binary blob.
        // Dart calls VariantExt.fromNative to decode then frees the allocation.
        final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
        unpackExpr =
            '(message) { if (message == null) { $nullAction; } '
            'final rawPtr = Pointer<Uint8>.fromAddress(message as int); '
            'try { return ${_variantDecodeExtName(spec, baseItemType)}.fromNative(rawPtr); } '
            'finally { _nitroFree(rawPtr); } }';
        streamItemType = baseItemType;
      case _ when stream.itemType.isAnyNativeObject:
        // AnyNativeObject stream: native posts kInt64 instance ID.
        // For nullable: native posts kNull → message is null.
        if (stream.itemType.isNullable) {
          unpackExpr = '(message) => message == null ? null : AnyNativeObject(message as int)';
        } else {
          unpackExpr = '(message) => AnyNativeObject(message as int)';
        }
        streamItemType = 'AnyNativeObject';
      case _ when spec.isEnumName(baseItemType):
        // Enum stream: convert int to enum via generated extension.
        // For nullable: native posts kNull for null items → message is null.
        if (stream.itemType.isNullable) {
          unpackExpr = '(message) => message == null ? null : (message as int).to$baseItemType()';
        } else {
          unpackExpr = '(message) => (message as int).to$baseItemType()';
        }
        streamItemType = baseItemType;
      case 'uint64':
        // uint64 stream: native posts kInt64; Dart int holds the same bits.
        // For nullable: native posts kNull → message is null.
        if (stream.itemType.isNullable) {
          unpackExpr = '(message) => message == null ? null : message as int';
        } else {
          unpackExpr = '(message) => message as int';
        }
        streamItemType = 'int';
      case 'bool':
        // Native posts kInt64 (0/1) for bool streams — kBool is unreliable on Android.
        // For nullable: native posts kNull for null → message is null.
        if (stream.itemType.isNullable) {
          unpackExpr = '(message) => message == null ? null : (message as int) != 0';
        } else {
          unpackExpr = '(message) => (message as int) != 0';
        }
        streamItemType = 'bool';
      case 'DateTime':
        if (stream.itemType.isNullable) {
          unpackExpr = '(message) => message == null ? null : DateTime.fromMillisecondsSinceEpoch(message as int)';
        } else {
          unpackExpr = '(message) => DateTime.fromMillisecondsSinceEpoch(message as int)';
        }
        streamItemType = 'DateTime';
      default:
        // int, double, String (and nullable variants): native posts kNull for null.
        // `message as T?` handles both null and the concrete Dart type.
        unpackExpr = '(message) => message as $baseItemType${stream.itemType.isNullable ? '?' : ''}';
        streamItemType = baseItemType;
    }

    writer.line('  @override');
    final streamSig = stream.isMethodStyle
        ? 'Stream<$streamItemType${stream.itemType.isNullable ? '?' : ''}> ${stream.dartName}()'
        : 'Stream<$streamItemType${stream.itemType.isNullable ? '?' : ''}> get ${stream.dartName}';
    writer.line('  $streamSig {');
    writer.line('    checkDisposed();');
    if (stream.isBatch) {
      // Batch stream: the bridge batcher delivers [item, item, ...] per Dart
      // wake (whatever native emitted while Dart was busy) and expects an ack
      // after each message. Same shape on every backend.
      final openType = (isStruct || isStructBase) ? '${baseItemType}Proxy${stream.itemType.isNullable ? '?' : ''}' : '$streamItemType${stream.itemType.isNullable ? '?' : ''}';
      // unpackExpr is a `(message) ...` closure; declare it as a local function.
      final decl = '$openType unpackItem(dynamic message)${unpackExpr.substring('(message)'.length)}';
      writer.line('    ${decl.endsWith('}') ? decl : '$decl;'}');
      writer.line('    return NitroRuntime.openStream<List<$openType>>(');
      writer.line('      register: (port) => _register${cap}Ptr(_instanceId, port),');
      writer.line('      unpack: (message) => [for (final m in message as List<dynamic>) unpackItem(m)],');
      writer.line('      release: (port) => _release${cap}Ptr(port),');
      writer.line('      backpressure: Backpressure.batch,');
      writer.line('      ack: _nitroAckPtr,');
      writer.line('    ).asyncExpand(Stream.fromIterable);');
    } else {
      // For struct streams, openStream is typed to the Proxy so the NativeFinalizer
      // is attached correctly, but the return is implicitly upcast to Stream<value>.
      final openType = (isStruct || isStructBase) ? '${baseItemType}Proxy${stream.itemType.isNullable ? '?' : ''}' : '$streamItemType${stream.itemType.isNullable ? '?' : ''}';
      writer.line('    return NitroRuntime.openStream<$openType>(');
      writer.line('      register: (port) => _register${cap}Ptr(_instanceId, port),');
      writer.line('      unpack: $unpackExpr,');
      writer.line('      release: (port) => _release${cap}Ptr(port),');
      writer.line(
        '      backpressure: Backpressure.${stream.backpressure.name},',
      );
      writer.line('    );');
    }
    writer.line('  }');
    writer.blankLine();
  }

  writer.line('}');
}
