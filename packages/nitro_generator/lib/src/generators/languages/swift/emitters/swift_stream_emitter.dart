import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'swift_type_mapper.dart';

/// Emits `@_cdecl` register/release stubs for a single [BridgeStream].
class SwiftStreamEmitter {
  static void emit(
    CodeWriter writer,
    BridgeStream stream,
    BridgeSpec spec,
    SwiftTypeMapper mapper,
  ) {
    final itemName = bareTypeName(stream.itemType.name);
    final isStructItem = spec.isStructName(itemName);
    final isRecordItem = stream.itemType.isRecord;
    final isEnumItem = spec.isEnumName(itemName);
    final isBoolItem = itemName == 'bool';
    final isVariantItem = spec.isVariantName(itemName);
    final isNullable = stream.itemType.isNullable;

    // For nullable scalar types (int?, double?, bool?, enum?), the emitCb callback
    // uses a pointer type so Swift can pass nil for null items. The C shim checks
    // nullptr and posts Dart_CObject_kNull.
    final String cType;
    if (stream.itemType.isAnyNativeObject && isNullable) {
      // Nullable AnyNativeObject: pointer to Int64 so nil can signal null.
      cType = 'UnsafePointer<Int64>?';
    } else if (isNullable && itemName == 'int') {
      cType = 'UnsafePointer<Int64>?';
    } else if (isNullable && itemName == 'uint64') {
      cType = 'UnsafePointer<UInt64>?';
    } else if (isNullable && itemName == 'double') {
      cType = 'UnsafePointer<Double>?';
    } else if (isNullable && isBoolItem) {
      cType = 'UnsafePointer<Int8>?';
    } else if (isNullable && isEnumItem) {
      cType = 'UnsafePointer<Int64>?';
    } else if (isNullable && itemName == 'DateTime') {
      cType = 'UnsafePointer<Int64>?';
    } else if (isVariantItem) {
      cType = 'UnsafeMutablePointer<UInt8>?';
    } else if (stream.itemType.isTypedData) {
      // (pointer, element count); a negative count means a null item.
      cType = 'UnsafeRawPointer?, Int64';
    } else {
      cType = mapper.swiftCType(stream.itemType.name);
    }

    // Backpressure.batch posts per item too — the C bridge coalesces the port.
    if (stream.isBufferDrop) {
      _emitBufferDrop(writer, stream, spec, cType, itemName, isStructItem: isStructItem, isRecordItem: isRecordItem, isEnumItem: isEnumItem, isBoolItem: isBoolItem, isVariantItem: isVariantItem);
    } else if (stream.isBlock) {
      _emitBlock(writer, stream, spec, cType, itemName, isStructItem: isStructItem, isRecordItem: isRecordItem, isEnumItem: isEnumItem, isBoolItem: isBoolItem, isVariantItem: isVariantItem);
    } else {
      _emitDropLatest(writer, stream, spec, cType, itemName, isStructItem: isStructItem, isRecordItem: isRecordItem, isEnumItem: isEnumItem, isBoolItem: isBoolItem, isVariantItem: isVariantItem);
    }
  }

  /// Backpressure.bufferDrop: ring buffer of [batchMaxSize] items; oldest item is
  /// silently dropped when the buffer is full. Uses Combine's `.buffer(whenFull: .dropOldest)`.
  static void _emitBufferDrop(
    CodeWriter writer,
    BridgeStream stream,
    BridgeSpec spec,
    String cType,
    String itemName, {
    required bool isStructItem,
    required bool isRecordItem,
    required bool isEnumItem,
    required bool isBoolItem,
    required bool isVariantItem,
  }) {
    final bufferCap = stream.batchMaxSize;
    writer.line('@_cdecl("_${spec.namespace}_register_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_register_${stream.dartName}_stream(');
    writer.line('    _ dartPort: Int64,');
    writer.line('    _ emitCb: @convention(c) (Int64, $cType) -> Bool');
    writer.line(') {');
    // bufferDrop: oldest items dropped when the ring buffer is full.
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =');
    writer.line('        ${spec.dartClassName}Registry.impl?.${stream.dartName}');
    writer.line('            .buffer(size: $bufferCap, prefetch: .byRequest, whenFull: .dropOldest)');
    writer.line('            .sink { item in');
    _emitSinkBody(writer, stream, spec, itemName, isStructItem: isStructItem, isRecordItem: isRecordItem, isEnumItem: isEnumItem, isBoolItem: isBoolItem, isVariantItem: isVariantItem, indent: '                ');
    writer.line('        }');
    writer.line('}');
    writer.blankLine();
    writer.line('@_cdecl("_${spec.namespace}_release_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_release_${stream.dartName}_stream(_ dartPort: Int64) {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort]?.cancel()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)');
    writer.line('}');
  }

