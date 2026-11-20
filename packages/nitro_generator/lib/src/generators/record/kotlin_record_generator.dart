part of '../record_generator.dart';

// ── Kotlin generator ────────────────────────────────────────────────────────

/// Per-file helpers for the record codec: the stream `encode()` writes into and
/// the string read. Every generated Kotlin file has its own package, so one
/// top-level declaration per file cannot collide.
///
/// It is still a `ByteArrayOutputStream`, so the `writeFieldsTo(out, buf)`
/// contract shared with the struct, variant and function emitters is unchanged.
/// A plain stream costs a lock, a scratch buffer and three calls per value —
/// about 100 ns per field on ART; this writes the bytes into its own array.
const _kotlinRecordOut = '''
/** Record encode target: little-endian values written straight into the stream's array. */
class NitroRecordOut(size: Int) : java.io.ByteArrayOutputStream(size) {
    private fun room(n: Int) { if (count + n > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, count + n)) }
    fun putByte(v: Int) { room(1); buf[count++] = v.toByte() }
    fun putInt32(v: Int) {
        room(4); val b = buf; val i = count
        b[i] = v.toByte(); b[i + 1] = (v shr 8).toByte(); b[i + 2] = (v shr 16).toByte(); b[i + 3] = (v shr 24).toByte()
        count = i + 4
    }
    fun putInt64(v: Long) {
        room(8); val b = buf; val i = count
        b[i] = v.toByte(); b[i + 1] = (v shr 8).toByte(); b[i + 2] = (v shr 16).toByte(); b[i + 3] = (v shr 24).toByte()
        b[i + 4] = (v shr 32).toByte(); b[i + 5] = (v shr 40).toByte(); b[i + 6] = (v shr 48).toByte(); b[i + 7] = (v shr 56).toByte()
        count = i + 8
    }
    fun putFloat64(v: Double) = putInt64(java.lang.Double.doubleToRawLongBits(v))
    // A whole list: one capacity check and a local write index. On ART this is
    // 2.6x faster than putInt64 per item, and get(k) 1.6x faster than an
    // iterator; a list without O(1) get is iterated.
    private inline fun <T> putAll(v: List<T>, bits: (T) -> Long) {
        val n = v.size; room(n * 8); val b = buf; var i = count
        val items = if (v is java.util.RandomAccess) null else v.iterator()
        for (k in 0 until n) {
            val x = bits(if (items == null) v[k] else items.next())
            b[i] = x.toByte(); b[i + 1] = (x shr 8).toByte(); b[i + 2] = (x shr 16).toByte(); b[i + 3] = (x shr 24).toByte()
            b[i + 4] = (x shr 32).toByte(); b[i + 5] = (x shr 40).toByte(); b[i + 6] = (x shr 48).toByte(); b[i + 7] = (x shr 56).toByte()
            i += 8
        }
        count = i
    }
    // A short ASCII string is copied char by char (16 chars: 103 -> 23 ns on
    // ART); past 64 chars, and for any other text, the platform encoder wins.
    fun putString(s: String) {
        val n = s.length
        if (n <= 64) {
            room(4 + n); val b = buf; val at = count + 4
            var k = 0
            while (k < n) { val c = s[k].code; if (c >= 0x80) break; b[at + k] = c.toByte(); k++ }
            if (k == n) { putInt32(n); count += n; return }
        }
        val utf8 = s.toByteArray(Charsets.UTF_8); putInt32(utf8.size); write(utf8, 0, utf8.size)
    }
    // A list this file's decoder produced is a view of an array: one bulk put,
    // where get(k) would box every item.
    fun putInt64s(v: List<Long>) {
        if (v is NitroLongList) { val n = v.a.size * 8; room(n); java.nio.ByteBuffer.wrap(buf, count, n).order(java.nio.ByteOrder.LITTLE_ENDIAN).asLongBuffer().put(v.a); count += n }
        else putAll(v) { it }
    }
    fun putFloat64s(v: List<Double>) {
        if (v is NitroDoubleList) { val n = v.a.size * 8; room(n); java.nio.ByteBuffer.wrap(buf, count, n).order(java.nio.ByteOrder.LITTLE_ENDIAN).asDoubleBuffer().put(v.a); count += n }
        else putAll(v) { java.lang.Double.doubleToRawLongBits(it) }
    }
}

/** A decoded `List<Long>`: a read-only view of the array it was read into. */
class NitroLongList(@JvmField val a: LongArray) : AbstractList<Long>(), java.util.RandomAccess {
    override val size: Int get() = a.size
    override fun get(index: Int): Long = a[index]
}

/** A decoded `List<Double>`: a read-only view of the array it was read into. */
class NitroDoubleList(@JvmField val a: DoubleArray) : AbstractList<Double>(), java.util.RandomAccess {
    override val size: Int get() = a.size
    override fun get(index: Int): Double = a[index]
}

/**
 * Record decode cursor over a heap array. On ART a ByteBuffer accessor costs
 * about four times a read from the array (measured); a truncated record still
 * ends in an exception, from the array's own bounds check.
 */
class NitroRecordIn(@JvmField val a: ByteArray, @JvmField var p: Int) {
    fun byte(): Int = a[p++].toInt()
    fun int32(): Int {
        val a = a; val i = p; p = i + 4
        return (a[i].toInt() and 0xFF) or ((a[i + 1].toInt() and 0xFF) shl 8) or ((a[i + 2].toInt() and 0xFF) shl 16) or (a[i + 3].toInt() shl 24)
    }
    fun int64(): Long {
        val a = a; val i = p; p = i + 8
        return (a[i].toLong() and 0xFF) or ((a[i + 1].toLong() and 0xFF) shl 8) or ((a[i + 2].toLong() and 0xFF) shl 16) or ((a[i + 3].toLong() and 0xFF) shl 24) or
            ((a[i + 4].toLong() and 0xFF) shl 32) or ((a[i + 5].toLong() and 0xFF) shl 40) or ((a[i + 6].toLong() and 0xFF) shl 48) or (a[i + 7].toLong() shl 56)
    }
    fun float64(): Double = java.lang.Double.longBitsToDouble(int64())
    fun string(): String {
        val len = int32(); val a = a; val from = p; val to = from + len
        // ASCII goes through the Latin-1 decoder: on ART the UTF-8 one is 1.1-1.6x
        // slower over the same bytes (most for short strings).
        var i = from
        while (i < to && a[i] >= 0) i++
        p = to
        return String(a, from, len, if (i == to) Charsets.ISO_8859_1 else Charsets.UTF_8)
    }
    fun bytes(): ByteArray { val n = int32(); val out = a.copyOfRange(p, p + n); p += n; return out }
    /** The next [n] bytes as a little-endian buffer, for one bulk read; the cursor moves past them. */
    fun take(n: Int): java.nio.ByteBuffer { val b = java.nio.ByteBuffer.wrap(a, p, n).order(java.nio.ByteOrder.LITTLE_ENDIAN); p += n; return b }
    /** Runs a decoder that takes a ByteBuffer (a struct, a record of another module) at the cursor. */
    inline fun <T> via(read: (java.nio.ByteBuffer) -> T): T {
        val b = java.nio.ByteBuffer.wrap(a).order(java.nio.ByteOrder.LITTLE_ENDIAN); b.position(p)
        val v = read(b); p = b.position(); return v
    }
}

/** Runs a cursor decoder on a ByteBuffer (heap or direct) and leaves the buffer past what it read. */
private inline fun <T> nitroDecode(buf: java.nio.ByteBuffer, read: (NitroRecordIn) -> T): T {
    val r = if (buf.hasArray()) NitroRecordIn(buf.array(), buf.arrayOffset() + buf.position())
            else NitroRecordIn(ByteArray(buf.remaining()).also { buf.duplicate().get(it) }, 0)
    val start = r.p
    val v = read(r)
    buf.position(buf.position() + (r.p - start))
    return v
}
''';

