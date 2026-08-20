import 'dart:convert';
import 'dart:typed_data';

/// True when compiling for the web (dart2js or dart2wasm). A compile-time
/// constant, so each compiler tree-shakes the other branch below.
const bool kNitroWeb = bool.fromEnvironment('dart.library.js_interop');

/// Reads a little-endian int64 at [offset].
///
/// dart2js has no `ByteData.getInt64`; assemble from two 32-bit halves there.
/// Exact on the VM and dart2wasm; 53-bit fidelity on dart2js (where Dart ints
/// are already 53-bit).
int getInt64LE(ByteData data, int offset) {
  if (kNitroWeb) {
    final lo = data.getUint32(offset, Endian.little);
    final hi = data.getInt32(offset + 4, Endian.little);
    return hi * 0x100000000 + lo;
  }
  return data.getInt64(offset, Endian.little);
}

/// Writes a little-endian int64 at [offset]. See [getInt64LE] for the
/// per-compiler contract.
void setInt64LE(ByteData data, int offset, int value) {
  if (kNitroWeb) {
    // Arithmetic, not bitwise: dart2js truncates bitwise operands to 32 bits,
    // and double division would lose precision for big int64s on dart2wasm.
    // Dart's % is non-negative for a positive divisor, so lo is the unsigned
    // low half and (value - lo) is exactly divisible.
    final lo = value % 0x100000000;
    final hi = (value - lo) ~/ 0x100000000;
    data.setUint32(offset, lo, Endian.little);
    data.setInt32(offset + 4, hi, Endian.little);
    return;
  }
  data.setInt64(offset, value, Endian.little);
}

const utf8DecoderAllowMalformed = Utf8Decoder(allowMalformed: true);

/// Decodes UTF-8 bytes to a Dart String without stripping leading U+FEFF.
/// dart:convert's Utf8Decoder treats a leading BOM (U+FEFF / 0xEF 0xBB 0xBF)
/// as a stream signature and drops it. Bridge strings are raw data, not
/// streams.
///
/// Rather than hand-roll a per-byte code-point loop, use the fast native
/// `Utf8Decoder`: count and strip any leading BOM byte-triples so the decoder
/// never sees a BOM to drop, decode the remainder in one pass, then re-prepend
/// exactly the U+FEFFs that were removed. Correct for any number of leading
/// BOMs; the common (no-BOM) case is a single decoder call.
String decodeUtf8NoBomStrip(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  var bomBytes = 0;
  while (bomBytes + 3 <= bytes.length &&
      bytes[bomBytes] == 0xEF &&
      bytes[bomBytes + 1] == 0xBB &&
      bytes[bomBytes + 2] == 0xBF) {
    bomBytes += 3;
  }
  final decoded = utf8DecoderAllowMalformed.convert(bytes, bomBytes);
  if (bomBytes == 0) return decoded;
  return String.fromCharCode(0xFEFF) * (bomBytes ~/ 3) + decoded;
}
