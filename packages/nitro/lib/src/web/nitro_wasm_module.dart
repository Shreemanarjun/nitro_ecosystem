import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../shared/nitro_bytes.dart';

/// The Emscripten `Module` object of a loaded nitro WASM module.
///
/// Exported C symbols live on it as `_<c_symbol>` properties — the glue's
/// `assignWasmExports` maps real names onto the Module object, whereas
/// `Module.wasmExports` carries minified names at -O2/-O3 and must not be
/// bound.
extension type EmscriptenModule(JSObject _) implements JSObject {
  /// The current heap view. Re-read per operation — `ALLOW_MEMORY_GROWTH`
  /// swaps the backing ArrayBuffer and stale views detach.
  @JS('HEAPU8')
  external JSUint8Array get heapU8;

  /// Adds a JS function to the module's function table and returns its index
  /// (usable as a C function pointer). Requires `-sALLOW_TABLE_GROWTH` and
  /// `addFunction` in `EXPORTED_RUNTIME_METHODS`.
  external int addFunction(JSFunction f, String sig);

  /// Removes a previously added function-table entry.
  external void removeFunction(int fnPtr);
}

// Cached JS constructors for the int64 <-> BigInt boundary (one JS call each).
final JSFunction _jsNumber = globalContext.getProperty('Number'.toJS)! as JSFunction;
final JSFunction _jsBigInt = globalContext.getProperty('BigInt'.toJS)! as JSFunction;

/// Largest magnitude a JS number represents exactly (2^53 - 1). Beyond this,
/// `Number(aBigInt)` silently rounds.
const int _maxExactInJsNumber = 9007199254740991;

/// Dart int → JS BigInt, for `int64_t` parameters.
///
/// `v.toJS` makes a JS number, so `BigInt(v.toJS)` would round past 2^53
/// before the BigInt exists. Large magnitudes go through `BigInt("…")`.
JSAny jsI64(int v) {
  if (v >= -_maxExactInJsNumber && v <= _maxExactInJsNumber) {
    return _jsBigInt.callAsFunction(null, v.toJS)!;
  }
  return _jsBigInt.callAsFunction(null, v.toString().toJS)!;
}

/// JS BigInt (or number) → Dart int, for `int64_t` returns and callback args.
///
/// Exact over the full int64 range on dart2wasm; 53-bit on dart2js, where a
/// Dart int is a JS double.
int dartI64(JSAny? v) {
  if (v == null) return 0;
  if (v.typeofEquals('number')) return (v as JSNumber).toDartDouble.toInt();

  // Fast path: values inside the exact-double range convert losslessly.
  final asDouble = (_jsNumber.callAsFunction(null, v)! as JSNumber).toDartDouble;
  if (asDouble >= -_maxExactInJsNumber && asDouble <= _maxExactInJsNumber) {
    return asDouble.toInt();
  }

  // `Number(bigint)` rounds past 2^53; decimal text is lossless.
  return BigInt.parse(v.toString()).toSigned(64).toInt();
}

/// A loaded nitro WASM module: the Emscripten Module object plus typed heap
/// I/O and the module-allocator entry points generated bridges rely on.
///
/// All heap access is bulk (`set`/`slice`) — per-element access from Dart is a
/// JS call per byte under dart2wasm, and cached views detach on memory growth.
final class NitroWasmModule {
  /// The nitro library name this module was registered under (`@NitroModule.lib`).
  final String libName;

  /// The raw Emscripten Module object.
  final EmscriptenModule module;

  NitroWasmModule(this.libName, this.module);

  // ── Export invocation ──────────────────────────────────────────────────────

  /// Calls the exported C symbol [cSymbol] (without the leading underscore)
  /// with pre-converted JS arguments.
  JSAny? call(String cSymbol, List<JSAny?> args) {
    if (!providesSymbol(cSymbol)) {
      throw StateError(
        '$libName: WASM module has no export "_$cSymbol". The .wasm/.js '
        'artifacts are stale — rebuild them (web/build_web.sh) after '
        '`nitrogen generate`.',
      );
    }
    return module.callMethodVarArgs('_$cSymbol'.toJS, args);
  }

  /// True when the module exports [cSymbol].
  bool providesSymbol(String cSymbol) => module.hasProperty('_$cSymbol'.toJS).toDart;

  // ── Heap I/O (bulk, growth-safe) ───────────────────────────────────────────

  /// Copies [len] bytes at [ptr] out of the module heap.
  Uint8List readBytes(int ptr, int len) {
    if (len == 0) return Uint8List(0);
    final heap = module.heapU8;
    return (heap.callMethod('slice'.toJS, ptr.toJS, (ptr + len).toJS) as JSUint8Array).toDart;
  }

  /// Copies [bytes] into the module heap at [ptr] in one bulk write.
  void writeBytes(int ptr, Uint8List bytes) {
    if (bytes.isEmpty) return;
    module.heapU8.callMethod<JSAny?>('set'.toJS, bytes.toJS, ptr.toJS);
  }