/// Generates `@Keep data class` declarations for every `@HybridRecord` type
/// into the Kotlin bridge file.  Each class also gets static `decode` /
/// `encode` helpers so callers never have to hand-roll ByteArray parsing.
String _generateKotlinRecords(BridgeSpec spec) {
  final localRecords = spec.nativeRecordTypes;
  if (localRecords.isEmpty) return '';
  final enumNames = spec.enums.map((e) => e.name).toSet();
  // Only this file's records take the cursor: each generated file has its own
  // package, so another module's record has its own NitroRecordIn class.
  final cursorRecords = localRecords.map((r) => r.name).toSet();

  final s = CodeWriter();
  s.writeln('// --- @HybridRecord Kotlin data classes (generated by Nitrogen) ---');
  s.writeln();
  _kotlinRecordOut.trim().split('\n').forEach(s.writeln);
  s.writeln();

  for (final rt in localRecords) {
    final fields = rt.fields.map((f) => 'val ${f.name}: ${_kotlinType(f, enumNames)}').join(', ');
    s.writeln('@androidx.annotation.Keep');
    s.writeln('data class ${rt.name}($fields) {');

    // --- companion: decodeFrom(buf) reads fields from a shared ByteBuffer cursor ---
    //                decode(bytes) wraps a standalone ByteArray (strips 4-byte prefix)
    s.writeln('    companion object {');
    s.writeln('        @JvmStatic fun decodeFrom(buf: java.nio.ByteBuffer): ${rt.name} = nitroDecode(buf) { decodeFrom(it) }');
    s.writeln('        @JvmStatic fun decodeFrom(r: NitroRecordIn): ${rt.name} {');
    for (final f in rt.fields) {
      s.writeln('            val ${f.name} = ${_kotlinReadExpr(f, enumNames, cursorRecords)}');
    }
    final ctorArgs = rt.fields.map((f) => f.name).join(', ');
    s.writeln('            return ${rt.name}($ctorArgs)');
    s.writeln('        }');
    final isNitroOpt = rt.name == 'NitroOptInt64' || rt.name == 'NitroOptFloat64' || rt.name == 'NitroOptBool';
    // The 4-byte length prefix is skipped; the NitroOpt records have none.
    s.writeln('        @JvmStatic fun decode(bytes: ByteArray): ${rt.name} = decodeFrom(NitroRecordIn(bytes, ${isNitroOpt ? 0 : 4}))');
    // --- fromJson() for Map<String, ${rt.name}> support (#2) ---
    final companionFromJsonFields = rt.fields
        .map((f) {
          final base = bareTypeName(f.dartType);
          switch (f.kind) {
            case RecordFieldKind.primitive:
              final kBase = bareTypeName(f.dartType);
              if (f.isNullable) {
                if (kBase == 'int') return '${f.name} = (map["${f.name}"] as Number?)?.toLong()';
                if (kBase == 'double') return '${f.name} = (map["${f.name}"] as Number?)?.toDouble()';
                if (kBase == 'bool') return '${f.name} = map["${f.name}"] as Boolean?';
                return '${f.name} = map["${f.name}"] as String?';
              }
              if (kBase == 'int') return '${f.name} = (map["${f.name}"] as Number).toLong()';
              if (kBase == 'double') return '${f.name} = (map["${f.name}"] as Number).toDouble()';
              if (kBase == 'bool') return '${f.name} = map["${f.name}"] as Boolean';
              return '${f.name} = map["${f.name}"] as String';
            case RecordFieldKind.enumValue:
              return f.isNullable ? '${f.name} = (map["${f.name}"] as Long?)?.let { $base.fromNative(it) }' : '${f.name} = $base.fromNative(map["${f.name}"] as Long)';
            case RecordFieldKind.recordObject:
              // @Suppress must be on the EXPRESSION, not on the named argument itself.
              return f.isNullable
                  ? '${f.name} = (map["${f.name}"] as? Map<*, *>)?.let { $base.fromJson(@Suppress("UNCHECKED_CAST") (it as Map<String, Any?>)) }'
                  : '${f.name} = $base.fromJson(@Suppress("UNCHECKED_CAST") (map["${f.name}"] as Map<String, Any?>))';
            case RecordFieldKind.struct:
              // @HybridStruct in a record — structs don't have fromJson.
              // fromJson is used for Map<String,@HybridRecord>; struct fields not supported there.
              return '${f.name} = ${f.isNullable ? "null" : "throw UnsupportedOperationException(\"Struct field \\'${f.name}\\' cannot be reconstructed from JSON — use binary bridge instead\")"}';
            default:
              return '${f.name} = @Suppress("UNCHECKED_CAST") (map["${f.name}"] as ${_kotlinType(f, enumNames)})';
          }
        })
        .join(',\n                ');
    s.writeln('        @Suppress("UNCHECKED_CAST")');
    s.writeln('        @JvmStatic fun fromJson(map: Map<String, Any?>): ${rt.name} = ${rt.name}(');
    s.writeln('                $companionFromJsonFields');
    s.writeln('        )');
    // Thread-local encode buffers (#8 perf): avoid per-call ByteArrayOutputStream allocation.
    s.writeln('        // Thread-local encode buffers — avoids allocation per bridge call.');
    s.writeln('        val _tlsOut = ThreadLocal.withInitial { NitroRecordOut(${_recordBytesHint(rt)}) }');
    s.writeln('        val _tlsBuf = ThreadLocal.withInitial { java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN) }');
    s.writeln('    }');
    // ── Built-in NitroNullable types: nullable getter + single-arg constructor ──
    switch (rt.name) {
      case 'NitroNullableInt':
        s.writeln('    constructor(v: Long?) : this(v != null, v ?: 0L)');
        s.writeln('    val nullable: Long? get() = if (hasValue) value else null');
      case 'NitroNullableDouble':
        s.writeln('    constructor(v: Double?) : this(v != null, v ?: 0.0)');
        s.writeln('    val nullable: Double? get() = if (hasValue) value else null');
      case 'NitroNullableBool':
        s.writeln('    constructor(v: Boolean?) : this(v != null, v ?: false)');
        s.writeln('    val nullable: Boolean? get() = if (hasValue) value else null');
    }
    // ── NitroOpt* packed types: nullable getter + single-arg constructor ──
    // These use [1B hasValue][N bytes value] with NO 4-byte length prefix.
    switch (rt.name) {
      case 'NitroOptInt64':
        s.writeln('    constructor(v: Long?) : this(v != null, v ?: 0L)');
        s.writeln('    val nullable: Long? get() = if (hasValue) value else null');
      case 'NitroOptFloat64':
        s.writeln('    constructor(v: Double?) : this(v != null, v ?: 0.0)');
        s.writeln('    val nullable: Double? get() = if (hasValue) value else null');
      case 'NitroOptBool':
        s.writeln('    constructor(v: Boolean?) : this(v != null, v ?: false)');
        s.writeln('    val nullable: Boolean? get() = if (hasValue) value else null');
    }
    s.writeln();

    // --- writeFieldsTo: writes fields without length prefix (for use inside lists) ---
    s.writeln('    fun writeFieldsTo(out: java.io.ByteArrayOutputStream, buf: java.nio.ByteBuffer) {');
    // encode() hands in a NitroRecordOut; the stream-and-scratch path remains
    // for callers that pass a plain stream (struct, variant and list emitters,
    // or a record of another module's package).
    s.writeln('        val fast = out as? NitroRecordOut');
    s.writeln('        fun writeInt(v: Long) { if (fast != null) fast.putInt64(v) else { buf.clear(); buf.putLong(v); out.write(buf.array()) } }');
    s.writeln('        fun writeInt32(v: Int) { if (fast != null) fast.putInt32(v) else { buf.clear(); buf.putInt(v); out.write(buf.array(), 0, 4) } }');
    s.writeln('        fun writeDouble(v: Double) { if (fast != null) fast.putFloat64(v) else { buf.clear(); buf.putDouble(v); out.write(buf.array()) } }');
    s.writeln('        fun writeBool(v: Boolean) { if (fast != null) fast.putByte(if (v) 1 else 0) else out.write(if (v) 1 else 0) }');
    s.writeln('        fun writeString(v: String) { if (fast != null) fast.putString(v) else { val b = v.toByteArray(Charsets.UTF_8); writeInt32(b.size); out.write(b) } }');
    for (final f in rt.fields) {
      _kotlinWriteStmt(s, f);
    }
    s.writeln('    }');
    s.writeln();

    // NitroOpt* encode: NO 4-byte length prefix — fixed-size [1B hasValue][N bytes value].
    final isNitroOptEncode = rt.name == 'NitroOptInt64' || rt.name == 'NitroOptFloat64' || rt.name == 'NitroOptBool';
    if (isNitroOptEncode) {
      // Override decode(bytes) to NOT skip 4 bytes — bytes are the raw struct.
      s.writeln('    fun encode(): ByteArray {');
      s.writeln('        val out = _tlsOut.get()!!.also { it.reset() }');
      s.writeln('        val buf = _tlsBuf.get()!!');
      s.writeln('        writeFieldsTo(out, buf)');
      s.writeln('        return out.toByteArray()  // NO 4-byte length prefix');
      s.writeln('    }');
    } else {
      // --- encode to ByteArray (with 4-byte length prefix) ---
      // Thread-local buffers avoid per-call ByteArrayOutputStream/ByteBuffer allocation (#8 perf).
      s.writeln('    fun encode(): ByteArray {');
      s.writeln('        val out = _tlsOut.get()!!.also { it.reset() }');
      s.writeln('        val buf = _tlsBuf.get()!!');
      // The 4-byte prefix is reserved up front and patched in the result:
      // concatenating it afterwards copied the whole payload a second time.
      s.writeln('        out.write(buf.array(), 0, 4)');
      s.writeln('        writeFieldsTo(out, buf)');
      s.writeln('        val bytes = out.toByteArray()');
      s.writeln('        val n = bytes.size - 4');
      s.writeln('        bytes[0] = n.toByte(); bytes[1] = (n shr 8).toByte(); bytes[2] = (n shr 16).toByte(); bytes[3] = (n shr 24).toByte()');
      // The thread-local stream never shrinks: do not keep a large record's
      // worth of memory per thread for the life of the process.
      s.writeln('        if (bytes.size > 4 shl 20) _tlsOut.remove()');
      s.writeln('        return bytes');
      s.writeln('    }');
    }
    s.writeln();

    // --- toJson() / fromJson() for Map<String, @HybridRecord> support (#2) ---
    // Allows Kotlin bridge to serialize/deserialize when used as Map values.
    s.writeln('    // --- toJson/fromJson for Map<String, ${rt.name}> support ---');
    final toJsonFields = rt.fields
        .map((f) {
          switch (f.kind) {
            case RecordFieldKind.enumValue:
              return f.isNullable ? '"${f.name}" to ${f.name}?.nativeValue' : '"${f.name}" to ${f.name}.nativeValue';
            case RecordFieldKind.recordObject:
              return f.isNullable ? '"${f.name}" to ${f.name}?.toJson()' : '"${f.name}" to ${f.name}.toJson()';
            case RecordFieldKind.listPrimitive:
            case RecordFieldKind.listEnumValue:
            case RecordFieldKind.listRecordObject:
              return '"${f.name}" to ${f.name}';
            case RecordFieldKind.typedData:
              return '"${f.name}" to ${f.name}';
            case RecordFieldKind.struct:
              return '"${f.name}" to ${f.name}';
            default: // primitive
              return '"${f.name}" to ${f.name}';
          }
        })
        .join(', ');
    s.writeln('    fun toJson(): Map<String, Any?> = mapOf($toJsonFields)');
    s.writeln();

    s.writeln('}');
    s.writeln();
  }

  return s.toString();
}

