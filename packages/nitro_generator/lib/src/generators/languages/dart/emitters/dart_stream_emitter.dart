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
    final baseItemType = itemType.replaceFirst('?', '');
    final bool isVariant = spec.isVariantName(baseItemType);
    // Re-evaluate isStruct with base type (covers nullable struct streams).
    final isStructBase = spec.isStructName(baseItemType);

    if (isRecord) {
      final decodeExpr = _decodeRecordExpr(stream.itemType, 'rawPtr');
      final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
      unpackExpr = '(message) { if (message == null) { $nullAction; } final rawPtr = Pointer<Uint8>.fromAddress(message as int); try { return $decodeExpr; } finally { _nitroFree(rawPtr); } }';
      streamItemType = baseItemType; // nullable suffix added by isNullable check at stream signature
    } else if (isStruct || isStructBase) {
      // Zero-copy path: ${baseItemType}Proxy extends ${baseItemType} and overrides every
      // getter to read lazily from native memory.  Because the proxy IS-A value
      // type, Stream<${baseItemType}Proxy> satisfies Stream<${baseItemType}> via Dart's
      // covariant generics — no .map() or eager field copy required.
      final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
      unpackExpr = '(message) { if (message == null) { $nullAction; } return ${baseItemType}Proxy(Pointer<${baseItemType}Ffi>.fromAddress(message as int)); }';
      streamItemType = baseItemType;
    } else if (isVariant) {
      // @NitroVariant stream: native posts address of [4B len][1B tag][fields] binary blob.
      // Dart calls VariantExt.fromNative to decode then frees the allocation.
      final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
      unpackExpr =
          '(message) { if (message == null) { $nullAction; } '
          'final rawPtr = Pointer<Uint8>.fromAddress(message as int); '
          'try { return ${baseItemType}VariantExt.fromNative(rawPtr); } '
          'finally { _nitroFree(rawPtr); } }';
      streamItemType = baseItemType;
    } else if (stream.itemType.isAnyNativeObject) {
      // AnyNativeObject stream: native posts kInt64 instance ID.
      // For nullable: native posts kNull → message is null.
      if (stream.itemType.isNullable) {
        unpackExpr = '(message) => message == null ? null : AnyNativeObject(message as int)';
      } else {
        unpackExpr = '(message) => AnyNativeObject(message as int)';
      }
      streamItemType = 'AnyNativeObject';
    } else if (spec.isEnumName(baseItemType)) {
      // Enum stream: convert int to enum via generated extension.
      // For nullable: native posts kNull for null items → message is null.
      if (stream.itemType.isNullable) {
        unpackExpr = '(message) => message == null ? null : (message as int).to$baseItemType()';
      } else {
        unpackExpr = '(message) => (message as int).to$baseItemType()';
      }
      streamItemType = baseItemType;
    } else if (baseItemType == 'uint64') {
      // uint64 stream: native posts kInt64; Dart int holds the same bits.
      // For nullable: native posts kNull → message is null.
      if (stream.itemType.isNullable) {
        unpackExpr = '(message) => message == null ? null : message as int';
      } else {
        unpackExpr = '(message) => message as int';
      }
      streamItemType = 'int';
    } else if (baseItemType == 'bool') {
      // Native posts kInt64 (0/1) for bool streams — kBool is unreliable on Android.
      // For nullable: native posts kNull for null → message is null.
      if (stream.itemType.isNullable) {
        unpackExpr = '(message) => message == null ? null : (message as int) != 0';
      } else {
        unpackExpr = '(message) => (message as int) != 0';
      }
      streamItemType = 'bool';
    } else if (baseItemType == 'DateTime') {
      if (stream.itemType.isNullable) {
        unpackExpr = '(message) => message == null ? null : DateTime.fromMillisecondsSinceEpoch(message as int)';
      } else {
        unpackExpr = '(message) => DateTime.fromMillisecondsSinceEpoch(message as int)';
      }
      streamItemType = 'DateTime';
    } else {
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
    if (stream.isBatch && itemType == 'String') {
      // String batch: native sends Dart_CObject_kArray of kStrings → List<dynamic>.
      writer.line('    return NitroRuntime.openStream<List<dynamic>>(');
      writer.line('      register: (port) => _register${cap}Ptr(_instanceId, port),');
      writer.line('      unpack: (message) => message as List<dynamic>,');
      writer.line('      release: (port) => _release${cap}Ptr(port),');
      writer.line('      backpressure: Backpressure.batch,');
      writer.line('    ).asyncExpand((batch) {');
      writer.line('      return Stream.fromIterable(batch.cast<String>());');
      writer.line('    });');
    } else if (stream.isBatch && (isRecord || isVariant)) {
      // Record/variant batch: native emits [4B outer_len][4B count][item bytes...] as Uint8List.
      // Dart copies to native memory and decodes with RecordReader.decodeList.
      final decodeCall = isRecord ? 'RecordReader.decodeList(ptr, (r) => ${baseItemType}Ext.fromReader(r))' : 'RecordReader.decodeList(ptr, (r) => ${baseItemType}VariantExt.fromReader(r))';
      writer.line('    return NitroRuntime.openStream<Uint8List>(');
      writer.line('      register: (port) => _register${cap}Ptr(_instanceId, port),');
      writer.line('      unpack: (message) => message as Uint8List,');
      writer.line('      release: (port) => _release${cap}Ptr(port),');
      writer.line('      backpressure: Backpressure.batch,');
      writer.line('    ).asyncExpand((batch) {');
      writer.line('      final ptr = malloc<Uint8>(batch.length);');
      writer.line('      ptr.asTypedList(batch.length).setAll(0, batch);');
      writer.line('      try {');
      writer.line('        return Stream.fromIterable($decodeCall);');
      writer.line('      } finally {');
      writer.line('        malloc.free(ptr);');
      writer.line('      }');
      writer.line('    });');
    } else if (stream.isBatch) {
      // Numeric batch: native emits Int64List [count, item0, item1, ...].
      writer.line('    return NitroRuntime.openStream<List<int>>(');
      writer.line('      register: (port) => _register${cap}Ptr(_instanceId, port),');
      // Dart_CObject_kArray arrives as List<dynamic>; .cast<int>() lazy-reifies it.
      writer.line('      unpack: (message) => (message as List).cast<int>(),');
      writer.line('      release: (port) => _release${cap}Ptr(port),');
      writer.line('      backpressure: Backpressure.batch,');
      writer.line('    ).asyncExpand((batch) {');
      writer.line('      final count = batch[0];');
      // Build a List of decoded items and return Stream.fromIterable.
      if (itemType == 'int') {
        writer.line('      return Stream.fromIterable([for (var i = 1; i <= count; i++) batch[i]]);');
      } else if (itemType == 'double') {
        writer.line('      return Stream.fromIterable([for (var i = 1; i <= count; i++) Int64List.fromList([batch[i]]).buffer.asFloat64List()[0]]);');
      } else if (itemType == 'bool') {
        writer.line('      return Stream.fromIterable([for (var i = 1; i <= count; i++) batch[i] != 0]);');
      } else if (spec.isEnumName(itemType)) {
        // Enum batch: items packed as Int64 rawValues → decode to enum via extension.
        writer.line('      return Stream.fromIterable([for (var i = 1; i <= count; i++) batch[i].to$itemType()]);');
      } else {
        writer.line('      return Stream.fromIterable([for (var i = 1; i <= count; i++) batch[i] as $itemType]);');
      }
      writer.line('    });');
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
