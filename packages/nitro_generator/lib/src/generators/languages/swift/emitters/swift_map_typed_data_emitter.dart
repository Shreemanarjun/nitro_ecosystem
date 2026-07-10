part of '../swift_generator.dart';

void _emitSwiftMapHelpers(CodeWriter writer, BridgeSpec spec) {
  // Emit binary map helpers when any map types are used.
  final hasMapTypes = spec.functions.any((f) => f.returnType.isMap || f.params.any((p) => p.type.isMap)) || spec.properties.any((p) => p.type.isMap);
  if (hasMapTypes) {
    writer.line('// Binary map encode/decode — [4B payload_len][4B count][entries: [4B kLen][kBytes][1B tag][vBytes]]');
    writer.line('// Type tags: 1=int64, 2=float64, 3=bool, 4=string, 5=binary record/variant blob');
    writer.line('private func _nitroEncodeMapBinary(_ m: [String: Any]) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    var payload = Data()');
    // Use raw strings (r'...') for lines containing Swift's $0 closure shorthand.
    writer.line(r"    func writeLE32(_ v: Int32) { var lv = v.littleEndian; payload.append(contentsOf: withUnsafeBytes(of: &lv) { Data($0) }) }");
    writer.line(r"    func writeLE64(_ v: Int64) { var lv = v.littleEndian; payload.append(contentsOf: withUnsafeBytes(of: &lv) { Data($0) }) }");
    writer.line('    writeLE32(Int32(m.count))');
    writer.line('    for (k, v) in m {');
    writer.line('        let kb = k.data(using: .utf8)!; writeLE32(Int32(kb.count)); payload.append(kb)');
    writer.line('        if let iv = v as? Int64 { payload.append(1); writeLE64(iv) }');
    writer.line('        else if let dv = v as? Double { payload.append(2); writeLE64(Int64(bitPattern: dv.bitPattern)) }');
    writer.line('        else if let bv = v as? Bool { payload.append(3); payload.append(bv ? 1 : 0) }');
    writer.line('        else if let blob = v as? Data { payload.append(5); writeLE32(Int32(blob.count)); payload.append(blob) }');
    writer.line(r'        else { let sv = "\(v)".data(using: .utf8)!; payload.append(4); writeLE32(Int32(sv.count)); payload.append(sv) }');
    writer.line('    }');
    writer.line('    var lenLE = Int32(payload.count).littleEndian');
    writer.line('    let total = 4 + payload.count');
    writer.line('    guard let buf = malloc(total) else { return nil }');
    writer.line(r"    withUnsafeBytes(of: &lenLE) { memcpy(buf, $0.baseAddress!, 4) }");
    writer.line(r"    payload.withUnsafeBytes { memcpy(buf.advanced(by: 4), $0.baseAddress!, payload.count) }");
    writer.line('    return buf.assumingMemoryBound(to: UInt8.self)');
    writer.line('}');
    writer.line('private func _nitroDecodeMapBinary(_ ptr: UnsafeMutablePointer<UInt8>) -> [String: Any] {');
    // loadUnaligned avoids the Swift debug-mode alignment assertion:
    // after a variable-length key, pos is rarely on a 4- or 8-byte boundary.
    writer.line('    let payLen = Int(UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self).littleEndian)');
    writer.line('    let data = Data(bytes: ptr.advanced(by: 4), count: payLen)');
    writer.line('    var pos = 0');
    writer.line(r"    func readLE32() -> Int { let v = data[pos..<(pos+4)].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }; pos += 4; return v }");
    writer.line(r"    func readLE64() -> Int64 { let v = data[pos..<(pos+8)].withUnsafeBytes { Int64(bitPattern: $0.loadUnaligned(as: UInt64.self).littleEndian) }; pos += 8; return v }");
    writer.line('    let count = readLE32(); var result = [String: Any]()');
    writer.line('    for _ in 0..<count {');
    writer.line('        let kLen = readLE32(); let k = String(data: data[pos..<(pos+kLen)], encoding: .utf8)!; pos += kLen');
    writer.line('        let tag = data[pos]; pos += 1');
    writer.line('        switch tag {');
    writer.line('        case 1: result[k] = readLE64()');
    writer.line('        case 2: result[k] = Double(bitPattern: UInt64(bitPattern: readLE64()))');
    writer.line('        case 3: result[k] = data[pos] != 0; pos += 1');
    // tag 5 = binary record/variant blob — store as Data for type-specific caller to decode
    writer.line('        case 5: let bLen = readLE32(); result[k] = Data(data[pos..<(pos+bLen)]); pos += bLen');
    writer.line('        default: let vLen = readLE32(); result[k] = String(data: data[pos..<(pos+vLen)], encoding: .utf8); pos += vLen');
    writer.line('        }');
    writer.line('    }');
    writer.line('    return result');
    writer.line('}');
    writer.blankLine();
  }
}

