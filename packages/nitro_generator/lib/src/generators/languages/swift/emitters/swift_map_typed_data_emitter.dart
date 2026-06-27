part of '../swift_generator.dart';

void _emitSwiftMapHelpers(CodeWriter writer, BridgeSpec spec) {
// Emit binary map helpers when any map types are used.
final hasMapTypes = spec.functions.any((f) => f.returnType.isMap || f.params.any((p) => p.type.isMap))
    || spec.properties.any((p) => p.type.isMap);
if (hasMapTypes) {
  writer.line('// Binary map encode/decode — [4B payload_len][4B count][entries: [4B kLen][kBytes][1B tag][vBytes]]');
  writer.line('// Type tags: 1=int64, 2=float64, 3=bool, 4=string');
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
  writer.line('        default: let vLen = readLE32(); result[k] = String(data: data[pos..<(pos+vLen)], encoding: .utf8); pos += vLen');
  writer.line('        }');
  writer.line('    }');
  writer.line('    return result');
  writer.line('}');
  writer.blankLine();
}

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
