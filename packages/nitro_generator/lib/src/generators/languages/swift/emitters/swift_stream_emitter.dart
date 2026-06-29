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
    final isStructItem = spec.isStructName(itemName);
    final isRecordItem = stream.itemType.isRecord;
    final isEnumItem   = spec.isEnumName(itemName);
    final isBoolItem   = itemName == 'bool';
    final isNullable   = stream.itemType.isNullable;

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
    } else {
      cType = mapper.swiftCType(stream.itemType.name);
    }

    if (stream.isBatch) {
      _emitBatch(writer, stream, spec);
    } else {
      _emitDropLatest(writer, stream, spec, cType, itemName,
          isStructItem: isStructItem,
          isRecordItem: isRecordItem,
          isEnumItem: isEnumItem,
          isBoolItem: isBoolItem);
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
  }) {
    final isNullable = stream.itemType.isNullable;
    writer.line('@_cdecl("_${spec.namespace}_register_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_register_${stream.dartName}_stream(');
    writer.line('    _ dartPort: Int64,');
    writer.line('    _ emitCb: @convention(c) (Int64, $cType) -> Bool');
    writer.line(') {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =');
    writer.line('        ${spec.dartClassName}Registry.impl?.${stream.dartName}.sink { item in');
    if (isStructItem) {
      if (isNullable) {
        writer.line('            guard let item = item else {');
        writer.line('                if !emitCb(dartPort, nil) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('                return');
        writer.line('            }');
      }
      writer.line('            let ptr = UnsafeMutablePointer<_${itemName}C>.allocate(capacity: 1)');
      writer.line('            ptr.initialize(to: _${itemName}C.fromSwift(item))');
      writer.line('            if !emitCb(dartPort, UnsafeMutableRawPointer(ptr)) {');
      writer.line('                ptr.deinitialize(count: 1)');
      writer.line('                ptr.deallocate()');
      writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
      writer.line('            }');
    } else if (isEnumItem) {
      if (isNullable) {
        // Nullable enum: cType is UnsafePointer<Int64>? — pass nil for null.
        writer.line('            if let v = item {');
        writer.line('                var _rv = v.rawValue');
        writer.line('                if !emitCb(dartPort, &_rv) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('            } else {');
        writer.line('                if !emitCb(dartPort, nil) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('            }');
      } else {
        writer.line('            if !emitCb(dartPort, item.rawValue) {');
        writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('            }');
      }
    } else if (isRecordItem) {
      writer.line('            let raw = item.toNative()');
      writer.line('            if !emitCb(dartPort, raw) {');
      writer.line('                if let raw { free(UnsafeMutableRawPointer(raw)) }');
      writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
      writer.line('            }');
    } else if (isBoolItem) {
      if (isNullable) {
        // Nullable bool: cType is UnsafePointer<Int8>? — pass nil for null.
        writer.line('            if let v = item {');
        writer.line('                var _bv: Int8 = v ? 1 : 0');
        writer.line('                if !emitCb(dartPort, &_bv) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('            } else {');
        writer.line('                if !emitCb(dartPort, nil) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('            }');
      } else {
        writer.line('            if !emitCb(dartPort, Int8(item ? 1 : 0)) {');
        writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('            }');
      }
    } else if (itemName == 'String') {
      if (isNullable) {
        // Nullable String: pass nil for null, or cString pointer for non-null.
        writer.line('            if let s = item {');
        writer.line('                s.withCString { ptr in');
        writer.line('                    if !emitCb(dartPort, UnsafeMutablePointer(mutating: ptr)) {');
        writer.line('                        ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                    }');
        writer.line('                }');
        writer.line('            } else {');
        writer.line('                if !emitCb(dartPort, nil) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('            }');
      } else {
        writer.line('            item.withCString { ptr in');
        writer.line('                if !emitCb(dartPort, UnsafeMutablePointer(mutating: ptr)) {');
        writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('                }');
        writer.line('            }');
      }
    } else if (stream.itemType.isTypedData && stream.itemType.isNullable) {
      writer.line(r'            let _ptr: Int64 = item.map { d in d.withUnsafeBytes { Int64(bitPattern: UInt64(UInt(bitPattern: $0.baseAddress))) } } ?? 0');
      writer.line('            if !emitCb(dartPort, _ptr) {');
      writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
      writer.line('            }');
    } else if (isNullable) {
      // Nullable int/double: cType is UnsafePointer<Int64>?/UnsafePointer<Double>? — pass nil for null.
      writer.line('            if let v = item {');
      writer.line('                var _v = v');
      writer.line('                if !emitCb(dartPort, &_v) {');
      writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
      writer.line('                }');
      writer.line('            } else {');
      writer.line('                if !emitCb(dartPort, nil) {');
      writer.line('                    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
      writer.line('                }');
      writer.line('            }');
    } else {
      writer.line('            if !emitCb(dartPort, item) {');
      writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
      writer.line('            }');
    }
    writer.line('        }');
    writer.line('}');
    writer.blankLine();
    writer.line('@_cdecl("_${spec.namespace}_release_${stream.dartName}_stream")');
    writer.line('public func _${spec.namespace}_release_${stream.dartName}_stream(_ dartPort: Int64) {');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort]?.cancel()');
    writer.line('    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)');
    writer.line('}');
  }
}
