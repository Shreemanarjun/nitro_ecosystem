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
    final itemName = stream.itemType.name.replaceFirst('?', '');
    final isStructItem  = spec.isStructName(itemName);
    final isRecordItem  = stream.itemType.isRecord;
    final isEnumItem    = spec.isEnumName(itemName);
    final isBoolItem    = itemName == 'bool';
    final isVariantItem = spec.isVariantName(itemName);
    final isNullable    = stream.itemType.isNullable;

    // For nullable scalar types (int?, double?, bool?, enum?), the emitCb callback
    // uses a pointer type so Swift can pass nil for null items. The C shim checks
    // nullptr and posts Dart_CObject_kNull.
    final String cType;
    if (isNullable && itemName == 'int') {
      cType = 'UnsafePointer<Int64>?';
    } else if (isNullable && itemName == 'double') {
      cType = 'UnsafePointer<Double>?';
    } else if (isNullable && isBoolItem) {
      cType = 'UnsafePointer<Int8>?';
    } else if (isNullable && isEnumItem) {
      cType = 'UnsafePointer<Int64>?';
    } else if (isVariantItem) {
      cType = 'UnsafeMutablePointer<UInt8>?';
    } else {
      cType = mapper.swiftCType(stream.itemType.name);
    }

    if (stream.isBatch) {
      _emitBatch(writer, stream, spec);
    } else if (stream.isBufferDrop) {
      _emitBufferDrop(writer, stream, spec, cType, itemName,
          isStructItem: isStructItem,
          isRecordItem: isRecordItem,
          isEnumItem: isEnumItem,
          isBoolItem: isBoolItem,
          isVariantItem: isVariantItem);
    } else if (stream.isBlock) {
      _emitBlock(writer, stream, spec, cType, itemName,
          isStructItem: isStructItem,
          isRecordItem: isRecordItem,
          isEnumItem: isEnumItem,
          isBoolItem: isBoolItem,
          isVariantItem: isVariantItem);
    } else {
      _emitDropLatest(writer, stream, spec, cType, itemName,
          isStructItem: isStructItem,
          isRecordItem: isRecordItem,
          isEnumItem: isEnumItem,
          isBoolItem: isBoolItem,
          isVariantItem: isVariantItem);
    }
  }

  static void _emitBatch(CodeWriter writer, BridgeStream stream, BridgeSpec spec) {
    final batchMax  = stream.batchMaxSize;
    final itemBase  = stream.itemType.name.replaceFirst('?', '');
    writer.line('@_cdecl("_${spec.namespace}_register_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_register_${stream.dartName}_stream(');
    writer.line('    _ dartPort: Int64,');
    writer.line('    _ emitBatch: @convention(c) (Int64, UnsafeMutablePointer<Int64>?, Int32) -> Bool');
    writer.line(') {');
    writer.line('    let _lock = NSLock()');
    writer.line('    var _buf = [Int64]()');
    writer.line('    _buf.reserveCapacity($batchMax)');
    writer.line('    func _flush() {');
    writer.line('        _lock.lock()');
    writer.line('        guard !_buf.isEmpty else { _lock.unlock(); return }');
    writer.line('        var arr = _buf; _buf.removeAll(keepingCapacity: true)');
    writer.line('        _lock.unlock()');
    writer.line('        let count = Int32(arr.count)');
    writer.line(r'        _ = arr.withUnsafeMutableBufferPointer { emitBatch(dartPort, $0.baseAddress, count) }');
    writer.line('    }');
    writer.line('    let _timer = DispatchSource.makeTimerSource(queue: .global())');
    writer.line('    _timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))');
    writer.line('    _timer.setEventHandler { _flush() }');
    writer.line('    _timer.resume()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}FlushTimers[dartPort] = _timer');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =');
    writer.line('        ${spec.dartClassName}Registry.impl?.${stream.dartName}.sink { item in');
    writer.line('            _lock.lock()');
    if (itemBase == 'double') {
      writer.line('            _buf.append(Int64(bitPattern: item.bitPattern))');
    } else if (itemBase == 'bool') {
      writer.line('            _buf.append(item ? 1 : 0)');
    } else if (spec.isEnumName(itemBase)) {
      // Enum batch: pack enum rawValue into the Int64 batch buffer.
      writer.line('            _buf.append(item.rawValue)');
    } else {
      writer.line('            _buf.append(item)');
    }
    writer.line('            let needsFlush = _buf.count >= $batchMax');
    writer.line('            _lock.unlock()');
    writer.line('            if needsFlush { _flush() }');
    writer.line('        }');
    writer.line('}');
    writer.blankLine();
    writer.line('@_cdecl("_${spec.namespace}_release_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_release_${stream.dartName}_stream(_ dartPort: Int64) {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}FlushTimers[dartPort]?.cancel()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}FlushTimers.removeValue(forKey: dartPort)');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort]?.cancel()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)');
    writer.line('}');
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
    _emitSinkBody(writer, stream, spec, itemName,
        isStructItem: isStructItem,
        isRecordItem: isRecordItem,
        isEnumItem: isEnumItem,
        isBoolItem: isBoolItem,
        isVariantItem: isVariantItem,
        indent: '                ');
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
    writer.line('    let _serialQ = DispatchQueue(label: "com.nitro.block.${stream.dartName}.\(dartPort)", qos: .userInteractive)');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =');
    writer.line('        ${spec.dartClassName}Registry.impl?.${stream.dartName}');
    writer.line('            .buffer(size: $bufferCap, prefetch: .byRequest, whenFull: .dropNewest)');
    writer.line('            .receive(on: _serialQ)');
    writer.line('            .sink { item in');
    _emitSinkBody(writer, stream, spec, itemName,
        isStructItem: isStructItem,
        isRecordItem: isRecordItem,
        isEnumItem: isEnumItem,
        isBoolItem: isBoolItem,
        isVariantItem: isVariantItem,
        indent: '                ');
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
    _emitSinkBody(writer, stream, spec, itemName,
        isStructItem: isStructItem,
        isRecordItem: isRecordItem,
        isEnumItem: isEnumItem,
        isBoolItem: isBoolItem,
        isVariantItem: isVariantItem,
        indent: '            ');
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
    if (isVariantItem) {
      // @NitroVariant stream: serialize variant to length-prefixed bytes via toNative(),
      // post the pointer address as Int64 (Dart frees via malloc.free after decode).
      writer.line('${indent}let raw = item.toNative()');
      writer.line('${indent}if !emitCb(dartPort, raw) {');
      writer.line('$indent    if let raw { free(UnsafeMutableRawPointer(raw)) }');
      writer.line('$indent    $cancel');
      writer.line('$indent}');
    } else if (isStructItem) {
      if (isNullable) {
        writer.line('${indent}guard let item = item else {');
        writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
        writer.line('${indent}    return');
        writer.line('$indent}');
      }
      writer.line('${indent}let ptr = UnsafeMutablePointer<_${itemName}C>.allocate(capacity: 1)');
      writer.line('${indent}ptr.initialize(to: _${itemName}C.fromSwift(item))');
      writer.line('${indent}if !emitCb(dartPort, UnsafeMutableRawPointer(ptr)) {');
      writer.line('$indent    ptr.deinitialize(count: 1)');
      writer.line('$indent    ptr.deallocate()');
      writer.line('$indent    $cancel');
      writer.line('$indent}');
    } else if (isEnumItem) {
      if (isNullable) {
        writer.line('${indent}if let v = item {');
        writer.line('$indent    var _rv = v.rawValue');
        writer.line('$indent    if !emitCb(dartPort, &_rv) { $cancel }');
        writer.line('${indent}} else {');
        writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
        writer.line('$indent}');
      } else {
        writer.line('${indent}if !emitCb(dartPort, item.rawValue) { $cancel }');
      }
    } else if (isRecordItem) {
      writer.line('${indent}let raw = item.toNative()');
      writer.line('${indent}if !emitCb(dartPort, raw) {');
      writer.line('$indent    if let raw { free(UnsafeMutableRawPointer(raw)) }');
      writer.line('$indent    $cancel');
      writer.line('$indent}');
    } else if (isBoolItem) {
      if (isNullable) {
        writer.line('${indent}if let v = item {');
        writer.line('$indent    var _bv: Int8 = v ? 1 : 0');
        writer.line('$indent    if !emitCb(dartPort, &_bv) { $cancel }');
        writer.line('${indent}} else {');
        writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
        writer.line('$indent}');
      } else {
        writer.line('${indent}if !emitCb(dartPort, Int8(item ? 1 : 0)) { $cancel }');
      }
    } else if (itemName == 'String') {
      if (isNullable) {
        writer.line('${indent}if let s = item {');
        writer.line('$indent    s.withCString { ptr in');
        writer.line('$indent        if !emitCb(dartPort, UnsafeMutablePointer(mutating: ptr)) { $cancel }');
        writer.line('$indent    }');
        writer.line('${indent}} else {');
        writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
        writer.line('$indent}');
      } else {
        writer.line('${indent}item.withCString { ptr in');
        writer.line('$indent    if !emitCb(dartPort, UnsafeMutablePointer(mutating: ptr)) { $cancel }');
        writer.line('$indent}');
      }
    } else if (stream.itemType.isTypedData && stream.itemType.isNullable) {
      writer.line(r'${indent}let _ptr: Int64 = item.map { d in d.withUnsafeBytes { Int64(bitPattern: UInt64(UInt(bitPattern: $0.baseAddress))) } } ?? 0');
      writer.line('${indent}if !emitCb(dartPort, _ptr) { $cancel }');
    } else if (isNullable) {
      // Nullable int/double: cType is UnsafePointer<Int64>?/UnsafePointer<Double>? — pass nil for null.
      writer.line('${indent}if let v = item {');
      writer.line('$indent    var _v = v');
      writer.line('$indent    if !emitCb(dartPort, &_v) { $cancel }');
      writer.line('${indent}} else {');
      writer.line('$indent    if !emitCb(dartPort, nil) { $cancel }');
      writer.line('$indent}');
    } else {
      writer.line('${indent}if !emitCb(dartPort, item) { $cancel }');
    }
  }
}
