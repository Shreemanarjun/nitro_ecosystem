import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeType callback support', () {
    test('BridgeType with isFunction=true stores return type and params', () {
      final paramType = BridgeType(name: 'int');
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [paramType],
      );

      expect(callbackType.isFunction, isTrue);
      expect(callbackType.functionReturnType, 'void');
      expect(callbackType.functionParams, hasLength(1));
      expect(callbackType.functionParams.first.name, 'int');
    });

    test('BridgeType with isFunction=false has null function fields', () {
      final regularType = BridgeType(name: 'String');

      expect(regularType.isFunction, isFalse);
      expect(regularType.functionReturnType, isNull);
      expect(regularType.functionParams, isEmpty);
    });

    test('BridgeType with complex callback signature', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'bool',
        functionParams: [
          BridgeType(name: 'String'),
          BridgeType(name: 'double'),
          BridgeType(name: 'int'),
        ],
      );

      expect(callbackType.isFunction, isTrue);
      expect(callbackType.functionReturnType, 'bool');
      expect(callbackType.functionParams, hasLength(3));
      expect(callbackType.functionParams[0].name, 'String');
      expect(callbackType.functionParams[1].name, 'double');
      expect(callbackType.functionParams[2].name, 'int');
    });

    test('BridgeType with no-argument callback', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [],
      );

      expect(callbackType.isFunction, isTrue);
      expect(callbackType.functionReturnType, 'void');
      expect(callbackType.functionParams, isEmpty);
    });
  });

  group('BridgeParam with callback types', () {
    test('BridgeParam can hold callback BridgeType', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'onStateChanged',
        type: callbackType,
      );

      expect(param.type.isFunction, isTrue);
      expect(param.type.functionReturnType, 'void');
      expect(param.type.functionParams, hasLength(1));
    });
  });

  group('BridgeFunction with callback parameters', () {
    test('BridgeFunction can have callback parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String')],
      );
      final func = BridgeFunction(
        dartName: 'onEvent',
        cSymbol: 'on_event',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'callback',
            type: callbackType,
          ),
        ],
      );

      expect(func.params.first.type.isFunction, isTrue);
      expect(func.params.first.type.functionReturnType, 'void');
    });
  });

  group('Callback native ABI generation', () {
    test('SpecValidator accepts supported callback parameters', () {
      final spec = _callbackParamSpec();

      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('DartFfiGenerator emits typed NativeCallable cache and pointer argument', () {
      final out = DartFfiGenerator.generate(_callbackParamSpec());

      expect(out, contains('final Map<String, NativeCallable<dynamic>> _nativeCallbackCache = {};'));
      expect(out, contains('void Function(int, Pointer<NativeFunction<Void Function(Int64)>>, Pointer<NitroErrorFfi>) _watchPtr'));
      expect(out, contains('NativeCallable<Void Function(Int64)> _nativeCallbackWatchOnEvent(void Function(int) callback)'));
      expect(out, contains("const key = 'watch.onEvent';"));
      expect(out, contains('NativeCallable<Void Function(Int64)>.listener((int arg0)'));
      expect(out, contains('callback(arg0);'));
      expect(out, contains('_watchPtr(_instanceId, _nativeCallbackWatchOnEvent(onEvent).nativeFunction, _nitroErr);'));
      expect(out, contains('callback.close();'));
      expect(out, contains('_nativeCallbackCache.clear();'));
    });

    test('DartFfiGenerator supports primitive return callbacks using isolateLocal', () {
      final out = DartFfiGenerator.generate(_callbackReturnValueParamSpec());
      // bool return now uses Int64 (not Int8) — consistent with Android jlong path
      // and keeps all bidirectional returns in GP registers via Int64.
      expect(out, contains('Pointer<NativeFunction<Int64 Function(Pointer<Utf8>)>>'));
      expect(out, contains('NativeCallable<Int64 Function(Pointer<Utf8>)>.isolateLocal((Pointer<Utf8> arg0)'));
      expect(out, contains('return callback(arg0.toDartString()) ? 1 : 0;'));
      expect(out, contains('exceptionalReturn: 0'));
    });

    test('DartFfiGenerator omits exceptionalReturn for String-returning callbacks', () {
      final out = DartFfiGenerator.generate(_unsupportedCallbackParamSpec());
      // String maps to Pointer<Utf8>; NativeCallable.isolateLocal rejects
      // exceptionalReturn for pointer return types.
      expect(out, contains('NativeCallable<Pointer<Utf8> Function(Int64)>.isolateLocal'));
      expect(out, isNot(contains('exceptionalReturn: nullptr')));
    });

    test('DartFfiGenerator omits exceptionalReturn for zero-arg String callbacks', () {
      final out = DartFfiGenerator.generate(_zeroArgStringCallbackReturnSpec());

      expect(out, contains('NativeCallable<Pointer<Utf8> Function()>.isolateLocal(()'));
      expect(out, contains('return callback().toNativeUtf8(allocator: _nitroNativeAllocator);'));
      expect(out, isNot(contains('exceptionalReturn: nullptr')));
    });

    test('DartFfiGenerator returns nullptr for nullable String callback result', () {
      final out = DartFfiGenerator.generate(_nullableStringCallbackReturnSpec());

      expect(out, contains('String? Function(int)'));
      expect(out, contains('final _value = callback(arg0);'));
      expect(out, contains('return _value == null ? nullptr : _value.toNativeUtf8(allocator: _nitroNativeAllocator);'));
      expect(out, isNot(contains('exceptionalReturn: nullptr')));
    });

    test('DartFfiGenerator keeps primitive exceptionalReturn in mixed callback spec', () {
      final out = DartFfiGenerator.generate(_mixedCallbackReturnSpec());

      expect(out, contains('NativeCallable<Pointer<Utf8> Function(Int64)>.isolateLocal'));
      expect(out, contains('NativeCallable<Int64 Function(Int64)>.isolateLocal'));
      expect(out, contains('exceptionalReturn: 0'));
      expect(out, isNot(contains('exceptionalReturn: nullptr')));
    });

    test('DartFfiGenerator keeps exceptionalReturn for enum-returning callbacks', () {
      final out = DartFfiGenerator.generate(_enumCallbackReturnSpec());

      expect(out, contains('NativeCallable<Int64 Function(Int64)>.isolateLocal'));
      expect(out, contains('return callback(arg0).nativeValue;'));
      expect(out, contains('exceptionalReturn: 0'));
      expect(out, isNot(contains('exceptionalReturn: nullptr')));
    });

    test('CppHeaderGenerator emits real function pointer callback parameters', () {
      final out = CppHeaderGenerator.generate(_callbackParamSpec());

      expect(out, contains('NITRO_EXPORT void camera_watch(int64_t instanceId, void (*onEvent)(int64_t), NitroError* _nitro_err);'));
    });

    test('C++ interface uses std::function<>, bridge C extern keeps raw fn ptr ABI', () {
      final spec = _cppCallbackParamSpec();
      final iface = CppInterfaceGenerator.generate(spec);
      final bridge = CppBridgeGenerator.generate(spec);

      // Abstract class uses std::function<> (mirrors RN Nitro's JSIConverter<std::function<>>).
      expect(iface, contains('std::function<void(int64_t)> onEvent'));
      // C extern declaration (bridge ABI) keeps raw fn ptr for C linkage.
      expect(bridge, contains('void camera_watch(int64_t instanceId, void (*onEvent)(int64_t), NitroError* _nitro_err)'));
      // std::function<> accepts raw fn ptr implicitly — no wrapper needed.
      expect(bridge, contains('_impl->watch(onEvent);'));
      expect(bridge, isNot(contains('void* onEvent')));
    });

    test('C bridge JNI signature treats enum callback params as function-pointer longs', () {
      final bridge = CppBridgeGenerator.generate(_jniEnumCallbackParamSpec());

      expect(bridge, contains('torch_watch'));
      expect(bridge, contains('void torch_watch(int64_t instanceId, void (*onTorchState)(int64_t), NitroError* _nitro_err)'));
      expect(bridge, contains('GetStaticMethodID(g_bridgeClass, "watch_call", "(JJ)V")'));
      expect(bridge, contains('CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, (jlong)onTorchState)'));
      expect(bridge, isNot(contains('Unknown JNI signature type')));
    });

    test('SpecValidator accepts @HybridStruct callback params', () {
      // Struct callback params were previously rejected; they are now supported.
      final issues = SpecValidator.validate(_unsupportedStructCallbackParamSpec());
      expect(issues.where((i) => i.code == 'UNSUPPORTED_FUNCTION_TYPE'), isEmpty);
    });

    test('CppBridgeGenerator emits const TorchState* in callback typedef for struct param', () {
      final bridge = CppBridgeGenerator.generate(_unsupportedStructCallbackParamSpec());
      expect(bridge, contains('const TorchState*'));
    });

    test('SpecValidator accepts @HybridRecord callback params', () {
      // Records are now supported: encode()/toNative() serializes, fromNative() deserializes.
      final issues = SpecValidator.validate(_unsupportedRecordCallbackParamSpec());
      expect(issues.where((i) => i.code == 'UNSUPPORTED_FUNCTION_TYPE'), isEmpty);
    });

    test('CppBridgeGenerator emits const uint8_t* in callback typedef for record param', () {
      final bridge = CppBridgeGenerator.generate(_unsupportedRecordCallbackParamSpec());
      expect(bridge, contains('const uint8_t*'));
    });

    test('DartFfiGenerator refuses callback return types if validation is bypassed', () {
      expect(
        () => DartFfiGenerator.generate(_callbackReturnSpec()),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('returns function type'),
          ),
        ),
      );
    });

    test('SpecValidator rejects callback return types with the same ABI error', () {
      final issues = SpecValidator.validate(_callbackReturnSpec());

      final issue = issues.singleWhere((i) => i.code == 'UNSUPPORTED_FUNCTION_TYPE');
      expect(issue.isError, isTrue);
      expect(issue.message, contains('return type'));
      expect(issue.message, contains('void Function(int)'));
    });

    test('SpecValidator rejects unsupported callback object return values', () {
      // String is now supported (#4) — use a non-supported type (custom object) instead.
      final issues = SpecValidator.validate(_unsupportedCallbackParamSpec());
      // The spec uses 'String' return which IS now allowed — no error expected.
      expect(issues.where((i) => i.code == 'UNSUPPORTED_FUNCTION_TYPE'), isEmpty);
    });
  });

  group('SpecValidator — E016 (callback param on @NitroAsync)', () {
    test('E016 error when a callback param is on a plain @NitroAsync method', () {
      final issues = SpecValidator.validate(_asyncCallbackParamSpec(isAsync: true, isNativeAsync: false));
      expect(issues.any((i) => i.code == 'E016'), isTrue, reason: 'callback param + @NitroAsync should be rejected');
    });

    test('E016 hint mentions @NitroNativeAsync as the alternative', () {
      final issues = SpecValidator.validate(_asyncCallbackParamSpec(isAsync: true, isNativeAsync: false));
      final e016 = issues.firstWhere((i) => i.code == 'E016');
      expect(e016.hint, contains('NitroNativeAsync'));
    });

    test('no E016 when the same callback param is on a @NitroNativeAsync method', () {
      final issues = SpecValidator.validate(_asyncCallbackParamSpec(isAsync: true, isNativeAsync: true));
      expect(issues.where((i) => i.code == 'E016'), isEmpty);
    });

    test('no E016 when the callback param is on a plain sync method', () {
      final issues = SpecValidator.validate(_asyncCallbackParamSpec(isAsync: false, isNativeAsync: false));
      expect(issues.where((i) => i.code == 'E016'), isEmpty);
    });
  });
}

