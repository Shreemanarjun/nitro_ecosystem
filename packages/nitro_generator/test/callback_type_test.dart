import 'package:nitro_generator/src/bridge_spec.dart';
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
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'callback',
            type: callbackType,
          ),
        ],
        isAsync: false,
      );

      expect(func.params.first.type.isFunction, isTrue);
      expect(func.params.first.type.functionReturnType, 'void');
    });
  });
}
