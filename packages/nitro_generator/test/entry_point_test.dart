// @NitroEntryPoint: extraction, validation edge cases, and emission across
// every backend. The type-coverage fixture's §76 integration group proves the
// runtime; these pin the generator contract.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

import 'spec_from_source.dart';

const _prelude = '''
import 'package:nitro_annotations/nitro_annotations.dart';
part 'demo.g.dart';
@HybridEnum()
enum Mode { fast, slow }
@HybridRecord()
class Job { final String id; final int priority; final List<double> weights; final Mode mode; final Job? parent;
  const Job({required this.id, required this.priority, required this.weights, required this.mode, this.parent}); }
@NitroTuple()
typedef Pair = (int, String);
''';

String _spec(String entries, {String platforms = 'ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp, web: NativeImpl.wasm'}) => '''
$_prelude
@NitroModule($platforms)
abstract class Demo extends HybridObject { int add(int a, int b); }
$entries
''';

const _allTypes = '''
@nitroEntryPoint
Future<Job> process(Job job, Mode mode, List<Job> events, Map<String, List<int?>> counts, DateTime at, Uint8List raw, Float64List samples, (int, String) pair, {required int retries, String? tag, bool verbose = false}) async => job;
@nitroEntryPoint
Mode flip(Mode e) => e;
@nitroEntryPoint
Future<void> ping(int n, [double scale = 1.0]) async {}
@nitroEntryPoint
Stream<Job> watch(Mode mode, int count) async* {}
''';