  /// Backpressure.block: bounded buffer of [batchMaxSize] items; emits are serialized
  /// on a dedicated serial DispatchQueue. Provides throughput matching — the producer is
  /// slowed when the serial queue is backed up. Uses `.buffer(whenFull: .dropNewest)` so
  /// the buffer stays bounded; Combine's serial scheduling provides the rate-limiting.
  static void _emitBlock(
    CodeWriter writer,
    BridgeStream stream,
    BridgeSpec spec,
    String cType,
    String itemName, {
    required bool isStructItem,
    required bool isRecordItem,
    required bool isEnumItem,
    required bool isBoolItem,
    required bool isVariantItem,
  }) {
    final bufferCap = stream.batchMaxSize;
    writer.line('@_cdecl("_${spec.namespace}_register_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_register_${stream.dartName}_stream(');
    writer.line('    _ dartPort: Int64,');
    writer.line('    _ emitCb: @convention(c) (Int64, $cType) -> Bool');
    writer.line(') {');
    // block: bounded buffer + serial delivery queue. The serial queue processes one item
    // at a time; if the queue is saturated, Combine backs off demand to the publisher.
    writer.line('    let _serialQ = DispatchQueue(label: "com.nitro.block.${stream.dartName}.(dartPort)", qos: .userInteractive)');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =');
    writer.line('        ${spec.dartClassName}Registry.impl?.${stream.dartName}');
    writer.line('            .buffer(size: $bufferCap, prefetch: .byRequest, whenFull: .dropNewest)');
    writer.line('            .receive(on: _serialQ)');
    writer.line('            .sink { item in');
    _emitSinkBody(writer, stream, spec, itemName, isStructItem: isStructItem, isRecordItem: isRecordItem, isEnumItem: isEnumItem, isBoolItem: isBoolItem, isVariantItem: isVariantItem, indent: '                ');
    writer.line('        }');
    writer.line('}');
    writer.blankLine();
    writer.line('@_cdecl("_${spec.namespace}_release_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_release_${stream.dartName}_stream(_ dartPort: Int64) {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort]?.cancel()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)');
    writer.line('}');
  }

  static void _emitDropLatest(
    CodeWriter writer,
    BridgeStream stream,
    BridgeSpec spec,
    String cType,
    String itemName, {
    required bool isStructItem,
    required bool isRecordItem,
    required bool isEnumItem,
    required bool isBoolItem,
    required bool isVariantItem,
  }) {
    writer.line('@_cdecl("_${spec.namespace}_register_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_register_${stream.dartName}_stream(');
    writer.line('    _ dartPort: Int64,');
    writer.line('    _ emitCb: @convention(c) (Int64, $cType) -> Bool');
    writer.line(') {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =');
    writer.line('        ${spec.dartClassName}Registry.impl?.${stream.dartName}.sink { item in');
    _emitSinkBody(writer, stream, spec, itemName, isStructItem: isStructItem, isRecordItem: isRecordItem, isEnumItem: isEnumItem, isBoolItem: isBoolItem, isVariantItem: isVariantItem, indent: '            ');
    writer.line('        }');
    writer.line('}');
    writer.blankLine();
    writer.line('@_cdecl("_${spec.namespace}_release_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_release_${stream.dartName}_stream(_ dartPort: Int64) {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort]?.cancel()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)');
    writer.line('}');
  }