  int readI32(int ptr) => ByteData.sublistView(readBytes(ptr, 4)).getInt32(0, Endian.little);

  int readU32(int ptr) => ByteData.sublistView(readBytes(ptr, 4)).getUint32(0, Endian.little);

  int readI64(int ptr) => getInt64LE(ByteData.sublistView(readBytes(ptr, 8)), 0);

  double readF64(int ptr) => ByteData.sublistView(readBytes(ptr, 8)).getFloat64(0, Endian.little);

  int readU8(int ptr) => readBytes(ptr, 1)[0];

  /// Reads a framed buffer (`[4B len][payload]`) at [ptr] — the standard
  /// record/variant/map envelope — as one bulk copy of the whole frame.
  Uint8List readFramed(int ptr) {
    final len = readI32(ptr);
    return readBytes(ptr, 4 + len);
  }

  /// Decodes a NUL-terminated C string at [ptr] (chunked scan — avoids a JS
  /// call per byte). Preserves a leading BOM, tolerates malformed UTF-8.
  String readCString(int ptr) {
    if (ptr == 0) return '';
    const chunk = 64;
    final collected = BytesBuilder(copy: false);
    var base = ptr;
    while (true) {
      final bytes = readBytes(base, chunk);
      final nul = bytes.indexOf(0);
      if (nul >= 0) {
        collected.add(Uint8List.sublistView(bytes, 0, nul));
        break;
      }
      collected.add(bytes);
      base += chunk;
    }
    return decodeUtf8NoBomStrip(collected.takeBytes());
  }

  /// Encodes [s] as NUL-terminated UTF-8 bytes (not yet in the heap — copy in
  /// via a `WasmArena` or [writeBytes]).
  static Uint8List encodeCString(String s) {
    final utf8 = const Utf8Encoder().convert(s);
    final out = Uint8List(utf8.length + 1);
    out.setRange(0, utf8.length, utf8);
    return out;
  }

  // ── Allocators ─────────────────────────────────────────────────────────────

  /// Dart-owned scratch memory (Emscripten `malloc`). Pair with [free].
  int malloc(int byteCount) {
    final p = dartI64(call('malloc', [byteCount.toJS]));
    if (p == 0) {
      throw ArgumentError('$libName: WASM malloc($byteCount) failed');
    }
    return p;
  }

  /// Frees a [malloc] allocation.
  void free(int ptr) {
    if (ptr != 0) call('free', [ptr.toJS]);
  }

  /// The module's `<lib>_nitro_alloc` — for buffers whose ownership transfers
  /// to native code (the C side frees them with its own `free`).
  /// `size_t`/`void*` are i32 on wasm32 — plain JS numbers, never BigInt.
  int nitroAlloc(int byteCount) {
    final p = dartI64(call('${libName}_nitro_alloc', [byteCount.toJS]));
    if (p == 0) {
      throw ArgumentError('$libName: ${libName}_nitro_alloc($byteCount) failed');
    }
    return p;
  }

  /// Copies [s] into a `<lib>_nitro_alloc`'d NUL-terminated buffer — for
  /// values whose ownership transfers to native (e.g. callback string
  /// returns, which the bridge frees with its own `free`).
  int nitroAllocCString(String s) {
    final bytes = encodeCString(s);
    final p = nitroAlloc(bytes.length);
    writeBytes(p, bytes);
    return p;
  }

  /// Copies [bytes] into a `<lib>_nitro_alloc`'d buffer — for framed payloads
  /// whose ownership transfers to native, such as a `@HybridRecord` returned
  /// from a Dart callback. The C side frees it with its own free.
  int nitroAllocBytes(Uint8List bytes) {
    final p = nitroAlloc(bytes.length);
    writeBytes(p, bytes);
    return p;
  }

  /// The module's `<lib>_nitro_free` — frees native-owned returns (strings,
  /// framed buffers) that crossed with ownership transfer to Dart.
  void nitroFree(int ptr) {
    if (ptr != 0) call('${libName}_nitro_free', [ptr.toJS]);
  }

  // ── Function table ─────────────────────────────────────────────────────────

  /// Adds [f] to the module function table; the returned index is a C function
  /// pointer. [signature] uses Emscripten sig letters (`v`=void, `i`=i32,
  /// `j`=i64/BigInt, `d`=f64), return type first.
  int addFunction(JSFunction f, String signature) => module.addFunction(f, signature);

  /// Releases a function-table entry created by [addFunction].
  ///
  /// No-op when the module was linked without `removeFunction` in
  /// `EXPORTED_RUNTIME_METHODS`: leaking a table slot beats throwing out of
  /// the release microtask, far from the callback that caused it.
  void removeFunction(int fnPtr) {
    if (!module.has('removeFunction')) return;
    module.removeFunction(fnPtr);
  }
}
