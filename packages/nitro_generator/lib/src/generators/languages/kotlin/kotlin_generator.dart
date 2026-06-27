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
    final hasTimeoutFunctions = spec.functions.any((f) => f.isAsync && f.asyncTimeout != null);
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
    if (hasTimeoutFunctions) writer.line('import kotlinx.coroutines.withTimeout');
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
    writer.line('    private var implementation: Hybrid${spec.dartClassName}Spec? = null');
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
    writer.line('    fun register(impl: Hybrid${spec.dartClassName}Spec, context: Context) {');
    writer.line('        applicationContext = context');
    writer.line('        implementation = impl');
    writer.line('        initialize(this::class.java)');
    writer.line('        impl.onAttached()');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onDetached() {');
    writer.line('        implementation?.onDetached()');
    writer.line('        activity = null');
    writer.line('        implementation = null');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onActivityAttached(newActivity: Activity) {');
    writer.line('        activity = newActivity');
    writer.line('        implementation?.onActivityAttached(newActivity)');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onActivityDetached() {');
    writer.line('        activity = null');
    writer.line('        implementation?.onActivityDetached()');
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
      writer.line('class RecordReader(private val buf: java.nio.ByteBuffer) {');
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
      writer.line('    private val out = java.io.ByteArrayOutputStream()');
      writer.line('    private val tmp = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
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