/// Emits the NitroAnyMap recursive binary codec for Swift bridge files.
///
/// Previously entirely unimplemented on Swift (sync, `@nitroAsync`, and
/// `@NitroNativeAsync` alike) — `isAnyMap` was never referenced anywhere in
/// the Swift emitters. Wire format matches Dart's `NitroAnyValue`/Kotlin's
/// `NitroAnyMapCodec` exactly: `[4B payload_len][4B count][entries: [4B kLen]
/// [kBytes][1B tag][value bytes]]`, tags 0=null 1=bool 2=int64 3=float64
/// 4=string 5=list 6=object (recursive).
///
/// `NSNull()` is used as the in-memory null marker (not Swift `nil`) because
/// `dict[k] = nil` deletes the key in a `[String: Any]` dictionary instead of
/// storing a null value — Kotlin's `Map<String, Any?>` has no such gotcha.
void _emitSwiftAnyMapHelpers(CodeWriter writer, BridgeSpec spec) {
  final hasAnyMap = spec.functions.any((f) => f.returnType.isAnyMap || f.params.any((p) => p.type.isAnyMap)) || spec.properties.any((p) => p.type.isAnyMap);
  if (!hasAnyMap) return;
  writer.line('// NitroAnyMap binary codec — [4B payload_len][4B count][entries: [4B kLen][kBytes][NitroAnyValue]]');
  writer.line('// NitroAnyValue wire: [1B tag][value]. Tags: 0=null 1=bool 2=int64 3=float64 4=string 5=list 6=object.');
  writer.line('private func _nitroWriteAnyValue(_ payload: inout Data, _ v: Any) {');
  writer.line(r"    func writeLE32(_ v: Int32) { var lv = v.littleEndian; payload.append(contentsOf: withUnsafeBytes(of: &lv) { Data($0) }) }");
  writer.line(r"    func writeLE64(_ v: Int64) { var lv = v.littleEndian; payload.append(contentsOf: withUnsafeBytes(of: &lv) { Data($0) }) }");
  writer.line('    func writeStr(_ s: String) { let b = s.data(using: .utf8) ?? Data(); writeLE32(Int32(b.count)); payload.append(b) }');
  writer.line('    if v is NSNull {');
  writer.line('        payload.append(0)');
  writer.line('    } else if let bv = v as? Bool {');
  writer.line('        payload.append(1); payload.append(bv ? 1 : 0)');
  writer.line('    } else if let iv = v as? Int64 {');
  writer.line('        payload.append(2); writeLE64(iv)');
  writer.line('    } else if let iv = v as? Int {');
  writer.line('        payload.append(2); writeLE64(Int64(iv))');
  writer.line('    } else if let dv = v as? Double {');
  writer.line('        payload.append(3); writeLE64(Int64(bitPattern: dv.bitPattern))');
  writer.line('    } else if let sv = v as? String {');
  writer.line('        payload.append(4); writeStr(sv)');
  writer.line('    } else if let lv = v as? [Any] {');
  writer.line('        payload.append(5); writeLE32(Int32(lv.count)); for item in lv { _nitroWriteAnyValue(&payload, item) }');
  writer.line('    } else if let mv = v as? [String: Any] {');
  writer.line('        payload.append(6); writeLE32(Int32(mv.count)); for (k, vv) in mv { writeStr(k); _nitroWriteAnyValue(&payload, vv) }');
  writer.line('    } else {');
  writer.line('        payload.append(0) // unsupported type — encode as null rather than crash');
  writer.line('    }');
  writer.line('}');
  writer.blankLine();
  writer.line('private func _nitroReadAnyValue(_ data: Data, _ pos: inout Int) -> Any {');
  writer.line(r"    func readLE32() -> Int { let v = data[pos..<(pos+4)].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }; pos += 4; return v }");
  writer.line(r"    func readLE64() -> Int64 { let v = data[pos..<(pos+8)].withUnsafeBytes { Int64(bitPattern: $0.loadUnaligned(as: UInt64.self).littleEndian) }; pos += 8; return v }");
  writer.line('    func readStr() -> String { let len = readLE32(); let s = String(data: data[pos..<(pos+len)], encoding: .utf8) ?? ""; pos += len; return s }');
  writer.line('    let tag = data[pos]; pos += 1');
  writer.line('    switch tag {');
  writer.line('    case 0: return NSNull()');
  writer.line('    case 1: let b = data[pos] != 0; pos += 1; return b');
  writer.line('    case 2: return readLE64()');
  writer.line('    case 3: return Double(bitPattern: UInt64(bitPattern: readLE64()))');
  writer.line('    case 4: return readStr()');
  writer.line('    case 5:');
  writer.line('        let count = readLE32()');
  writer.line('        var arr: [Any] = []');
  writer.line('        for _ in 0..<count { arr.append(_nitroReadAnyValue(data, &pos)) }');
  writer.line('        return arr');
  writer.line('    case 6:');
  writer.line('        let count = readLE32()');
  writer.line('        var obj: [String: Any] = [:]');
  writer.line('        for _ in 0..<count { let k = readStr(); obj[k] = _nitroReadAnyValue(data, &pos) }');
  writer.line('        return obj');
  writer.line('    default:');
  writer.line('        return NSNull()');
  writer.line('    }');
  writer.line('}');
  writer.blankLine();
  writer.line('private func _nitroEncodeAnyMapBinary(_ m: [String: Any]) -> UnsafeMutablePointer<UInt8>? {');
  writer.line('    var payload = Data()');
  writer.line(r"    func writeLE32(_ v: Int32) { var lv = v.littleEndian; payload.append(contentsOf: withUnsafeBytes(of: &lv) { Data($0) }) }");
  writer.line('    writeLE32(Int32(m.count))');
  writer.line('    for (k, v) in m {');
  writer.line('        let kb = k.data(using: .utf8) ?? Data(); writeLE32(Int32(kb.count)); payload.append(kb)');
  writer.line('        _nitroWriteAnyValue(&payload, v)');
  writer.line('    }');
  writer.line('    var lenLE = Int32(payload.count).littleEndian');
  writer.line('    let total = 4 + payload.count');
  writer.line('    guard let buf = malloc(total) else { return nil }');
  writer.line(r"    withUnsafeBytes(of: &lenLE) { memcpy(buf, $0.baseAddress!, 4) }");
  writer.line(r"    payload.withUnsafeBytes { memcpy(buf.advanced(by: 4), $0.baseAddress!, payload.count) }");
  writer.line('    return buf.assumingMemoryBound(to: UInt8.self)');
  writer.line('}');
  writer.line('private func _nitroDecodeAnyMapBinary(_ ptr: UnsafeMutablePointer<UInt8>) -> [String: Any] {');
  writer.line('    let payLen = Int(UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self).littleEndian)');
  writer.line('    let data = Data(bytes: ptr.advanced(by: 4), count: payLen)');
  writer.line('    var pos = 0');
  writer.line(r"    func readLE32() -> Int { let v = data[pos..<(pos+4)].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }; pos += 4; return v }");
  writer.line('    func readStr() -> String { let len = readLE32(); let s = String(data: data[pos..<(pos+len)], encoding: .utf8) ?? ""; pos += len; return s }');
  writer.line('    let count = readLE32(); var result = [String: Any]()');
  writer.line('    for _ in 0..<count {');
  writer.line('        let k = readStr()');
  writer.line('        result[k] = _nitroReadAnyValue(data, &pos)');
  writer.line('    }');
  writer.line('    return result');
  writer.line('}');
  writer.blankLine();
}