String _kotlinType(BridgeRecordField f, Set<String> enumNames) {
  switch (f.kind) {
    case RecordFieldKind.primitive:
      return _kotlinBase(f.dartType) + (f.isNullable ? '?' : '');
    case RecordFieldKind.enumValue:
      final base = bareTypeName(f.dartType);
      return (enumNames.contains(base) ? base : 'Long') + (f.isNullable ? '?' : '');
    case RecordFieldKind.recordObject:
      final base = bareTypeName(f.dartType);
      return base + (f.isNullable ? '?' : '');
    // A nullable list is declared nullable: the codec reads and writes its
    // null tag, and a non-null declaration did not compile against it.
    case RecordFieldKind.listPrimitive:
      return 'List<${_kotlinBase(f.itemTypeName ?? 'int')}>${f.isNullable ? '?' : ''}';
    case RecordFieldKind.listEnumValue:
      final item = f.itemTypeName ?? 'Long';
      return 'List<${enumNames.contains(item) ? item : 'Long'}>${f.isNullable ? '?' : ''}';
    case RecordFieldKind.listRecordObject:
      return 'List<${f.itemTypeName}>${f.isNullable ? '?' : ''}';
    case RecordFieldKind.typedData:
      final kotlinType = _kotlinTypedDataType(bareTypeName(f.dartType));
      return kotlinType + (f.isNullable ? '?' : '');
    case RecordFieldKind.struct:
      return bareTypeName(f.dartType) + (f.isNullable ? '?' : '');
  }
}

