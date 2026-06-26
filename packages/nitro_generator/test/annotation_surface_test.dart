import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeVariant _tcEventVariant() => BridgeVariant(
  name: 'TcEvent',
  cases: [
    BridgeVariantCase(
      name: 'TcEventStarted',
      label: 'started',
      fields: [
        BridgeRecordField(
          name: 'id',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
    BridgeVariantCase(
      name: 'TcEventStopped',
      label: 'stopped',
      fields: [],
    ),
  ],
);

BridgeSpec _annotationSurfaceSpec() => BridgeSpec(
  dartClassName: 'NitroTypeCoverage',
  lib: 'nitro_type_coverage',
  namespace: 'nitro_type_coverage',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'nitro_type_coverage.native.dart',
  variants: [_tcEventVariant()],
  functions: [
    BridgeFunction(
      dartName: 'acquireBuffer',
      cSymbol: 'nitro_type_coverage_acquire_buffer',
      isAsync: false,
      returnType: BridgeType(
        name: 'NativeHandle<Void>',
        isNativeHandle: true,
        nativeHandleTypeParam: 'Void',
      ),
      params: [
        BridgeParam(
          name: 'size',
          type: BridgeType(name: 'int'),
        ),
      ],
      isOwned: true,
    ),
    BridgeFunction(
      dartName: 'echoEvent',
      cSymbol: 'nitro_type_coverage_echo_event',
      isAsync: false,
      returnType: BridgeType(name: 'TcEvent'),
      params: [
        BridgeParam(
          name: 'event',
          type: BridgeType(name: 'TcEvent'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'safeDiv',
      cSymbol: 'nitro_type_coverage_safe_div',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
      isResult: true,
    ),
    BridgeFunction(
      dartName: 'validateLabel',
      cSymbol: 'nitro_type_coverage_validate_label',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'label',
          type: BridgeType(name: 'String'),
        ),
      ],
      isResult: true,
    ),
  ],
);

BridgeSpec _wrappedResultSpec() => BridgeSpec(
  dartClassName: 'MathApi',
  lib: 'math_api',
  namespace: 'math_api',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'math_api.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'safeDiv',
      cSymbol: 'math_api_safe_div',
      isAsync: false,
      returnType: BridgeType(name: 'NitroResultValue<double>'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
      isResult: true,
    ),
  ],
);

void main() {
  group('DartFfiGenerator — annotation surface regressions', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_annotationSurfaceSpec()));

    test('implements @NitroOwned NativeHandle method', () {
      expect(code, contains('NativeHandle<Void> acquireBuffer(int size)'));
      expect(code, contains('_acquireBufferReleaseFn'));
      expect(code, contains('_acquireBufferFinalizer.attach(handle'));
    });

    test('implements @NitroVariant parameter and return method', () {
      expect(code, contains('TcEvent echoEvent(TcEvent event)'));
      expect(code, contains('event.toNative(arena)'));
      expect(code, contains('TcEventVariantExt.fromNative(res)'));
    });

    test('accepts @NitroVariant names during validation', () {
      final issues = SpecValidator.validate(_annotationSurfaceSpec());
      expect(issues.where((issue) => issue.code == 'E010'), isEmpty);
    });

    test('implements @NitroResult primitive methods with exact API return types', () {
      expect(code, contains('NitroResultValue<double> safeDiv(double a, double b)'));
      expect(code, contains('NitroResultValue<String> validateLabel(String label)'));
      expect(code, isNot(contains('NitroResultValue<NitroResultValue')));
    });
  });

  group('DartFfiGenerator — wrapped @NitroResult fallback', () {
    test('unwraps NitroResultValue<T> instead of nesting it', () {
      final code = DartFfiGenerator.generate(_wrappedResultSpec());
      expect(code, contains('NitroResultValue<double> safeDiv(double a, double b)'));
      expect(code, isNot(contains('NitroResultValue<NitroResultValue<double>>')));
      expect(code, contains('return NitroOk(_r.readDouble())'));
    });
  });
}
