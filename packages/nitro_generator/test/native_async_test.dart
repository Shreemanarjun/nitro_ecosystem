// Tests for @NitroNativeAsync — the zero-hop native async path.
//
// Covers all four generators (Dart FFI, C++ bridge, C++ interface, Kotlin,
// Swift) to ensure the correct code patterns are emitted for each return type.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Test specs ────────────────────────────────────────────────────────────────

BridgeSpec _nativeAsyncIntSpec() => BridgeSpec(
  dartClassName: 'Compute',
  lib: 'compute',
  namespace: 'compute',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'compute.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'compute',
      cSymbol: 'compute_compute',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'x',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncStringSpec() => BridgeSpec(
  dartClassName: 'Fetcher',
  lib: 'fetcher',
  namespace: 'fetcher',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'fetcher.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fetchData',
      cSymbol: 'fetcher_fetch_data',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'query',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncNullableStringSpec() => BridgeSpec(
  dartClassName: 'MaybeFetcher',
  lib: 'maybe_fetcher',
  namespace: 'maybe_fetcher',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'maybe_fetcher.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fetchMaybe',
      cSymbol: 'maybe_fetcher_fetch_maybe',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'String?', isNullable: true),
      params: [
        BridgeParam(
          name: 'query',
          type: BridgeType(name: 'String?', isNullable: true),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncVoidSpec() => BridgeSpec(
  dartClassName: 'Worker',
  lib: 'worker',
  namespace: 'worker',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'worker.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'doWork',
      cSymbol: 'worker_do_work',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
  ],
);

BridgeSpec _nativeAsyncBoolSpec() => BridgeSpec(
  dartClassName: 'Checker',
  lib: 'checker',
  namespace: 'checker',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'checker.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'check',
      cSymbol: 'checker_check',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [
        BridgeParam(
          name: 'flag',
          type: BridgeType(name: 'bool'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncDoubleSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'readTemp',
      cSymbol: 'sensor_read_temp',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'double'),
      params: [],
    ),
  ],
);

BridgeSpec _mixedSpec() => BridgeSpec(
  dartClassName: 'Mixed',
  lib: 'mixed',
  namespace: 'mixed',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mixed.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'syncAdd',
      cSymbol: 'mixed_sync_add',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'int'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'asyncFetch',
      cSymbol: 'mixed_async_fetch',
      isAsync: true,
      returnType: BridgeType(name: 'String'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'nativeCompute',
      cSymbol: 'mixed_native_compute',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'n',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncEnumReturnSpec() => BridgeSpec(
  dartClassName: 'Status',
  lib: 'status',
  namespace: 'status',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'status.native.dart',
  enums: [
    BridgeEnum(name: 'Mode', startValue: 0, values: ['idle', 'running', 'error']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getMode',
      cSymbol: 'status_get_mode',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Mode'),
      params: [],
    ),
  ],
);

BridgeSpec _cppOnlyNativeAsyncSpec() => BridgeSpec(
  dartClassName: 'Engine',
  lib: 'engine',
  namespace: 'engine',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'engine.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'engine_process',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'value',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

// ── DartFfiGenerator tests ────────────────────────────────────────────────────

void main() {
  group('DartFfiGenerator — @NitroNativeAsync', () {
    // ── Function pointer ──────────────────────────────────────────────────────

    test('int return: FFI type is Void Function(Int64, Int64) with dart_port', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(
        out,
        contains('Void Function(Int64, Int64, Int64)'),
        reason: 'native-async wrapper returns void and takes (param, dart_port)',
      );
    });

    test('int return: Dart callable type is void Function(int, int, int)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('void Function(int, int, int)'));
    });

    test('String return: FFI type is Void Function(Pointer<Utf8>, Int64)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('Void Function(Int64, Pointer<Utf8>, Int64)'));
    });

    test('void return: FFI type is Void Function(Int64, Int64) — instanceId + dart_port', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('Void Function(Int64, Int64)'));
    });

    // ── No isLeaf ─────────────────────────────────────────────────────────────

    test('isNativeAsync methods are NOT bound with isLeaf:true', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      // The compute pointer must use lookupFunction, not .asFunction(isLeaf:true).
      expect(out, isNot(contains('isLeaf: true')));
    });

    // ── Method return type ────────────────────────────────────────────────────

    test('int return: method signature is Future<int>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Future<int> compute(int x)'));
    });

    test('String return: method signature is Future<String>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('Future<String> fetchData(String query)'));
    });

    test('void return: method signature is Future<void>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('Future<void> doWork()'));
    });

    // ── No async keyword ──────────────────────────────────────────────────────

    test('method body does NOT use the async keyword (returns Future directly)', () {
      // async keyword is only for @nitroAsync. @NitroNativeAsync returns the
      // Future produced by openNativeAsync without suspending.
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('compute(int x) async')));
      expect(out, contains('compute(int x) {'));
    });

    // ── openNativeAsync call ──────────────────────────────────────────────────

    test('method body calls NitroRuntime.openNativeAsync', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('NitroRuntime.openNativeAsync'));
    });

    test('method body does NOT call NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('NitroRuntime.callAsync')));
    });

    test('call: lambda passes the dart_port as last arg to the FFI ptr', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('call: (port) => _computePtr('));
      expect(out, contains(', port)'));
    });

    // ── Unpack expressions ────────────────────────────────────────────────────

    test('int return: unpack casts raw to int', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('(raw) => raw as int'));
    });

    test('double return: unpack casts raw to double', () {
      final out = DartFfiGenerator.generate(_nativeAsyncDoubleSpec());
      expect(out, contains('(raw) => raw as double'));
    });

    test('bool return: unpack casts raw to bool', () {
      final out = DartFfiGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('(raw) => raw as bool'));
    });

    test('String return: unpack casts raw to String (kString delivery)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('(raw) => raw as String'));
    });

    test('String return: openNativeAsync uses String transport type', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('NitroRuntime.openNativeAsync<String>'));
      expect(out, isNot(contains('NitroRuntime.openNativeAsync<Pointer<Utf8>>')));
    });

    test('nullable String return: openNativeAsync uses nullable API type', () {
      final out = DartFfiGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('NitroRuntime.openNativeAsync<String?>'));
      expect(out, contains('(raw) => raw as String?'));
      expect(out, isNot(contains('NitroRuntime.openNativeAsync<Pointer<Utf8>>')));
    });

    test('void return: unpack is _ => {}', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('(_) {}'));
    });

    // ── Arena management ──────────────────────────────────────────────────────

    test('String param forces arena allocation with release in finally', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      // Must allocate arena for UTF-8 String encoding.
      expect(out, contains('final arena = Arena()'));
      expect(out, contains('arena.releaseAll()'));
      expect(out, contains('finally {'));
    });

    test('primitive-only params (int) require no arena', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('final arena = Arena()')));
    });

    // ── Mixed spec ───────────────────────────────────────────────────────────

    test('mixed spec: sync method still emits callSync path', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      expect(out, contains('syncAdd(int a, int b)'));
      expect(out, isNot(contains('syncAdd.*async')));
    });

    test('mixed spec: @nitroAsync method still emits callAsync', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      expect(out, contains('NitroRuntime.callAsync'));
    });

    test('mixed spec: @NitroNativeAsync method emits openNativeAsync', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      expect(out, contains('NitroRuntime.openNativeAsync'));
    });

    test('mixed spec: nativeCompute pointer is Void Function(Int64, Int64)', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      // nativeCompute takes one int param + dart_port
      expect(out, contains('Void Function(Int64, Int64, Int64)'));
    });
  });

  // ── CppBridgeGenerator (direct C++ path) ─────────────────────────────────

  group('CppBridgeGenerator — @NitroNativeAsync (direct C++ path)', () {
    test('wrapper returns void (not the return type of the method)', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('void engine_process('));
    });

    test('wrapper has int64_t dart_port as last parameter', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('int64_t dart_port'));
    });

    test('wrapper does NOT call engine_clear_error()', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      // engine_clear_error() is declared globally but must NOT be called inside
      // the native-async wrapper — the wrapper has no error-slot logic.
      final wrapperStart = out.indexOf('void engine_process(');
      final wrapperBody = out.substring(wrapperStart, out.indexOf('\n}', wrapperStart));
      expect(wrapperBody, isNot(contains('engine_clear_error()')));
    });

    test('when impl is null, posts kNull to dart_port (not error slot)', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('Dart_CObject_kNull'));
      expect(out, contains('Dart_PostCObject_DL(dart_port, &_err)'));
    });

    test('delegates to g_impl->process() passing dart_port as last arg', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('g_impl->process('));
      expect(out, contains('dart_port)'));
    });

    test('wrapper has no try/catch (impl is responsible for posting errors)', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      // The NativeAsync wrapper should NOT have a try/catch — the native impl
      // posts errors via the port itself.
      final wrapperSection = out.substring(out.indexOf('void engine_process('));
      final nextFn = wrapperSection.indexOf('\n\n');
      final wrapper = nextFn > 0 ? wrapperSection.substring(0, nextFn) : wrapperSection;
      expect(wrapper, isNot(contains('catch')));
    });
  });

  // ── CppInterfaceGenerator ─────────────────────────────────────────────────

  group('CppInterfaceGenerator — @NitroNativeAsync', () {
    test('pure-virtual method returns void (not the Dart return type)', () {
      final out = CppInterfaceGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('virtual void process('));
    });

    test('pure-virtual method has int64_t dartPort as last param', () {
      final out = CppInterfaceGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('int64_t dartPort'));
    });

    test('pure-virtual is = 0 (must be overridden)', () {
      final out = CppInterfaceGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('virtual void process(int64_t value, int64_t dartPort) = 0;'));
    });
  });

  // ── KotlinGenerator ──────────────────────────────────────────────────────

  group('KotlinGenerator — @NitroNativeAsync', () {
    test('_call method accepts extra dartPort: Long parameter', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('compute_call(instanceId: Long, x: Long, dartPort: Long)'));
    });

    test('_call method returns Unit (void), not the Dart return type', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      // The wrapper accepts (params, dartPort) and returns Unit implicitly —
      // it must NOT declare ): Long { (that would be a non-void return type).
      expect(out, contains('fun compute_call(instanceId: Long, '));
      final callLine = out.split('\n').firstWhere((l) => l.contains('compute_call(instanceId: Long, '), orElse: () => '');
      // Closing paren followed by ): Long would indicate a Long return type.
      expect(callLine, isNot(contains('): Long')));
    });

    test('executes via _asyncExecutor.execute (non-blocking)', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('_asyncExecutor.execute'));
    });

    test('posts result via postInt64ToPort for int return', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('postInt64ToPort(dartPort,'));
    });

    test('posts result via postStringToPort for String return', () {
      final out = KotlinGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('postStringToPort(dartPort,'));
    });

    test('posts via postNullToPort for void return', () {
      final out = KotlinGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('postNullToPort(dartPort)'));
    });

    test('posts via postBoolToPort for bool return', () {
      final out = KotlinGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('postBoolToPort(dartPort,'));
    });

    test('posts via postDoubleToPort for double return', () {
      final out = KotlinGenerator.generate(_nativeAsyncDoubleSpec());
      expect(out, contains('postDoubleToPort(dartPort,'));
    });

    test('postXxxToPort helpers are declared as external JvmStatic', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('@JvmStatic external fun postNullToPort(dartPort: Long)'));
      expect(out, contains('@JvmStatic external fun postInt64ToPort(dartPort: Long, value: Long)'));
      expect(out, contains('@JvmStatic external fun postStringToPort(dartPort: Long, value: String)'));
    });

    test('postXxxToPort helpers are NOT emitted for specs with no @NitroNativeAsync', () {
      // simpleSpec() has @nitroAsync but no @NitroNativeAsync — no helper noise.
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, isNot(contains('postNullToPort')));
    });

    test('handles null impl gracefully by posting null to port', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('postNullToPort(dartPort)'));
    });

    test('interface suspend fun still declared for @NitroNativeAsync method', () {
      // The Kotlin interface uses `suspend` for any async-natured method.
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('suspend fun compute('));
    });

    test('mixed spec: regular @JvmStatic fun still emitted for non-native-async', () {
      final out = KotlinGenerator.generate(_mixedSpec());
      expect(out, contains('fun syncAdd_call(instanceId: Long, '));
      expect(out, contains('fun asyncFetch_call(instanceId: Long)'));
    });
  });

  // ── SwiftGenerator ───────────────────────────────────────────────────────

  group('SwiftGenerator — @NitroNativeAsync', () {
    test('stub does NOT use DispatchSemaphore (non-blocking path)', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('DispatchSemaphore')));
    });

    test('stub accepts extra _ dartPort: Int64 parameter', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('_ dartPort: Int64'));
    });

    test('stub uses Task.detached for non-blocking async execution', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Task.detached'));
    });

    test('stub calls Dart_PostCObject_DL(dartPort, &_obj)', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Dart_PostCObject_DL(dartPort'));
    });

    test('int return: posts via kInt64', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, contains('as_int64'));
    });

    test('double return: posts via kDouble', () {
      final out = SwiftGenerator.generate(_nativeAsyncDoubleSpec());
      expect(out, contains('Dart_CObject_kDouble'));
      expect(out, contains('as_double'));
    });

    test('bool return: posts via kBool', () {
      final out = SwiftGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('Dart_CObject_kBool'));
      expect(out, contains('as_bool'));
    });

    test('stub has @_cdecl annotation', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      // namespace = 'compute' → _compute_call_compute
      expect(out, contains('@_cdecl("_compute_call_compute")'));
    });

    test('stub does NOT call sema.wait() — no thread blocking', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('sema.wait()')));
    });
  });

  // ── NitroRuntime.openNativeAsync contract ─────────────────────────────────

  group('NitroRuntime.openNativeAsync — contract via generated output', () {
    test('Dart output does not contain NitroRuntime.callAsync for native-async', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('NitroRuntime.callAsync')));
    });

    test('Dart output does not reference _getErrorNativePtr for native-async', () {
      // Error slot checks are skipped — errors come via the port.
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      final computeMethod = out.substring(out.indexOf('Future<int> compute'));
      final endOfMethod = computeMethod.indexOf('\n  }');
      final methodBody = computeMethod.substring(0, endOfMethod);
      expect(methodBody, isNot(contains('_getErrorNativePtr')));
    });
  });

  // ── DartFfiGenerator — additional return / param types ───────────────────────

  group('DartFfiGenerator — @NitroNativeAsync additional coverage', () {
    test('enum return: unpack converts raw int via .toMode()', () {
      final out = DartFfiGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('(raw) => (raw as int).toMode()'));
    });

    test('enum return: openNativeAsync uses enum API type', () {
      final out = DartFfiGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('NitroRuntime.openNativeAsync<Mode>'));
      expect(out, isNot(contains('NitroRuntime.openNativeAsync<int>')));
    });

    test('enum return: method signature is Future<Mode>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('Future<Mode> getMode()'));
    });

    test('bool param: FFI type includes Int8 for the bool parameter', () {
      final out = DartFfiGenerator.generate(_nativeAsyncBoolSpec());
      // instanceId -> Int64, bool flag -> Int8, dart_port -> Int64
      expect(out, contains('Void Function(Int64, Int8, Int64)'));
    });

    test('bool param: Dart callable type uses int for bool parameter', () {
      final out = DartFfiGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('void Function(int, int, int)'));
    });

    test('String param: arena call arg uses toNativeUtf8(allocator: arena)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('query.toNativeUtf8(allocator: arena)'));
    });

    test('no-params void: call lambda is _doWorkPtr(_instanceId, port)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('_doWorkPtr(_instanceId, port)'));
      expect(out, isNot(contains('_doWorkPtr(, port)')));
    });
  });

  // ── SwiftGenerator — additional return types ──────────────────────────────────

  group('SwiftGenerator — @NitroNativeAsync additional coverage', () {
    test('void return: posts kNull after executing inside Task', () {
      final out = SwiftGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('Dart_CObject_kNull'));
    });

    test('void return: calls impl.doWork() before posting null', () {
      final out = SwiftGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('impl.doWork()'));
      expect(out, contains('Dart_PostCObject_DL(dartPort, &_null)'));
    });

    test('String return: uses kString type', () {
      final out = SwiftGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('Dart_CObject_kString'));
      expect(out, contains('as_string'));
    });

    test('String return: uses withCString to pass the string pointer', () {
      final out = SwiftGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('withCString'));
    });

    test('nullable String return: posts kNull or kString', () {
      final out = SwiftGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('guard let _value = _result ?? nil else'));
      expect(out, contains('Dart_CObject_kNull'));
      expect(out, contains('Dart_CObject_kString'));
    });

    test('nullable String param: preserves nil instead of empty string', () {
      final out = SwiftGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('let queryStr: String? = _nitroStringOptFromCString(query)'));
    });

    test('no-params stub: signature has no comma before _ dartPort', () {
      final out = SwiftGenerator.generate(_nativeAsyncVoidSpec());
      // namespace = 'worker' → _worker_call_doWork
      expect(out, contains('public func _worker_call_doWork(_ dartPort: Int64)'));
      expect(out, isNot(contains('(, _ dartPort')));
    });

    test('null guard: posts kNull to dartPort before Task when impl is nil', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      final guardIdx = out.indexOf('guard let impl = ComputeRegistry.impl else {');
      expect(guardIdx, isNot(-1), reason: 'null guard must be present');
      final guardBlock = out.substring(guardIdx, out.indexOf('\n    }', guardIdx) + 6);
      expect(guardBlock, contains('Dart_PostCObject_DL(dartPort, &_null)'));
    });

    test('enum return: posts via kInt64 using .rawValue', () {
      final out = SwiftGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('?.rawValue ?? 0'));
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, contains('as_int64'));
    });

    test('bool param converts Int8 ABI value to Swift Bool', () {
      final out = SwiftGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('impl.check(flag: flag != 0)'));
      expect(out, isNot(contains('impl.check(flag: flag)')));
    });
  });

  // ── KotlinGenerator — additional return types ─────────────────────────────────

  group('KotlinGenerator — @NitroNativeAsync additional coverage', () {
    test('enum return: posts nativeValue via postInt64ToPort', () {
      final out = KotlinGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('postInt64ToPort(dartPort, result.nativeValue)'));
    });

    test('enum return: interface uses suspend fun with enum return type', () {
      final out = KotlinGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('suspend fun getMode('));
    });

    test('uses runBlocking inside _asyncExecutor.execute body', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('runBlocking {'));
    });

    test('executor catches thrown native async work and completes port', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('} catch (_: Throwable) {'));
      expect(out, contains('postNullToPort(dartPort)'));
    });

    test('nullable String return: posts null or string to port', () {
      final out = KotlinGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('suspend fun fetchMaybe(query: String?): String?'));
      expect(
        out,
        contains('if (result == null) postNullToPort(dartPort) else postStringToPort(dartPort, result)'),
      );
    });
  });

  // ── CppBridgeGenerator — param type conversions ───────────────────────────────

  group('CppBridgeGenerator — @NitroNativeAsync param conversions', () {
    test('String param is converted to std::string in the call args', () {
      final spec = BridgeSpec(
        dartClassName: 'Greeter',
        lib: 'greeter',
        namespace: 'greeter',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'greeter.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'greet',
            cSymbol: 'greeter_greet',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'name',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('std::string(name)'));
    });

    test('enum param is cast with static_cast<EnumType>()', () {
      final spec = BridgeSpec(
        dartClassName: 'Ctrl',
        lib: 'ctrl',
        namespace: 'ctrl',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'ctrl.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['on', 'off']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'setMode',
            cSymbol: 'ctrl_set_mode',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'mode',
                type: BridgeType(name: 'Mode'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('static_cast<Mode>(mode)'));
    });

    test('String param has const char* type in the C function signature', () {
      final spec = BridgeSpec(
        dartClassName: 'Greeter',
        lib: 'greeter',
        namespace: 'greeter',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'greeter.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'greet',
            cSymbol: 'greeter_greet',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'name',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('const char* name'));
    });
  });

  // ── CppBridgeGenerator — Android JNI @NitroNativeAsync ───────────────────

  BridgeSpec jniNativeAsyncSpec(String returnType) => BridgeSpec(
    dartClassName: 'Fetcher',
    lib: 'fetcher',
    namespace: 'fetcher',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'fetcher.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'fetch',
        cSymbol: 'fetcher_fetch',
        isAsync: false,
        isNativeAsync: true,
        returnType: BridgeType(name: returnType),
        params: [
          BridgeParam(
            name: 'key',
            type: BridgeType(name: 'String'),
          ),
        ],
      ),
    ],
  );

  group('CppBridgeGenerator — Android JNI @NitroNativeAsync', () {
    test('JNI_OnLoad caches method with (instanceId + params + J)V signature for native async', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('"(JLjava/lang/String;J)V"'));
    });

    test('Android C function is void with instanceId and dart_port params', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('void fetcher_fetch(int64_t instanceId, const char* key, int64_t dart_port)'));
    });

    test('Android C function calls CallStaticVoidMethod with jlong dart_port', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('CallStaticVoidMethod('));
      expect(out, contains('(jlong)dart_port'));
    });

    test('Android C function reports native async JNI exceptions without out-param slot', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      final start = out.indexOf('void fetcher_fetch(');
      expect(start, isNonNegative);
      final end = out.indexOf('\n}', start);
      expect(end, isNonNegative);
      final body = out.substring(start, end);
      expect(body, contains('nitro_report_jni_exception(env, env->ExceptionOccurred(), nullptr);'));
      expect(body, isNot(contains('_nitro_err')));
    });

    test('Android/iOS bridge emits one extern C close per platform section', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(RegExp(r'} // extern "C"').allMatches(out), hasLength(2));
    });

    test('postNullToPort JNIEXPORT is emitted for specs with @NitroNativeAsync', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postNullToPort'));
    });

    test('postStringToPort JNIEXPORT uses GetStringUTFChars and Dart_PostCObject_DL', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postStringToPort'));
      expect(out, contains('GetStringUTFChars'));
      expect(out, contains('if (value == nullptr)'));
      expect(out, contains('Dart_CObject_kString'));
      expect(out, contains('Dart_CObject_kNull'));
      expect(out, contains('Dart_PostCObject_DL'));
    });

    test('postInt64ToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('int'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postInt64ToPort'));
      expect(out, contains('Dart_CObject_kInt64'));
    });

    test('postDoubleToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('double'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postDoubleToPort'));
      expect(out, contains('Dart_CObject_kDouble'));
    });

    test('postBoolToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('bool'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postBoolToPort'));
      expect(out, contains('Dart_CObject_kBool'));
    });

    test('postXxxToPort helpers NOT emitted when no @NitroNativeAsync', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, isNot(contains('postNullToPort')));
      expect(out, isNot(contains('postStringToPort')));
    });

    test('Apple section for @NitroNativeAsync emits void + dart_port signature', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      // The Apple #elif section should have void func(params, int64_t dart_port)
      expect(out, contains('void fetcher_fetch(int64_t instanceId, const char* key, int64_t dart_port)'));
      // And should declare the Swift extern as void too
      expect(out, contains('extern void _fetcher_call_fetch('));
    });
  });
}