String _kotlinTypedDataType(String dartType) {
  switch (dartType) {
    case 'Uint8List':
    case 'Int8List':
      return 'ByteArray';
    case 'Int16List':
    case 'Uint16List':
      return 'ShortArray';
    case 'Int32List':
    case 'Uint32List':
      return 'IntArray';
    case 'Int64List':
    case 'Uint64List':
      return 'LongArray';
    case 'Float32List':
      return 'FloatArray';
    case 'Float64List':
      return 'DoubleArray';
    default:
      return 'ByteArray';
  }
}

String _kotlinBase(String dartType) {
  final base = bareTypeName(dartType);
  switch (base) {
    case 'int':
      return 'Long';
    case 'double':
      return 'Double';
    case 'bool':
      return 'Boolean';
    case 'String':
      return 'String';
    default:
      return 'Long';
  }
}

String _kotlinReadExpr(BridgeRecordField f, Set<String> enumNames, Set<String> cursorRecords) {
  String nullable(String read) => f.isNullable ? '(if (r.byte() == 0) null else $read)' : read;
  // A record of this file reads from the cursor; anything else that decodes
  // itself (a struct, another module's record) takes a ByteBuffer.
  String nested(String type) => cursorRecords.contains(type) ? '$type.decodeFrom(r)' : 'r.via { $type.decodeFrom(it) }';
  String enumRead(String type) => enumNames.contains(type) ? '$type.fromNative(r.int64())' : 'r.int64()';
  switch (f.kind) {
    case RecordFieldKind.primitive:
      return nullable(_kotlinPrimRead(bareTypeName(f.dartType)));
    case RecordFieldKind.enumValue:
      return nullable(enumRead(bareTypeName(f.dartType)));
    case RecordFieldKind.recordObject:
    case RecordFieldKind.struct:
      return nullable(nested(bareTypeName(f.dartType)));
    // Nullable list fields are bracketed by a null tag, same as every other
    // nullable field — an absent list and an empty list are distinct.
    case RecordFieldKind.listPrimitive:
      final item = f.itemTypeName ?? 'int';
      // int/double/bool: read into a primitive array (one bulk get for the
      // 8-byte kinds) and expose it as a List — no box per element up front.
      final bulk = const {
        'int': 'run { val _a = LongArray(r.int32()); r.take(_a.size * 8).asLongBuffer().get(_a); NitroLongList(_a) }',
        'double': 'run { val _a = DoubleArray(r.int32()); r.take(_a.size * 8).asDoubleBuffer().get(_a); NitroDoubleList(_a) }',
        'bool': 'run { val _n = r.int32(); val _a = r.a; val _o = r.p; r.p += _n; BooleanArray(_n) { _a[_o + it].toInt() != 0 }.asList() }',
      }[item];
      return nullable(bulk ?? '(0 until r.int32()).map { ${_kotlinPrimRead(item)} }');
    case RecordFieldKind.listEnumValue:
      return nullable('(0 until r.int32()).map { ${enumRead(f.itemTypeName ?? 'Long')} }');
    case RecordFieldKind.listRecordObject:
      return nullable('(0 until r.int32()).map { ${nested(f.itemTypeName!)} }');
    case RecordFieldKind.typedData:
      return nullable(_kotlinTypedDataRead(bareTypeName(f.dartType)));
  }
}

