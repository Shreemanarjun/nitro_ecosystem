import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:test/test.dart';

void main() {
  group('Named callback parameters', () {
    test('single named callback parameter', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'onValueChanged',
        type: callbackType,
        isNamed: true,
      );

      expect(param.isNamed, isTrue);
      expect(param.type.isFunction, isTrue);
      expect(param.name, 'onValueChanged');
    });

    test('required named callback parameter', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String')],
      );
      final param = BridgeParam(
        name: 'onEvent',
        type: callbackType,
        isNamed: true,
        isOptional: false,
      );

      expect(param.isNamed, isTrue);
      expect(param.isOptional, isFalse);
      expect(param.type.functionParams.first.name, 'String');
    });

    test('optional named callback parameter', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'double')],
      );
      final param = BridgeParam(
        name: 'onUpdate',
        type: callbackType,
        isNamed: true,
        isOptional: true,
      );

      expect(param.isNamed, isTrue);
      expect(param.isOptional, isTrue);
    });
  });

  group('Multiple callback parameters', () {
    test('two callback parameters', () {
      final onSuccess = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String')],
      );
      final onError = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String')],
      );
      final func = BridgeFunction(
        dartName: 'fetchData',
        cSymbol: 'fetch_data',
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(name: 'onSuccess', type: onSuccess, isNamed: true),
          BridgeParam(name: 'onError', type: onError, isNamed: true),
        ],
        isAsync: false,
      );

      expect(func.params, hasLength(2));
      expect(func.params[0].type.isFunction, isTrue);
      expect(func.params[1].type.isFunction, isTrue);
      expect(func.params[0].name, 'onSuccess');
      expect(func.params[1].name, 'onError');
    });

    test('mixed callback and non-callback parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [],
      );
      final func = BridgeFunction(
        dartName: 'process',
        cSymbol: 'process',
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(name: 'url', type: BridgeType(name: 'String')),
          BridgeParam(name: 'timeout', type: BridgeType(name: 'int')),
          BridgeParam(name: 'onComplete', type: callbackType, isNamed: true),
        ],
        isAsync: false,
      );

      expect(func.params, hasLength(3));
      expect(func.params[0].type.isFunction, isFalse);
      expect(func.params[1].type.isFunction, isFalse);
      expect(func.params[2].type.isFunction, isTrue);
    });
  });

  group('Callbacks with different return types', () {
    test('callback returning bool', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'bool',
        functionParams: [BridgeType(name: 'String')],
      );
      final param = BridgeParam(
        name: 'validator',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'bool');
      expect(param.type.functionParams, hasLength(1));
    });

    test('callback returning String', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'String',
        functionParams: [BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'transformer',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'String');
    });

    test('callback returning double', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'double',
        functionParams: [BridgeType(name: 'int'), BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'calculator',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'double');
      expect(param.type.functionParams, hasLength(2));
    });

    test('callback returning int', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'int',
        functionParams: [],
      );
      final param = BridgeParam(
        name: 'counter',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'int');
      expect(param.type.functionParams, isEmpty);
    });
  });

  group('Callbacks with multiple parameters', () {
    test('callback with two parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String'), BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'handler',
        type: callbackType,
      );

      expect(param.type.functionParams, hasLength(2));
      expect(param.type.functionParams[0].name, 'String');
      expect(param.type.functionParams[1].name, 'int');
    });

    test('callback with three parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [
          BridgeType(name: 'String'),
          BridgeType(name: 'int'),
          BridgeType(name: 'double'),
        ],
      );
      final param = BridgeParam(
        name: 'processor',
        type: callbackType,
      );

      expect(param.type.functionParams, hasLength(3));
    });

    test('callback with four parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [
          BridgeType(name: 'String'),
          BridgeType(name: 'int'),
          BridgeType(name: 'double'),
          BridgeType(name: 'bool'),
        ],
      );
      final param = BridgeParam(
        name: 'complexHandler',
        type: callbackType,
      );

      expect(param.type.functionParams, hasLength(4));
    });
  });

  group('Callbacks with struct parameters', () {
    test('callback with struct parameter', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'CameraSettings')],
      );
      final param = BridgeParam(
        name: 'onSettingsChanged',
        type: callbackType,
        isNamed: true,
      );

      expect(param.type.functionParams.first.name, 'CameraSettings');
      expect(param.type.functionParams.first.isFunction, isFalse);
    });

    test('callback with multiple struct parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [
          BridgeType(name: 'CameraSettings'),
          BridgeType(name: 'CaptureConfig'),
        ],
      );
      final param = BridgeParam(
        name: 'onConfigUpdate',
        type: callbackType,
      );

      expect(param.type.functionParams, hasLength(2));
      expect(param.type.functionParams[0].name, 'CameraSettings');
      expect(param.type.functionParams[1].name, 'CaptureConfig');
    });
  });

  group('Callbacks with enum parameters', () {
    test('callback with enum parameter', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'TorchState')],
      );
      final param = BridgeParam(
        name: 'onStateChanged',
        type: callbackType,
        isNamed: true,
      );

      expect(param.type.functionParams.first.name, 'TorchState');
    });

    test('callback with multiple enum parameters', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [
          BridgeType(name: 'TorchState'),
          BridgeType(name: 'Quality'),
        ],
      );
      final param = BridgeParam(
        name: 'onStateQualityChange',
        type: callbackType,
      );

      expect(param.type.functionParams, hasLength(2));
    });
  });

  group('Callbacks with nullable parameters', () {
    test('callback with nullable return type', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'String?',
        functionParams: [BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'getter',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'String?');
    });

    test('callback with nullable parameter', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String?')],
      );
      final param = BridgeParam(
        name: 'handler',
        type: callbackType,
      );

      expect(param.type.functionParams.first.name, 'String?');
    });
  });

  group('Callbacks with complex signatures', () {
    test('callback with struct return type', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'CameraSettings',
        functionParams: [BridgeType(name: 'int')],
      );
      final param = BridgeParam(
        name: 'settingsProvider',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'CameraSettings');
    });

    test('callback with enum return type', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'TorchState',
        functionParams: [],
      );
      final param = BridgeParam(
        name: 'stateProvider',
        type: callbackType,
      );

      expect(param.type.functionReturnType, 'TorchState');
    });

    test('callback with mixed parameter types', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'bool',
        functionParams: [
          BridgeType(name: 'String'),
          BridgeType(name: 'int'),
          BridgeType(name: 'CameraSettings'),
          BridgeType(name: 'TorchState'),
        ],
      );
      final param = BridgeParam(
        name: 'complexValidator',
        type: callbackType,
      );

      expect(param.type.functionParams, hasLength(4));
      expect(param.type.functionParams[0].name, 'String');
      expect(param.type.functionParams[1].name, 'int');
      expect(param.type.functionParams[2].name, 'CameraSettings');
      expect(param.type.functionParams[3].name, 'TorchState');
    });
  });

  group('BridgeFunction with callback return type', () {
    test('function returning a callback', () {
      final callbackType = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'int')],
      );
      final func = BridgeFunction(
        dartName: 'getHandler',
        cSymbol: 'get_handler',
        returnType: callbackType,
        params: [],
        isAsync: false,
      );

      expect(func.returnType.isFunction, isTrue);
      expect(func.returnType.functionReturnType, 'void');
      expect(func.returnType.functionParams, hasLength(1));
    });
  });

  group('Edge cases for function type detection', () {
    test('BridgeType with isFunction=false ignores function fields', () {
      final type = BridgeType(
        name: 'Function',
        isFunction: false,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'int')],
      );

      expect(type.isFunction, isFalse);
      // Function fields are set but should be ignored when isFunction is false
      expect(type.functionReturnType, 'void');
      expect(type.functionParams, hasLength(1));
    });

    test('BridgeType with empty function params', () {
      final type = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [],
      );

      expect(type.isFunction, isTrue);
      expect(type.functionParams, isEmpty);
    });

    test('BridgeType with default function params', () {
      final type = BridgeType(name: 'Function');

      expect(type.isFunction, isFalse);
      expect(type.functionReturnType, isNull);
      expect(type.functionParams, isEmpty);
    });
  });

  group('Real-world callback patterns', () {
    test('success/error callback pattern', () {
      final onSuccess = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String')],
      );
      final onError = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String')],
      );
      final func = BridgeFunction(
        dartName: 'fetchData',
        cSymbol: 'fetch_data',
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(name: 'url', type: BridgeType(name: 'String')),
          BridgeParam(name: 'onSuccess', type: onSuccess, isNamed: true),
          BridgeParam(name: 'onError', type: onError, isNamed: true),
        ],
        isAsync: false,
      );

      expect(func.params, hasLength(3));
      expect(func.params[1].type.isFunction, isTrue);
      expect(func.params[2].type.isFunction, isTrue);
    });

    test('progress callback pattern', () {
      final onProgress = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'double')],
      );
      final func = BridgeFunction(
        dartName: 'download',
        cSymbol: 'download',
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(name: 'url', type: BridgeType(name: 'String')),
          BridgeParam(name: 'onProgress', type: onProgress, isNamed: true),
        ],
        isAsync: false,
      );

      expect(func.params[1].type.functionParams.first.name, 'double');
    });

    test('event listener callback pattern', () {
      final onEvent = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'void',
        functionParams: [BridgeType(name: 'String'), BridgeType(name: 'String')],
      );
      final func = BridgeFunction(
        dartName: 'addEventListener',
        cSymbol: 'add_event_listener',
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(name: 'eventType', type: BridgeType(name: 'String')),
          BridgeParam(name: 'onEvent', type: onEvent),
        ],
        isAsync: false,
      );

      expect(func.params[1].type.functionParams, hasLength(2));
    });

    test('validator callback pattern', () {
      final validator = BridgeType(
        name: 'Function',
        isFunction: true,
        functionReturnType: 'bool',
        functionParams: [BridgeType(name: 'String')],
      );
      final func = BridgeFunction(
        dartName: 'validate',
        cSymbol: 'validate',
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(name: 'input', type: BridgeType(name: 'String')),
          BridgeParam(name: 'validator', type: validator),
        ],
        isAsync: false,
      );

      expect(func.params[1].type.functionReturnType, 'bool');
    });
  });
}
