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
      writer.line('import kotlinx.coroutines.Dispatchers');
    }
    if (hasAsyncFunctions) writer.line('import kotlinx.coroutines.runBlocking');
    if (hasTimeoutFunctions) writer.line('import kotlinx.coroutines.withTimeout');
    writer.blankLine();

    // ── Type declarations (enums / structs / records) ──────────────────────
    final kotlinEnums = EnumGenerator.generateKotlin(spec);
    if (kotlinEnums.isNotEmpty) writer.raw(kotlinEnums);

    final kotlinStructs = StructGenerator.generateKotlin(spec);
    if (kotlinStructs.isNotEmpty) writer.raw(kotlinStructs);

    final kotlinRecords = RecordGenerator.generateKotlin(spec);
    if (kotlinRecords.isNotEmpty) writer.raw(kotlinRecords);

    // ── Interface ──────────────────────────────────────────────────────────
    writer.line('/**');
    writer.line(' * Contract for the [${spec.dartClassName}] module.');
    writer.line(' * Implement this in your Kotlin source code.');
    writer.line(' * Nitro may call this implementation from any JNI thread.');
    writer.line(' * Keep mutable state thread-safe or marshal work onto your own dispatcher.');
    writer.line(' */');
    writer.line('interface Hybrid${spec.dartClassName}Spec {');
    writer.line(
        '    val applicationContext: Context get() = ${spec.dartClassName}JniBridge.applicationContext');
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
      final params = func.params
          .map((p) => '${p.name}: ${mapper.paramType(p)}')
          .join(', ');
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
      writer.line(
          '    private val _asyncExecutor = java.util.concurrent.Executors.newCachedThreadPool()');
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
      writer.line(
          '    private val _streamJobs = java.util.concurrent.ConcurrentHashMap<Pair<String, Long>, kotlinx.coroutines.Job>()');
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