String _kotlinTypedDataRead(String dartType) {
  // Wire format: [4B byteCount][byteCount bytes] — byte count, not element count.
  // Dart writes byte count via writeBlob(TypedData.buffer.asUint8List()).
  //
  // `run { }`, never `{ }()`: after the `else` of a nullable field's null check
  // the braces would be a block, and the call a compile error.
  //
  // Wider arrays are read through a typed view of the bytes in one bulk get
  // instead of one read per item.
  String bulk(String array, String view, int size) => 'run { val _len = r.int32(); val _a = $array(_len / $size); r.take(_len).$view().get(_a); _a }';
  switch (dartType) {
    case 'Int16List':
    case 'Uint16List':
      return bulk('ShortArray', 'asShortBuffer', 2);
    case 'Int32List':
    case 'Uint32List':
      return bulk('IntArray', 'asIntBuffer', 4);
    case 'Int64List':
    case 'Uint64List':
      return bulk('LongArray', 'asLongBuffer', 8);
    case 'Float32List':
      return bulk('FloatArray', 'asFloatBuffer', 4);
    case 'Float64List':
      return bulk('DoubleArray', 'asDoubleBuffer', 8);
    default: // Uint8List, Int8List
      return 'r.bytes()';
  }
}

/// A list field's body, behind the null tag when the field is nullable.
void _kotlinWriteListField(CodeWriter s, BridgeRecordField f, void Function(String accessor) body) {
  if (!f.isNullable) {
    body(f.name);
    return;
  }
  s.writeln('        writeBool(${f.name} != null)');
  s.writeln('        if (${f.name} != null) {');
  body('${f.name}!!');
  s.writeln('        }');
}

