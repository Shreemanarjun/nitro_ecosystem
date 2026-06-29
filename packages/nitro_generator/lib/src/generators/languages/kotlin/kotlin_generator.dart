import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';
import '../../struct_generator.dart';
import 'emitters/kotlin_callback_emitter.dart';
import 'emitters/kotlin_function_emitter.dart';
import 'emitters/kotlin_property_emitter.dart';
import 'emitters/kotlin_stream_emitter.dart';
import 'emitters/kotlin_type_mapper.dart';
import 'emitters/kotlin_variant_emitter.dart';

class KotlinGenerator {
  static String generate(BridgeSpec spec) {
    if (spec.isTypeOnly) return _generateTypeOnly(spec);
    if (spec.androidImpl == null) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri)}\n'
          '// Android not targeted — no Kotlin bridge generated.\n';
    }

    final writer = CodeWriter();
    final mapper = KotlinTypeMapper.fromSpec(spec);
    final hasStreams = spec.streams.isNotEmpty;
    final hasBatchStreams = spec.streams.any((s) => s.isBatch);
    final hasAsyncFunctions = spec.functions.any((f) => f.isAsync || f.isNativeAsync);
    final hasNativeAsync = spec.functions.any((f) => f.isNativeAsync);

    // ── File header & imports ──────────────────────────────────────────────
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('package nitro.${spec.lib.replaceAll('-', '_')}_module');
    writer.blankLine();
    writer.line('import android.app.Activity');
    writer.line('import android.content.Context');
    writer.line('import androidx.annotation.Keep');
    if (hasStreams) {
      writer.line('import kotlinx.coroutines.flow.Flow');
      writer.line('import kotlinx.coroutines.launch');
      writer.line('import kotlinx.coroutines.CoroutineScope');
      writer.line('import kotlinx.coroutines.CoroutineStart');
      writer.line('import kotlinx.coroutines.Dispatchers');
      if (hasBatchStreams) writer.line('import kotlinx.coroutines.sync.withLock');
    }
    if (hasAsyncFunctions) writer.line('import kotlinx.coroutines.runBlocking');
    writer.blankLine();

    // ── Type declarations (enums / structs / records / variants) ──────────────────────
    final kotlinEnums = EnumGenerator.generateKotlin(spec);
    if (kotlinEnums.isNotEmpty) writer.raw(kotlinEnums);

    final kotlinStructs = StructGenerator.generateKotlin(spec);
    if (kotlinStructs.isNotEmpty) writer.raw(kotlinStructs);

    final kotlinRecords = RecordGenerator.generateKotlin(spec);
    if (kotlinRecords.isNotEmpty) writer.raw(kotlinRecords);

    // Emit @NitroVariant sealed class declarations in the bridge file.
    // Also emit RecordReader/RecordWriter helper classes needed by variant encode/decode.
    final hasVariants = spec.localVariants.isNotEmpty;
    final hasVariantBridge = spec.functions.any((f) {
      final ret = f.returnType.name.replaceFirst('?', '');
      return spec.isVariantName(ret) || f.params.any((p) => spec.isVariantName(p.type.name.replaceFirst('?', '')));
    });
    if (hasVariants) {
      final varWriter = CodeWriter();
      for (final variant in spec.localVariants) {
        KotlinVariantEmitter.emit(varWriter, variant, KotlinTypeMapper.fromSpec(spec));
      }
      writer.raw(varWriter.toString());
    }
    // Emit RecordReader/RecordWriter Kotlin helper classes when variant bridge functions exist.
    final hasResultFunctions = spec.functions.any((f) => f.isResult);
    if (hasVariantBridge || hasResultFunctions) {
      _emitKotlinBridgeHelpers(writer, hasVariantBridge: hasVariantBridge, hasResult: hasResultFunctions);
    }

    // Emit NitroAnyMap binary codec helper when any function uses NitroAnyMap.
    final hasAnyMap = spec.functions.any((f) =>
        f.returnType.isAnyMap || f.params.any((p) => p.type.isAnyMap));
    if (hasAnyMap) {
      _emitKotlinAnyMapHelper(writer);
    }

    // ── Interface ──────────────────────────────────────────────────────────
    writer.line('/**');
    writer.line(' * Contract for the [${spec.dartClassName}] module.');
    writer.line(' * Implement this in your Kotlin source code.');
    writer.line(' * Nitro may call this implementation from any JNI thread.');
    writer.line(' * Keep mutable state thread-safe or marshal work onto your own dispatcher.');
    writer.line(' */');
    writer.line('interface Hybrid${spec.dartClassName}Spec {');
    writer.line('    val applicationContext: Context get() = ${spec.dartClassName}JniBridge.applicationContext');
    writer.line('    val activity: Activity? get() = ${spec.dartClassName}JniBridge.activity');
    writer.blankLine();
    writer.line('    // Optional lifecycle hooks — override only what you need.');
    writer.line('    fun onAttached() {}');
    writer.line('    fun onDetached() {}');
    writer.line('    fun onActivityAttached(activity: Activity) {}');
    writer.line('    fun onActivityDetached() {}');
    writer.blankLine();

    for (final func in spec.functions) {
      if (func.lineNumber != null) {
        writer.line('    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
      }
      final retType = mapper.functionRetType(func);
      final params = func.params.map((p) => '${p.name}: ${mapper.paramType(p)}').join(', ');
      final suspend = (func.isAsync || func.isNativeAsync) ? 'suspend ' : '';
      writer.line('    ${suspend}fun ${func.dartName}($params): $retType');
    }

    for (final prop in spec.properties) {
      final kt = mapper.propertyType(prop.type.name);
      if (prop.hasSetter) {
        writer.line('    var ${prop.dartName}: $kt');
      } else {
        writer.line('    val ${prop.dartName}: $kt');
      }
    }

    for (final stream in spec.streams) {
      final itemType = mapper.type(stream.itemType.name, bridgeType: stream.itemType);
      writer.line('    val ${stream.dartName}: Flow<$itemType>');
    }

    writer.line('}');
    writer.blankLine();

    // ── JNI Bridge object ──────────────────────────────────────────────────
    writer.line('@Keep');
    writer.line('object ${spec.dartClassName}JniBridge {');
    // Factory pattern (like RN Nitro's HybridObjectRegistry):
    //   registerFactory { -> Impl() }  — called once at plugin startup (type-level)
    //   create_instance_call(key)      — called by Dart on first getInstance(key)
    //   destroy_instance_call(id)      — called by Dart from dispose()
    //
    // All JNI _call methods use Long instanceId for zero per-call overhead.
    writer.line('    private val _implementations = java.util.concurrent.ConcurrentHashMap<Long, Hybrid${spec.dartClassName}Spec>()');
    writer.line('    private val _idCounter = java.util.concurrent.atomic.AtomicLong(0)');
    writer.line('    private var _factory: (() -> Hybrid${spec.dartClassName}Spec)? = null');
    if (hasAsyncFunctions) {
      writer.line('    private val _asyncExecutor = java.util.concurrent.Executors.newCachedThreadPool()');
    }
    writer.blankLine();
    writer.line('    lateinit var applicationContext: Context');
    writer.line('        private set');
    writer.blankLine();
    writer.line('    var activity: Activity? = null');
    writer.line('        private set');
    writer.blankLine();
    writer.line('    @JvmStatic external fun initialize(bridgeClass: Class<*>)');
    writer.blankLine();
    // registerFactory: called once at plugin startup. Equivalent to
    // HybridObjectRegistry::registerHybridObjectConstructor in RN Nitro.
    writer.line('    fun registerFactory(factory: () -> Hybrid${spec.dartClassName}Spec, context: Context) {');
    writer.line('        applicationContext = context');
    writer.line('        _factory = factory');
    writer.line('        if (_implementations.isEmpty()) { initialize(this::class.java) }');
    writer.line('    }');
    writer.blankLine();
    // create_instance_call: invoked via JNI when Dart calls getInstance(key) for the first time.
    // Creates a new impl via the factory, assigns a unique Long id, and returns it to Dart.
    writer.line('    @JvmStatic');
    writer.line('    fun create_instance_call(key: String): Long {');
    writer.line('        val factory = _factory ?: throw IllegalStateException(');
    writer.line('            "${spec.dartClassName}: no factory registered. Call registerFactory() in onAttachedToEngine().")');
    writer.line('        val id = _idCounter.getAndIncrement()');
    writer.line('        val impl = factory()');
    writer.line('        _implementations[id] = impl');
    writer.line('        impl.onAttached()');
    writer.line('        return id');
    writer.line('    }');
    writer.blankLine();
    // destroy_instance_call: invoked via JNI from Dart dispose(). Removes and detaches impl.
    writer.line('    @JvmStatic');
    writer.line('    fun destroy_instance_call(instanceId: Long) {');
    writer.line('        _implementations.remove(instanceId)?.onDetached()');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onActivityAttached(newActivity: Activity) {');
    writer.line('        activity = newActivity');
    writer.line('        _implementations.values.forEach { it.onActivityAttached(newActivity) }');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onActivityDetached() {');
    writer.line('        activity = null');
    writer.line('        _implementations.values.forEach { it.onActivityDetached() }');
    writer.line('    }');
    writer.blankLine();

    if (hasNativeAsync) {
      writer.line('    // @NitroNativeAsync helpers — post primitive results via Dart_PostCObject_DL.');
      writer.line('    @JvmStatic external fun postNullToPort(dartPort: Long)');
      writer.line('    @JvmStatic external fun postInt64ToPort(dartPort: Long, value: Long)');
      writer.line('    @JvmStatic external fun postDoubleToPort(dartPort: Long, value: Double)');
      writer.line('    @JvmStatic external fun postBoolToPort(dartPort: Long, value: Boolean)');
      writer.line('    @JvmStatic external fun postStringToPort(dartPort: Long, value: String)');
      writer.blankLine();
    }

    // ── Function _call bridge methods ──────────────────────────────────────
    for (final func in spec.functions) {
      KotlinFunctionEmitter.emit(writer, func, spec, mapper);
    }

    // ── Property getter/setter _call bridge methods ────────────────────────
    for (final prop in spec.properties) {
      KotlinPropertyEmitter.emit(writer, prop, spec.dartClassName, mapper);
    }

    // ── Stream registration / external emit declarations ───────────────────
    if (hasStreams) {
      writer.line('    private val _streamJobs = java.util.concurrent.ConcurrentHashMap<Pair<String, Long>, kotlinx.coroutines.Job>()');
      writer.blankLine();
    }

    for (final stream in spec.streams) {
      KotlinStreamEmitter.emit(writer, stream, mapper);
    }

    // ── Native callback invoker declarations ───────────────────────────────
    KotlinCallbackEmitter.emitInvokers(writer, spec, mapper);

    writer.line('}');
    return writer.toString();
  }

  /// Emits Kotlin helper classes/functions needed for @NitroVariant bridge and @NitroResult.
  ///
  /// RecordReader / RecordWriter are not in the nitro AAR runtime — they must be
  /// emitted as package-level classes in the generated bridge file so that the
  /// variant's fromReader / writeFields methods can use them.
  ///
  /// nitroEncodeResult* functions are private helpers used by the _call bridge methods.
  static void _emitKotlinBridgeHelpers(
    CodeWriter writer, {
    bool hasVariantBridge = false,
    bool hasResult = false,
  }) {
    if (hasVariantBridge) {
      writer.line('/** Minimal RecordReader for @NitroVariant bridge decode. */');
      writer.line('class RecordReader(val buf: java.nio.ByteBuffer) {');
      writer.line('    fun readInt8(): Byte = buf.get()');
      writer.line('    fun readInt32(): Int = buf.int');
      writer.line('    fun readInt64(): Long = buf.long');
      writer.line('    fun readFloat64(): Double = buf.double');
      writer.line('    fun readBool(): Boolean = buf.get().toInt() != 0');
      writer.line('    fun readString(): String {');
      writer.line('        val len = buf.int');
      writer.line('        val bytes = ByteArray(len)');
      writer.line('        buf.get(bytes)');
      writer.line('        return bytes.toString(Charsets.UTF_8)');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
      writer.line('/** Minimal RecordWriter for @NitroVariant bridge encode. */');
      writer.line('class RecordWriter {');
      writer.line('    val out = java.io.ByteArrayOutputStream()');
      writer.line('    val tmp = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('    fun writeInt8(v: Byte) { out.write(v.toInt()) }');
      writer.line('    fun writeInt32(v: Int) { tmp.clear(); tmp.putInt(v); out.write(tmp.array(), 0, 4) }');
      writer.line('    fun writeInt64(v: Long) { tmp.clear(); tmp.putLong(v); out.write(tmp.array(), 0, 8) }');
      writer.line('    fun writeFloat64(v: Double) { tmp.clear(); tmp.putDouble(v); out.write(tmp.array(), 0, 8) }');
      writer.line('    fun writeBool(v: Boolean) { out.write(if (v) 1 else 0) }');
      writer.line('    fun writeString(v: String) { val b = v.toByteArray(Charsets.UTF_8); writeInt32(b.size); out.write(b) }');
      writer.line('    fun toByteArray(): ByteArray = out.toByteArray()');
      writer.line('}');
      writer.blankLine();
    }
    if (hasResult) {
      writer.line('/** @NitroResult bridge encoding helpers. */');
      writer.line('private fun nitroWriteResultTag(tag: Byte, payload: ByteArray): ByteArray {');
      writer.line('    val buf = ByteArray(1 + payload.size)');
      writer.line('    buf[0] = tag');
      writer.line('    payload.copyInto(buf, 1)');
      writer.line('    return buf');
      writer.line('}');
      writer.blankLine();
      writer.line('private fun nitroEncodeResultInt64(v: Long): ByteArray {');
      writer.line('    val w = java.nio.ByteBuffer.allocate(4 + 8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('    w.putInt(8); w.putLong(v)');
      writer.line('    return nitroWriteResultTag(0, w.array())');
      writer.line('}');
      writer.blankLine();
      writer.line('private fun nitroEncodeResultFloat64(v: Double): ByteArray {');
      writer.line('    val w = java.nio.ByteBuffer.allocate(4 + 8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('    w.putInt(8); w.putDouble(v)');
      writer.line('    return nitroWriteResultTag(0, w.array())');
      writer.line('}');
      writer.blankLine();
      writer.line('private fun nitroEncodeResultBool(v: Boolean): ByteArray {');
      writer.line('    val w = java.nio.ByteBuffer.allocate(4 + 1).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('    w.putInt(1); w.put(if (v) 1.toByte() else 0.toByte())');
      writer.line('    return nitroWriteResultTag(0, w.array())');
      writer.line('}');
      writer.blankLine();
      writer.line('private fun nitroEncodeResultString(v: String): ByteArray {');
      writer.line('    val bytes = v.toByteArray(Charsets.UTF_8)');
      writer.line('    val w = java.nio.ByteBuffer.allocate(4 + 4 + bytes.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('    w.putInt(4 + bytes.size); w.putInt(bytes.size); w.put(bytes)');
      writer.line('    return nitroWriteResultTag(0, w.array())');
      writer.line('}');
      writer.blankLine();
      writer.line('private fun nitroEncodeResultRecord(v: Any): ByteArray {');
      writer.line('    // For @HybridRecord: encode via the generated encode() method (duck-typed via reflection)');
      writer.line('    return try {');
      writer.line('        val method = v.javaClass.getMethod("encode")');
      writer.line('        val payload = method.invoke(v) as? ByteArray ?: ByteArray(4)');
      writer.line('        nitroWriteResultTag(0, payload)');
      writer.line('    } catch (_: Throwable) {');
      writer.line('        nitroEncodeResultError("Record encode failed")');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
      writer.line('private fun nitroEncodeResultError(msg: String): ByteArray {');
      writer.line('    // Encode error as [1B tag=1][string payload]');
      writer.line('    val errBytes = msg.toByteArray(Charsets.UTF_8)');
      writer.line('    val w = java.nio.ByteBuffer.allocate(4 + 4 + errBytes.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('    w.putInt(4 + errBytes.size); w.putInt(errBytes.size); w.put(errBytes)');
      writer.line('    return nitroWriteResultTag(1, w.array())');
      writer.line('}');
      writer.blankLine();
    }
  }

  /// Emits the NitroAnyMap inline binary codec object for Kotlin bridge files.
  ///
  /// This object handles the full recursive AnyValue variant type:
  /// null, bool, int64, float64, string, array, object.
  static void _emitKotlinAnyMapHelper(CodeWriter writer) {
    writer.line('/** NitroAnyMap binary codec — generated by Nitrogen. */');
    writer.line('private object NitroAnyMapCodec {');
    writer.line('    private const val ANY_NULL: Byte = 0');
    writer.line('    private const val ANY_BOOL: Byte = 1');
    writer.line('    private const val ANY_INT: Byte = 2');
    writer.line('    private const val ANY_DOUBLE: Byte = 3');
    writer.line('    private const val ANY_STRING: Byte = 4');
    writer.line('    private const val ANY_LIST: Byte = 5');
    writer.line('    private const val ANY_OBJECT: Byte = 6');
    writer.blankLine();
    writer.line('    fun encode(map: Map<String, Any?>): ByteArray {');
    writer.line('        val payload = java.io.ByteArrayOutputStream()');
    writer.line('        val buf = java.io.DataOutputStream(payload)');
    writer.line('        writeInt32LE(buf, map.size)');
    writer.line('        for ((k, v) in map) { writeStr(buf, k); writeValue(buf, v) }');
    writer.line('        val payloadBytes = payload.toByteArray()');
    writer.line('        val result = java.io.ByteArrayOutputStream(4 + payloadBytes.size)');
    writer.line('        val header = java.io.DataOutputStream(result)');
    writer.line('        writeInt32LE(header, payloadBytes.size)');
    writer.line('        result.write(payloadBytes)');
    writer.line('        return result.toByteArray()');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun decode(bytes: ByteArray): Map<String, Any?> {');
    writer.line('        val buf = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        buf.position(4) // skip outer 4-byte length prefix');
    writer.line('        return readMap(buf)');
    writer.line('    }');
    writer.blankLine();
    writer.line('    private fun writeValue(out: java.io.DataOutputStream, v: Any?) { when (v) {');
    writer.line('        null -> out.writeByte(ANY_NULL.toInt())');
    writer.line('        is Boolean -> { out.writeByte(ANY_BOOL.toInt()); out.writeByte(if (v) 1 else 0) }');
    writer.line('        is Long -> { out.writeByte(ANY_INT.toInt()); writeInt64LE(out, v) }');
    writer.line('        is Int -> { out.writeByte(ANY_INT.toInt()); writeInt64LE(out, v.toLong()) }');
    writer.line('        is Double -> { out.writeByte(ANY_DOUBLE.toInt()); writeDoubleLE(out, v) }');
    writer.line('        is Float -> { out.writeByte(ANY_DOUBLE.toInt()); writeDoubleLE(out, v.toDouble()) }');
    writer.line('        is String -> { out.writeByte(ANY_STRING.toInt()); writeStr(out, v) }');
    writer.line('        is List<*> -> { out.writeByte(ANY_LIST.toInt()); writeInt32LE(out, v.size); v.forEach { writeValue(out, it) } }');
    writer.line('        is Map<*, *> -> { out.writeByte(ANY_OBJECT.toInt()); writeInt32LE(out, v.size); v.forEach { (k, vv) -> writeStr(out, k.toString()); writeValue(out, vv) } }');
    writer.line('        else -> throw IllegalArgumentException("Cannot encode \$v as NitroAnyValue") } }');
    writer.blankLine();
    writer.line('    private fun readValue(buf: java.nio.ByteBuffer): Any? = when (buf.get()) {');
    writer.line('        ANY_NULL -> null');
    writer.line('        ANY_BOOL -> buf.get().toInt() != 0');
    writer.line('        ANY_INT -> buf.long');
    writer.line('        ANY_DOUBLE -> buf.double');
    writer.line('        ANY_STRING -> readStr(buf)');
    writer.line('        ANY_LIST -> (0 until buf.int).map { readValue(buf) }');
    writer.line('        ANY_OBJECT -> readMap(buf)');
    writer.line('        else -> throw IllegalArgumentException("Unknown NitroAnyValue tag") }');
    writer.blankLine();
    writer.line('    private fun readMap(buf: java.nio.ByteBuffer): Map<String, Any?> =');
    writer.line('        (0 until buf.int).associate { readStr(buf) to readValue(buf) }');
    writer.blankLine();
    writer.line('    private fun writeStr(out: java.io.DataOutputStream, s: String) {');
    writer.line('        val b = s.toByteArray(Charsets.UTF_8); writeInt32LE(out, b.size); out.write(b) }');
    writer.line('    private fun readStr(buf: java.nio.ByteBuffer): String {');
    writer.line('        val len = buf.int; val b = ByteArray(len); buf.get(b); return b.toString(Charsets.UTF_8) }');
    writer.line('    private fun writeInt32LE(out: java.io.DataOutputStream, v: Int) {');
    writer.line('        out.write(v and 0xFF); out.write((v shr 8) and 0xFF); out.write((v shr 16) and 0xFF); out.write((v shr 24) and 0xFF) }');
    writer.line('    private fun writeInt64LE(out: java.io.DataOutputStream, v: Long) {');
    writer.line('        (0..7).forEach { out.write(((v shr (it * 8)) and 0xFF).toInt()) } }');
    writer.line('    private fun writeDoubleLE(out: java.io.DataOutputStream, v: Double) =');
    writer.line('        writeInt64LE(out, java.lang.Double.doubleToRawLongBits(v))');
    writer.line('}');
    writer.blankLine();
  }

  static String _generateTypeOnly(BridgeSpec spec) {
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      CodeLine('package nitro.${spec.lib.replaceAll('-', '_')}_module'),
      const BlankLine(),
      const CodeLine('import androidx.annotation.Keep'),
      const BlankLine(),
    ];

    final kotlinEnums = EnumGenerator.generateKotlin(spec);
    if (kotlinEnums.isNotEmpty) nodes.add(CodeSnippet(kotlinEnums));

    final kotlinStructs = StructGenerator.generateKotlin(spec);
    if (kotlinStructs.isNotEmpty) nodes.add(CodeSnippet(kotlinStructs));

    final kotlinRecords = RecordGenerator.generateKotlin(spec);
    if (kotlinRecords.isNotEmpty) nodes.add(CodeSnippet(kotlinRecords));

    if (spec.localVariants.isNotEmpty) {
      final mapper = KotlinTypeMapper.fromSpec(spec);
      final varWriter = CodeWriter();
      for (final variant in spec.localVariants) {
        KotlinVariantEmitter.emit(varWriter, variant, mapper);
      }
      nodes.add(CodeSnippet(varWriter.toString()));
    }

    return CodeFile(nodes).render();
  }
}