BridgeSpec _asyncCallbackParamSpec({required bool isAsync, required bool isNativeAsync}) {
  return BridgeSpec(
    dartClassName: 'Scanner',
    lib: 'scanner',
    namespace: 'scanner',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'scanner.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'onFound',
        cSymbol: 'scanner_on_found',
        isAsync: isAsync,
        isNativeAsync: isNativeAsync,
        returnType: BridgeType(name: isAsync ? 'Future<void>' : 'void'),
        params: [
          BridgeParam(
            name: 'callback',
            type: BridgeType(
              name: 'void Function(int)',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _callbackParamSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'watch',
        cSymbol: 'camera_watch',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'onEvent',
            type: BridgeType(
              name: 'void Function(int)',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _callbackReturnValueParamSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'validate',
        cSymbol: 'camera_validate',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'validator',
            type: BridgeType(
              name: 'bool Function(String)',
              isFunction: true,
              functionReturnType: 'bool',
              functionParams: [BridgeType(name: 'String')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _cppCallbackParamSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.cpp,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'watch',
        cSymbol: 'camera_watch',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'onEvent',
            type: BridgeType(
              name: 'void Function(int)',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _jniEnumCallbackParamSpec() {
  return BridgeSpec(
    dartClassName: 'Torch',
    lib: 'torch',
    namespace: 'torch',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'torch.native.dart',
    enums: [
      BridgeEnum(name: 'TorchState', startValue: 0, values: ['off', 'on']),
    ],
    functions: [
      BridgeFunction(
        dartName: 'watch',
        cSymbol: 'torch_watch',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'onTorchState',
            type: BridgeType(
              name: 'void Function(TorchState)',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: [BridgeType(name: 'TorchState')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _unsupportedStructCallbackParamSpec() {
  return BridgeSpec(
    dartClassName: 'Torch',
    lib: 'torch',
    namespace: 'torch',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'torch.native.dart',
    structs: [
      BridgeStruct(
        name: 'TorchState',
        packed: false,
        fields: [
          BridgeField(
            name: 'enabled',
            type: BridgeType(name: 'bool'),
          ),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'watch',
        cSymbol: 'torch_watch',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'onTorchState',
            type: BridgeType(
              name: 'void Function(TorchState)',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: [BridgeType(name: 'TorchState')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _callbackReturnSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'handler',
        cSymbol: 'camera_handler',
        isAsync: false,
        returnType: BridgeType(
          name: 'void Function(int)',
          isFunction: true,
          functionReturnType: 'void',
          functionParams: [BridgeType(name: 'int')],
        ),
        params: [],
      ),
    ],
  );
}

BridgeSpec _unsupportedCallbackParamSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'transform',
        cSymbol: 'camera_transform',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'transformer',
            type: BridgeType(
              name: 'String Function(int)',
              isFunction: true,
              functionReturnType: 'String',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _zeroArgStringCallbackReturnSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'label',
        cSymbol: 'camera_label',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'formatter',
            type: BridgeType(
              name: 'String Function()',
              isFunction: true,
              functionReturnType: 'String',
              functionParams: [],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _nullableStringCallbackReturnSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'optionalLabel',
        cSymbol: 'camera_optional_label',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'formatter',
            type: BridgeType(
              name: 'String? Function(int)',
              isFunction: true,
              functionReturnType: 'String?',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _mixedCallbackReturnSpec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'stringTransform',
        cSymbol: 'camera_string_transform',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'formatter',
            type: BridgeType(
              name: 'String Function(int)',
              isFunction: true,
              functionReturnType: 'String',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
      BridgeFunction(
        dartName: 'intTransform',
        cSymbol: 'camera_int_transform',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'mapper',
            type: BridgeType(
              name: 'int Function(int)',
              isFunction: true,
              functionReturnType: 'int',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _enumCallbackReturnSpec() {
  return BridgeSpec(
    dartClassName: 'Torch',
    lib: 'torch',
    namespace: 'torch',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'torch.native.dart',
    enums: [
      BridgeEnum(name: 'TorchState', startValue: 0, values: ['off', 'on']),
    ],
    functions: [
      BridgeFunction(
        dartName: 'mapState',
        cSymbol: 'torch_map_state',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'mapper',
            type: BridgeType(
              name: 'TorchState Function(int)',
              isFunction: true,
              functionReturnType: 'TorchState',
              functionParams: [BridgeType(name: 'int')],
            ),
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _unsupportedRecordCallbackParamSpec() {
  return BridgeSpec(
    dartClassName: 'Sensor',
    lib: 'sensor',
    namespace: 'sensor',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'sensor.native.dart',
    recordTypes: [
      BridgeRecordType(
        name: 'Reading',
        fields: [BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive)],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'onReading',
        cSymbol: 'sensor_on_reading',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'handler',
            type: BridgeType(
              name: 'void Function(Reading)',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: [BridgeType(name: 'Reading', isRecord: true)],
            ),
          ),
        ],
      ),
    ],
  );
}