String _kotlinPrimRead(String base) => switch (base) {
  'double' => 'r.float64()',
  'bool' => '(r.byte() != 0)',
  'String' => 'r.string()',
  'Uint8List' || 'ByteArray' => 'r.bytes()',
  _ => 'r.int64()',
};

void _kotlinWriteStmt(CodeWriter s, BridgeRecordField f) {
  switch (f.kind) {
    case RecordFieldKind.primitive:
      final base = bareTypeName(f.dartType);
      if (f.isNullable) {
        s.writeln('        writeBool(${f.name} != null)');
        s.writeln('        ${f.name}?.let { ${_kotlinWriteCall(base, 'it')} }');
      } else {
        s.writeln('        ${_kotlinWriteCall(base, f.name)}');
      }
      break;
    case RecordFieldKind.enumValue:
      if (f.isNullable) {
        s.writeln('        writeBool(${f.name} != null)');
        s.writeln('        ${f.name}?.let { writeInt(it.nativeValue) }');
      } else {
        s.writeln('        writeInt(${f.name}.nativeValue)');
      }
      break;
    case RecordFieldKind.recordObject:
      if (f.isNullable) {
        s.writeln('        writeBool(${f.name} != null)');
        s.writeln('        ${f.name}?.writeFieldsTo(out, buf)');
      } else {
        s.writeln('        ${f.name}.writeFieldsTo(out, buf)');
      }
      break;
    case RecordFieldKind.listPrimitive:
      final base = f.itemTypeName ?? 'int';
      _kotlinWriteListField(s, f, (a) {
        s.writeln('        writeInt32($a.size)');
        s.writeln('        ${_kotlinBulkListWrite(base, a) ?? '$a.forEach { e -> ${_kotlinWriteCall(base, 'e')} }'}');
      });
      break;
    case RecordFieldKind.listEnumValue:
      _kotlinWriteListField(s, f, (a) {
        s.writeln('        writeInt32($a.size)');
        s.writeln('        $a.forEach { e -> writeInt(e.nativeValue) }');
      });
      break;
    case RecordFieldKind.listRecordObject:
      _kotlinWriteListField(s, f, (a) {
        s.writeln('        writeInt32($a.size)');
        s.writeln('        $a.forEach { e -> e.writeFieldsTo(out, buf) }');
      });
      break;
    case RecordFieldKind.typedData:
      final base = bareTypeName(f.dartType);
      if (f.isNullable) {
        s.writeln('        writeBool(${f.name} != null)');
        s.writeln('        ${f.name}?.let { ${_kotlinTypedDataWrite(base, 'it')} }');
      } else {
        s.writeln('        ${_kotlinTypedDataWrite(base, f.name)}');
      }
      break;
    case RecordFieldKind.struct:
      // @HybridStruct embedded inline — write via writeFieldsTo.
      if (f.isNullable) {
        s.writeln('        writeBool(${f.name} != null)');
        s.writeln('        ${f.name}?.writeFieldsTo(out, buf)');
      } else {
        s.writeln('        ${f.name}.writeFieldsTo(out, buf)');
      }
      break;
  }
}