void _emitSwiftTypedDataHelpers(CodeWriter writer, BridgeSpec spec) {
  if (spec.functions.any((f) => f.returnType.isTypedData)) {
    writer.line('private func _nitroCopyTypedDataReturn(_ bytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let headerSize = MemoryLayout<Int64>.size');
    writer.line('    let byteLength = bytes.count');
    writer.line('    guard let raw = malloc(byteLength + headerSize) else { return nil }');
    writer.line('    raw.storeBytes(of: Int64(byteLength), as: Int64.self)');
    writer.line('    if let base = bytes.baseAddress, byteLength > 0 {');
    writer.line('        memcpy(raw.advanced(by: headerSize), base, byteLength)');
    writer.line('    }');
    writer.line('    return raw.bindMemory(to: UInt8.self, capacity: byteLength + headerSize)');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroCopyTypedDataArrayReturn<T>(_ values: [T]) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    return values.withUnsafeBufferPointer { buffer in');
    writer.line('        _nitroCopyTypedDataReturn(UnsafeRawBufferPointer(buffer))');
    writer.line('    }');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroMakeZeroCopyTypedDataReturn(_ bytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    let headerSize = MemoryLayout<Int64>.size * 3');
    writer.line('    let byteLength = bytes.count');
    writer.line('    guard let raw = malloc(byteLength + headerSize) else { return nil }');
    writer.line('    raw.storeBytes(of: Int64(byteLength), as: Int64.self)');
    writer.line('    let payload = raw.advanced(by: headerSize)');
    writer.line('    raw.advanced(by: MemoryLayout<Int64>.size).storeBytes(of: Int64(Int(bitPattern: payload)), as: Int64.self)');
    writer.line('    raw.advanced(by: MemoryLayout<Int64>.size * 2).storeBytes(of: Int64(0), as: Int64.self)');
    writer.line('    if let base = bytes.baseAddress, byteLength > 0 {');
    writer.line('        memcpy(payload, base, byteLength)');
    writer.line('    }');
    writer.line('    return raw.bindMemory(to: UInt8.self, capacity: byteLength + headerSize)');
    writer.line('}');
    writer.blankLine();
    writer.line('private func _nitroMakeZeroCopyTypedDataArrayReturn<T>(_ values: [T]) -> UnsafeMutablePointer<UInt8>? {');
    writer.line('    return values.withUnsafeBufferPointer { buffer in');
    writer.line('        _nitroMakeZeroCopyTypedDataReturn(UnsafeRawBufferPointer(buffer))');
    writer.line('    }');
    writer.line('}');
    writer.blankLine();
  }
}