void main() {
  group('extraction', () {
    test('typed params, unwrapped Future return, void, named/optional shapes', () {
      final spec = SpecFromSource.parse(_spec(_allTypes), sourceUri: 'package:demo/src/demo.native.dart');
      expect(spec.entryPoints.map((e) => e.name), ['process', 'flip', 'ping', 'watch']);
      expect(spec.entryPoints[3].isStream, isTrue);
      expect(spec.entryPoints[3].returnType.name, 'Job', reason: 'Stream<Job> unwrapped to its item type');
      final p = spec.entryPoints[0];
      expect(p.isAsync, isTrue);
      expect(p.returnType.name, 'Job', reason: 'Future<Job> unwrapped');
      expect(p.params.map((x) => x.name), ['job', 'mode', 'events', 'counts', 'at', 'raw', 'samples', 'pair', 'retries', 'tag', 'verbose']);
      expect(p.params.where((x) => x.isNamed).map((x) => x.name), ['retries', 'tag', 'verbose']);
      expect(p.params.firstWhere((x) => x.name == 'verbose').defaultLiteral, 'false');
      expect(spec.entryPoints[1].isAsync, isFalse);
      expect(spec.entryPoints[2].returnsVoid, isTrue);
      expect(p.runnerName, 'runProcessInBackground');
      expect(p.wrapperName, 'nitroEntry_process');
    });

    test('a spec without entry points has none — and generates no background code at all', () {
      final spec = SpecFromSource.parse(_spec(''), sourceUri: 'package:demo/src/demo.native.dart');
      expect(spec.entryPoints, isEmpty);
      for (final out in [DartFfiGenerator.generateFfiLibrary(spec), CppBridgeGenerator.generate(spec), KotlinGenerator.generate(spec), SwiftGenerator.generate(spec), WebBridgeGenerator.generate(spec), CppHeaderGenerator.generate(spec)]) {
        expect(out, isNot(contains('_bg_submit')));
        expect(out, isNot(contains('nitro_background.h')));
        expect(out, isNot(contains('vm:entry-point')));
        expect(out, isNot(contains('nitroBgStart')));
        expect(out, isNot(contains('InBackground')));
      }
    });

    test('entryPointLibraryUri: spec library normally, the ffi library under the web split', () {
      final web = SpecFromSource.parse(_spec(_allTypes), sourceUri: 'package:demo/src/demo.native.dart');
      expect(web.entryPointLibraryUri, 'package:demo/src/generated/native/demo.ffi.g.dart');
      final native = SpecFromSource.parse(_spec(_allTypes, platforms: 'ios: NativeImpl.swift, android: NativeImpl.kotlin'), sourceUri: 'package:demo/src/demo.native.dart');
      expect(native.entryPointLibraryUri, 'package:demo/src/demo.native.dart');
    });
  });

  group('validation', () {
    BridgeSpec direct(List<BridgeEntryPoint> entries, {NativeImpl? ios = NativeImpl.swift, NativeImpl? android = NativeImpl.kotlin, NativeImpl? web}) => BridgeSpec(
      dartClassName: 'Demo', lib: 'demo', namespace: 'demo', iosImpl: ios, androidImpl: android, webImpl: web, sourceUri: 'demo.native.dart',
      functions: [BridgeFunction(dartName: 'add', cSymbol: 'demo_add', isAsync: false, returnType: BridgeType(name: 'int'), params: const [])],
      entryPoints: entries,
    );
    BridgeEntryPoint ep(String name, BridgeType param, {BridgeType? ret}) => BridgeEntryPoint(name: name, isAsync: true, params: [BridgeParam(name: 'p', type: param)], returnType: ret ?? BridgeType(name: 'int'));
    List<String> codes(BridgeSpec s) => SpecValidator.validate(s).map((i) => i.code).toList();

    test('the full type matrix (from source) is accepted', () {
      final spec = SpecFromSource.parse(_spec(_allTypes), sourceUri: 'package:demo/src/demo.native.dart');
      expect(spec.entryPoints, hasLength(4));
      expect(codes(spec).where((c) => c.startsWith('ENTRY_POINT')), isEmpty);
    });

    test('callbacks, streams, handles, pointers and nested futures are rejected with the reason', () {
      expect(codes(direct([ep('a', BridgeType(name: 'Function', isFunction: true))])), contains('ENTRY_POINT_UNSUPPORTED_TYPE'));
      expect(codes(direct([ep('a', BridgeType(name: 'Stream<int>', isStream: true))])), contains('ENTRY_POINT_UNSUPPORTED_TYPE'), reason: 'stream PARAM rejected');
      expect(codes(direct([BridgeEntryPoint(name: 's', isAsync: false, isStream: true, params: [BridgeParam(name: 'p', type: BridgeType(name: 'int'))], returnType: BridgeType(name: 'int'))])).where((c) => c.startsWith('ENTRY_POINT')), isEmpty, reason: 'stream RETURN accepted');
      expect(codes(direct([ep('a', BridgeType(name: 'Future<int>', isFuture: true))])), contains('ENTRY_POINT_UNSUPPORTED_TYPE'));
      expect(codes(direct([ep('a', BridgeType(name: 'Pointer<Void>', isPointer: true))])), contains('ENTRY_POINT_UNSUPPORTED_TYPE'));
      expect(codes(direct([ep('a', BridgeType(name: 'int'), ret: BridgeType(name: 'Function', isFunction: true))])), contains('ENTRY_POINT_UNSUPPORTED_TYPE'));
      final msg = SpecValidator.validate(direct([ep('a', BridgeType(name: 'Function', isFunction: true))])).firstWhere((i) => i.code == 'ENTRY_POINT_UNSUPPORTED_TYPE').message;
      expect(msg, contains('callbacks cannot cross into a background isolate'));
    });

    test('duplicate names are rejected', () {
      expect(codes(direct([ep('a', BridgeType(name: 'int')), ep('a', BridgeType(name: 'String'))])), contains('ENTRY_POINT_DUPLICATE'));
    });

    test('a web-only module cannot host entry points', () {
      expect(codes(direct([ep('a', BridgeType(name: 'int'))], ios: null, android: null, web: NativeImpl.wasm)), contains('ENTRY_POINT_NO_NATIVE_TARGET'));
    });
  });

  group('emission', () {
    late String dart, part, cpp, kt, sw, web, h;
    setUpAll(() {
      final spec = SpecFromSource.parse(_spec(_allTypes), sourceUri: 'package:demo/src/demo.native.dart');
      dart = DartFfiGenerator.generateFfiLibrary(spec);
      part = DartFfiGenerator.generate(SpecFromSource.parse(_spec(_allTypes, platforms: 'ios: NativeImpl.swift, android: NativeImpl.kotlin'), sourceUri: 'package:demo/src/demo.native.dart'));
      cpp = CppBridgeGenerator.generate(spec);
      kt = KotlinGenerator.generate(spec);
      sw = SwiftGenerator.generate(spec);
      web = WebBridgeGenerator.generate(spec);
      h = CppHeaderGenerator.generate(spec);
    });

    test('Dart: one pragma wrapper per entry, typed runner keeps the signature, host probe exported', () {
      for (final out in [dart, part]) {
        expect(RegExp(r"@pragma\('vm:entry-point'\)\nvoid nitroEntry_").allMatches(out).length, 4);
        expect(out, contains('Stream<Job> runWatchInBackground(Mode mode, int count)'));
        expect(out, contains('NitroBackground.runStreamEntry('));
        expect(out, contains('return watch(mode, count).map((item) {'));
        expect(out, contains("NitroBackground.openStream<R>("));
        expect(out, contains('Future<Job> runProcessInBackground(Job job, Mode mode, List<Job> events, Map<String, List<int?>> counts, DateTime at, Uint8List raw, Float64List samples, (int, String) pair, {required int retries, String? tag, bool verbose = false})'));
        expect(out, contains('Future<Mode> runFlipInBackground(Mode e)'));
        expect(out, contains('Future<void> runPingInBackground(int n, [double scale = 1.0])'));
        expect(out, contains('bool hasDemoBackgroundHost()'));
        expect(out, contains("NitroBackground.spawnFallback(wrapper, id)"), reason: 'fallback when no host, bound to the job id');
        expect(out, contains("final jobId = NitroBackground.jobIdOf(entryArgs);"), reason: 'the wrapper takes the job it was started for');
        expect(out, contains("int activeDemoBackgroundJobs() => _nitroBgActiveCount();"));
        expect(out, contains("throw NitroBackgroundException.fromPost(entry, raw);"), reason: 'typed failure');
      }
    });

    test('Dart codec covers every family: record, enum, variant list, map of nullable lists, DateTime, typed data, tuple, nullable', () {
      expect(dart, contains('job.writeFields(w);'));
      expect(dart, contains('w.writeInt(mode.nativeValue);'));
      expect(dart, contains('for (final _e2 in events) {'));
      expect(dart, contains('_e2.writeFields(w);'));
      expect(dart, contains('counts.forEach((_k2, _v2) {'));
      expect(dart, contains('w.writeNullTag(_e4 == null);'));
      expect(dart, contains('w.writeInt(at.millisecondsSinceEpoch);'));
      expect(dart, contains('w.writeBlob(Uint8List.view(raw.buffer, raw.offsetInBytes, raw.lengthInBytes));'));
      expect(dart, contains('w.writeInt(pair.\$1);'));
      expect(dart, contains('w.writeString(pair.\$2);'));
      expect(dart, contains('w.writeNullTag(tag == null);'));
      // read side
      expect(dart, contains('JobRecordExt.fromReader(r)'));
      expect(dart, contains('r.readInt().toMode()'));
      expect(dart, contains('DateTime.fromMillisecondsSinceEpoch(r.readInt())'));
      expect(dart, contains('Float64List.view(r.readBlob().buffer)'));
      expect(dart, contains('(r.readInt(), r.readString())'));
      expect(dart, contains("<String, List<int?>>{ for (var i = 0, n = r.readInt32(); i < n; i++) r.readString(): List<int?>.generate(r.readInt32(), (_) => (r.readNullTag() ? null : r.readInt())) }"));
    });

    test('C++: table + exports, JNI hooks (Kotlin android) and Swift hooks (iOS only) present', () {
      expect(cpp, contains('#include "nitro_background.h"'));
      expect(cpp, contains('static NitroBgTable g_bg_demo;'));
      for (final sym in ['demo_bg_submit', 'demo_bg_has_host', 'demo_bg_take_job', 'demo_bg_complete', 'demo_bg_fail', 'demo_bg_emit', 'demo_bg_end', 'demo_bg_cancel', 'demo_bg_run_string', 'demo_bg_register_host']) {
        expect(cpp, contains('NITRO_EXPORT'), reason: sym);
        expect(cpp, contains('$sym('), reason: sym);
      }
      expect(cpp, contains('g_bg_demo.registerHost(&nitro_bg_jni_start, &nitro_bg_jni_done, nullptr);'));
      expect(cpp, contains('Java_nitro_demo_1module_DemoJniBridge_nitroBgFail'));
      expect(cpp, contains('Java_nitro_demo_1module_DemoJniBridge_nitroBgRunString'));
      expect(cpp, contains('#if TARGET_OS_IOS'));
      expect(cpp, contains('extern int _demo_bg_start(const char* entry, int64_t jobId);'));
      expect(h, contains('NITRO_EXPORT int64_t demo_bg_submit('));
    });

    test('C++: no host hooks when the platform impl is C++ (fallback isolate instead)', () {
      final spec = SpecFromSource.parse(_spec(_allTypes, platforms: 'ios: NativeImpl.cpp, android: NativeImpl.cpp'), sourceUri: 'package:demo/src/demo.native.dart');
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('demo_bg_submit('));
      expect(out, isNot(contains('nitro_bg_jni_start')));
      expect(out, isNot(contains('_demo_bg_start')));
    });

    test('Kotlin: headless engine starter at the wrapper in the right library', () {
      expect(kt, contains('@Keep @JvmStatic fun nitroBgStart(entry: String, jobId: Long)'));
      expect(kt, contains('"package:demo/src/generated/native/demo.ffi.g.dart", "nitroEntry_" + entry'));
      expect(kt, contains('@JvmStatic external fun nitroBgFail(jobId: Long, error: String)'));
      expect(kt, contains('fun nitroBgDone(jobId: Long, error: String?)'));
        expect(kt, contains('FlutterEngineGroup.Options(applicationContext)'), reason: 'engines spawn from one group');
        expect(kt, contains('.setDartEntrypointArgs(listOf(jobId.toString()))'), reason: 'job id travels as the entrypoint argument');
        expect(kt, contains('fun runInBackground(context: Context, entry: String, text: String, onDone: ((jobId: Long, error: String?) -> Unit)? = null): Long'));
        expect(kt, contains('fun runInBackgroundAndWait(context: Context, entry: String, text: String, timeoutMs: Long = 30_000L): String?'));
        expect(kt, contains('fun activeBackgroundEngines(): Int'));
      expect(kt, contains('@JvmStatic @JvmOverloads fun runInBackground(context: Context, entry: String, text: String, onDone: ((jobId: Long, error: String?) -> Unit)? = null): Long'));
      expect(kt, contains('System.loadLibrary("demo")'));
    });

    test('Swift: iOS-only @_cdecl starter with libraryURI, imports Flutter under os(iOS)', () {
      expect(sw, contains('#if os(iOS)\nimport Flutter\n#endif'));
      expect(sw, contains('@_cdecl("_demo_bg_start")'));
      expect(sw, contains('options.libraryURI = "package:demo/src/generated/native/demo.ffi.g.dart"'));
        expect(sw, contains('options.entrypointArgs = [String(jobId)]'), reason: 'job id travels as the entrypoint argument');
        expect(sw, contains('FlutterEngineGroup(name: "nitro_bg_demo", project: nil)'));
        expect(sw, contains('public static func run(entry: String, text: String, onDone: ((Int64, String?) -> Void)? = nil) -> Int64'));
        expect(sw, contains('public static func run(entry: String, text: String) async -> String?'));
        expect(sw, contains('public func _demo_bg_done(_ jobId: Int64, _ error: UnsafePointer<CChar>?)'));
      expect(sw, contains('@_cdecl("_demo_bg_done")'));
      expect(sw, contains('@_silgen_name("demo_bg_run_string")'), reason: 'symbol-bound, not header-bound');
      expect(sw, contains('public enum DemoBackground {'));
      expect(sw, contains('@_silgen_name("demo_bg_run_string")'));
    });

    test('web: same public names, throwing; shim re-exports them', () {
      expect(web, contains('bool hasDemoBackgroundHost() => false;'));
      expect(web, contains('Future<Job> runProcessInBackground(Job job, Mode mode, List<Job> events'));
      expect(web, contains("throw UnsupportedError('@NitroEntryPoint process"));
      expect(web, contains('Stream<Job> runWatchInBackground(Mode mode, int count) =>'));
      final shim = DartFfiGenerator.generatePlatformShim(SpecFromSource.parse(_spec(_allTypes), sourceUri: 'package:demo/src/demo.native.dart'));
      expect(shim, contains('show createDemoInstance, ensureDemoReady, hasDemoBackgroundHost, activeDemoBackgroundJobs, runProcessInBackground, runFlipInBackground, runPingInBackground, runWatchInBackground;'));
    });
  });
}