String _kotlinTypedDataWrite(String dartType, String expr) {
  // Wire format: [4B byteCount][byteCount bytes] — must write BYTE count, not element count,
  // to match Dart's writeBlob which writes byteCount = TypedData.buffer.byteLength.
  // Use `run { }` instead of `{ }()` to prevent Kotlin trailing-lambda misparse.
  //
  // Wider arrays go through a typed view in one bulk put, then one write: a
  // write per element through the stream cost ~10 ns each (measured, JVM).
  String bulk(String view, int size) =>
      'run { writeInt32($expr.size * $size); '
      'val _bb = java.nio.ByteBuffer.allocate($expr.size * $size).order(java.nio.ByteOrder.LITTLE_ENDIAN); '
      '_bb.$view().put($expr); out.write(_bb.array()) }';
  switch (dartType) {
    case 'Int16List':
    case 'Uint16List':
      return bulk('asShortBuffer', 2);
    case 'Int32List':
    case 'Uint32List':
      return bulk('asIntBuffer', 4);
    case 'Int64List':
    case 'Uint64List':
      return bulk('asLongBuffer', 8);
    case 'Float32List':
      return bulk('asFloatBuffer', 4);
    case 'Float64List':
      return bulk('asDoubleBuffer', 8);
    default: // Uint8List, Int8List
      return 'run { writeInt32($expr.size); out.write($expr) }';
  }
}

