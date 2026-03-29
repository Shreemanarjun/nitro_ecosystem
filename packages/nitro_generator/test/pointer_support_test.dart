import 'package:test/test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import '../lib/src/bridge_spec.dart';
import '../lib/src/spec_validator.dart';
import '../lib/src/generators/dart_ffi_generator.dart';

void main() {
  group('Pointer Support Tests', () {
    test('SpecValidator accepts Pointer types', () {
      final spec = BridgeSpec(
        dartClassName: 'BenchmarkCpp',
        lib: 'benchmark_cpp',
        namespace: 'benchmark_cpp',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'benchmark_cpp.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'sendLargeBufferUnsafe',
            cSymbol: 'benchmark_cpp_send_large_buffer_unsafe',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [
              BridgeParam(
                name: 'ptr',
                type: BridgeType(
                  name: 'Pointer<Uint8>',
                  isPointer: true,
                  pointerInnerType: 'Uint8',
                ),
              ),
              BridgeParam(
                name: 'length',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );

      final issues = SpecValidator.validate(spec);
      expect(issues.where((i) => i.isError), isEmpty);
    });

    test('DartFfiGenerator produces correct FFI mapping for Pointer types', () {
      final spec = BridgeSpec(
        dartClassName: 'PointerModule',
        lib: 'pointer_module',
        namespace: 'pointer_module',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'pointer_module.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'passPointer',
            cSymbol: 'pointer_module_pass_pointer',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'p',
                type: BridgeType(
                  name: 'Pointer<Void>',
                  isPointer: true,
                  pointerInnerType: 'Void',
                ),
              ),
            ],
          ),
        ],
      );

      final output = DartFfiGenerator.generate(spec);
      
      // Verify FFI signatures
      expect(output, contains('Void Function(Pointer<Void>)'));
      expect(output, contains('void Function(Pointer<Void>)'));
      
      // Verify implementation call (direct pass-through, no conversion)
      expect(output, contains('_passPointerPtr(p)'));
    });

    test('DartFfiGenerator handles Pointer return types', () {
      final spec = BridgeSpec(
        dartClassName: 'PointerModule',
        lib: 'pointer_module',
        namespace: 'pointer_module',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'pointer_module.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getBuffer',
            cSymbol: 'pointer_module_get_buffer',
            isAsync: false,
            returnType: BridgeType(
              name: 'Pointer<Uint8>',
              isPointer: true,
              pointerInnerType: 'Uint8',
            ),
            params: [],
          ),
        ],
      );

      final output = DartFfiGenerator.generate(spec);
      
      expect(output, contains('Pointer<Uint8> Function()'));
      expect(output, contains('Pointer<Uint8> getBuffer()'));
      expect(output, contains('return res;'));
    });
  });
}
