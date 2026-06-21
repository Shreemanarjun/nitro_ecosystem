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

      expect(out, contains('final Map<Object, NativeCallable<dynamic>> _nativeCallbackCache = {};'));
      expect(out, contains('void Function(Pointer<NativeFunction<Void Function(Int64)>>, Pointer<NitroErrorFfi>) _watchPtr'));
      expect(out, contains('NativeCallable<Void Function(Int64)> _nativeCallbackWatchOnEvent(void Function(int) callback)'));
      expect(out, contains("final key = ('watch.onEvent', callback);"));
      expect(out, contains('NativeCallable<Void Function(Int64)>.listener((int arg0)'));
      expect(out, contains('callback(arg0);'));
      expect(out, contains('_watchPtr(_nativeCallbackWatchOnEvent(onEvent).nativeFunction, _nitroErr);'));
      expect(out, contains('callback.close();'));
      expect(out, contains('_nativeCallbackCache.clear();'));
    });

    test('DartFfiGenerator supports primitive return callbacks using isolateLocal', () {
      final out = DartFfiGenerator.generate(_callbackReturnValueParamSpec());

      expect(out, contains('Pointer<NativeFunction<Int8 Function(Pointer<Utf8>)>>'));
      expect(out, contains('NativeCallable<Int8 Function(Pointer<Utf8>)>.isolateLocal((Pointer<Utf8> arg0)'));
      expect(out, contains('return callback(arg0.toDartString()) ? 1 : 0;'));
      expect(out, contains('exceptionalReturn: 0'));
    });

    test('CppHeaderGenerator emits real function pointer callback parameters', () {
      final out = CppHeaderGenerator.generate(_callbackParamSpec());

      expect(out, contains('NITRO_EXPORT void camera_watch(void (*onEvent)(int64_t), NitroError* _nitro_err);'));
    });

    test('C++ interface and bridge preserve callback function pointer ABI', () {
      final spec = _cppCallbackParamSpec();
      final iface = CppInterfaceGenerator.generate(spec);
      final bridge = CppBridgeGenerator.generate(spec);

      expect(iface, contains('virtual void watch(void (*onEvent)(int64_t)) = 0;'));
      expect(bridge, contains('void camera_watch(void (*onEvent)(int64_t), NitroError* _nitro_err)'));
      expect(bridge, contains('g_impl->watch(onEvent);'));
      expect(bridge, isNot(contains('void* onEvent')));
    });

    test('C bridge JNI signature treats enum callback params as function-pointer longs', () {
      final bridge = CppBridgeGenerator.generate(_jniEnumCallbackParamSpec());

      expect(bridge, contains('torch_watch'));
      expect(bridge, contains('void torch_watch(void (*onTorchState)(int64_t), NitroError* _nitro_err)'));
      expect(bridge, contains('GetStaticMethodID(g_bridgeClass, "watch_call", "(J)V")'));
      expect(bridge, contains('CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)onTorchState)'));
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
      final issues = SpecValidator.validate(_unsupportedCallbackParamSpec());

      final issue = issues.singleWhere((i) => i.code == 'UNSUPPORTED_FUNCTION_TYPE');
      expect(issue.isError, isTrue);
      expect(issue.message, contains('callback return type "String"'));
    });
  });
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