/// A whole `List<int|double|bool>` staged in one buffer and written once, or
/// null for item types that are written one by one.
String? _kotlinBulkListWrite(String item, String a) {
  final words = 'java.nio.ByteBuffer.allocate($a.size * 8).order(java.nio.ByteOrder.LITTLE_ENDIAN)';
  return switch (item) {
    'int' =>
      'if (fast != null) fast.putInt64s($a) '
          'else { val _bb = $words; for (e in $a) _bb.putLong(e.toLong()); out.write(_bb.array()) }',
    'double' =>
      'if (fast != null) fast.putFloat64s($a) '
          'else { val _bb = $words; for (e in $a) _bb.putDouble(e); out.write(_bb.array()) }',
    'bool' => 'run { val _b = ByteArray($a.size); var _i = 0; for (e in $a) _b[_i++] = if (e) 1 else 0; out.write(_b) }',
    _ => null,
  };
}

String _kotlinWriteCall(String base, String expr) {
  switch (base) {
    case 'int':
      return 'writeInt($expr.toLong())';
    case 'double':
      return 'writeDouble($expr)';
    case 'bool':
      return 'writeBool($expr)';
    case 'String':
      return 'writeString($expr)';
    case 'Uint8List':
    case 'ByteArray':
      return 'writeInt32($expr.size); out.write($expr)';
    default:
      return 'writeInt($expr.toLong())';
  }
}

/// Returns a static byte-size estimate for one serialized instance of [rt].
/// Used to pre-size [ByteArrayOutputStream] in [encode] and list paths,
/// avoiding the default 32-byte initial buffer and subsequent grow copies.
///
/// Estimates per field kind:
///   int/double   → 8 bytes (+ 1 nullable tag)
///   bool         → 1 byte  (+ 1 nullable tag)
///   String       → 4 (len) + 32 (avg content) = 36 (+ 1 nullable tag)
///   nested record → 32 rough estimate (+ 1 nullable tag)
///   list         → 4 (count) + 8 * 4 avg items = 36
int _recordBytesHint(BridgeRecordType rt) {
  var total = 0;
  for (final f in rt.fields) {
    final nullableTag = f.isNullable ? 1 : 0;
    switch (f.kind) {
      case RecordFieldKind.primitive:
        final base = bareTypeName(f.dartType);
        switch (base) {
          case 'bool':
            total += nullableTag + 1;
          case 'String':
            total += nullableTag + 36;
          default: // int, double
            total += nullableTag + 8;
        }
      case RecordFieldKind.enumValue:
        total += nullableTag + 8;
      case RecordFieldKind.recordObject:
        total += nullableTag + 32;
      case RecordFieldKind.listPrimitive:
      case RecordFieldKind.listEnumValue:
      case RecordFieldKind.listRecordObject:
        total += 36; // 4-byte count + ~4 items * 8 bytes avg
      case RecordFieldKind.typedData:
        total += nullableTag + 68; // 4-byte count + ~64 bytes avg payload
      case RecordFieldKind.struct:
        total += nullableTag + 64; // struct fields inline, estimate 64 bytes
    }
  }
  return total > 0 ? total : 32;
}