  /// Emits the per-item-type body inside a `.sink { item in ... }` closure.
  /// [indent] controls the leading whitespace for each generated line.
  static void _emitSinkBody(
    CodeWriter writer,
    BridgeStream stream,
    BridgeSpec spec,
    String itemName, {
    required bool isStructItem,
    required bool isRecordItem,
    required bool isEnumItem,
    required bool isBoolItem,
    required bool isVariantItem,
    required String indent,
  }) {
    final isNullable = stream.itemType.isNullable;
    final cancel = '${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()';
    if (stream.itemType.isTypedData) {
      // Data (Uint8List / Int8List) or a Swift array: pass its storage and
      // element count; the C shim posts it as a Dart typed list.
      final isData = itemName == 'Uint8List' || itemName == 'Int8List';
      final ind = indent;
      if (isNullable) {
        writer.line('${indent}guard let item = item else {');
        writer.line('$indent    if !emitCb(dartPort, nil, -1) { $cancel }');
        writer.line('$indent    return');
        writer.line('$indent}');
      }
      if (isData) {
        writer.line('${ind}item.withUnsafeBytes { buf in');
        writer.line('$ind    if !emitCb(dartPort, buf.baseAddress, Int64(buf.count)) { $cancel }');
        writer.line('$ind}');
      } else {
        writer.line('${ind}item.withUnsafeBufferPointer { buf in');
        writer.line('$ind    if !emitCb(dartPort, UnsafeRawPointer(buf.baseAddress), Int64(buf.count)) { $cancel }');
        writer.line('$ind}');
      }
      return;
    }
    switch (itemName) {
      case _ when isVariantItem:
        // @NitroVariant stream: serialize variant to length-prefixed bytes via toNative(),
        // post the pointer address as Int64 (Dart frees via the module's <lib>_nitro_free export after decode).
        writer.line('${indent}let raw = item.toNative()');
        writer.line('${indent}if !emitCb(dartPort, raw) {');
        writer.line('$indent    if let raw { free(UnsafeMutableRawPointer(raw)) }');
        writer.line('$indent    $cancel');
        writer.line('$indent}');
      case _ when isStructItem:
        if (isNullable) {
          writer.line('${indent}guard let item = item else {');
          writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
          writer.line('$indent    return');
          writer.line('$indent}');
        }
        writer.line('${indent}let ptr = UnsafeMutablePointer<_${itemName}C>.allocate(capacity: 1)');
        writer.line('${indent}ptr.initialize(to: _${itemName}C.fromSwift(item))');
        writer.line('${indent}if !emitCb(dartPort, UnsafeMutableRawPointer(ptr)) {');
        writer.line('$indent    ptr.deinitialize(count: 1)');
        writer.line('$indent    ptr.deallocate()');
        writer.line('$indent    $cancel');
        writer.line('$indent}');
      case _ when isEnumItem:
        if (isNullable) {
          writer.line('${indent}if let v = item {');
          writer.line('$indent    var _rv = v.rawValue');
          writer.line('$indent    if !emitCb(dartPort, &_rv) { $cancel }');
          writer.line('$indent} else {');
          writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
          writer.line('$indent}');
        } else {
          writer.line('${indent}if !emitCb(dartPort, item.rawValue) { $cancel }');
        }
      case _ when isRecordItem:
        writer.line('${indent}let raw = item.toNative()');
        writer.line('${indent}if !emitCb(dartPort, raw) {');
        writer.line('$indent    if let raw { free(UnsafeMutableRawPointer(raw)) }');
        writer.line('$indent    $cancel');
        writer.line('$indent}');
      case _ when isBoolItem:
        if (isNullable) {
          writer.line('${indent}if let v = item {');
          writer.line('$indent    var _bv: Int8 = v ? 1 : 0');
          writer.line('$indent    if !emitCb(dartPort, &_bv) { $cancel }');
          writer.line('$indent} else {');
          writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
          writer.line('$indent}');
        } else {
          writer.line('${indent}if !emitCb(dartPort, Int8(item ? 1 : 0)) { $cancel }');
        }
      case 'String':
        if (isNullable) {
          writer.line('${indent}if let s = item {');
          writer.line('$indent    s.withCString { ptr in');
          writer.line('$indent        if !emitCb(dartPort, UnsafeMutablePointer(mutating: ptr)) { $cancel }');
          writer.line('$indent    }');
          writer.line('$indent} else {');
          writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
          writer.line('$indent}');
        } else {
          writer.line('${indent}item.withCString { ptr in');
          writer.line('$indent    if !emitCb(dartPort, UnsafeMutablePointer(mutating: ptr)) { $cancel }');
          writer.line('$indent}');
        }
      case 'DateTime':
        if (isNullable) {
          writer.line('${indent}if let v = item {');
          writer.line('$indent    var _ms = Int64(v.timeIntervalSince1970 * 1000)');
          writer.line('$indent    if !emitCb(dartPort, &_ms) { $cancel }');
          writer.line('$indent} else {');
          writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
          writer.line('$indent}');
        } else {
          writer.line('${indent}if !emitCb(dartPort, Int64(item.timeIntervalSince1970 * 1000)) { $cancel }');
        }
      case _ when stream.itemType.isTypedData && stream.itemType.isNullable:
        writer.line(r'${indent}let _ptr: Int64 = item.map { d in d.withUnsafeBytes { Int64(bitPattern: UInt64(UInt(bitPattern: $0.baseAddress))) } } ?? 0');
        writer.line('${indent}if !emitCb(dartPort, _ptr) { $cancel }');
      case _ when isNullable:
        // Nullable int/double: cType is UnsafePointer<Int64>?/UnsafePointer<Double>? — pass nil for null.
        writer.line('${indent}if let v = item {');
        writer.line('$indent    var _v = v');
        writer.line('$indent    if !emitCb(dartPort, &_v) { $cancel }');
        writer.line('$indent} else {');
        writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
        writer.line('$indent}');
      default:
        writer.line('${indent}if !emitCb(dartPort, item) { $cancel }');
    }
  }
}
