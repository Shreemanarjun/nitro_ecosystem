// Tests for typed-list (Float32List etc.) bridging and error-propagation fixes.
//
// Regression coverage for three bugs:
//   1. Swift @_cdecl functions generated `[Float]` for Float32List params —
//      not C-ABI compatible, causing crashes when C passed a raw float*.
//      Fixed by using UnsafeMutablePointer<Float>? + a separate length param.
//   2. No length was passed for typed-list params, so native code could not
//      reconstruct the array. Fixed by adding int64_t <name>_length companion
//      params throughout the C/Swift/Dart layers.
//   3. Bridge .cpp files on iOS were compiled as pure C++ (not Objective-C++),
//      so __OBJC__ was never defined and the @try/@catch (NSException*) blocks
//      were excluded. Any NSException raised by the Swift impl propagated
//      uncaught through the C++ stack → crash instead of Dart exception.
//      Fixed by renaming .bridge.g.cpp → .bridge.g.mm in ios/Classes/ so
//      Xcode compiles them as Objective-C++, enabling __OBJC__.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/cpp/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/cpp/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/ios/swift_generator.dart';

import 'package:test/test.dart';

// ── Spec helpers ─────────────────────────────────────────────────────────────

/// A spec that mirrors the `processFloats(Float32List) -> FloatBuffer` pattern.
BridgeSpec _floatSpec() {
  return BridgeSpec(
    dartClassName: 'Verification',
    lib: 'verification',
    namespace: 'verification_module',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'verification.native.dart',
    structs: [
      BridgeStruct(
        name: 'FloatBuffer',
        packed: false,
        fields: [
          BridgeField(
            name: 'data',
            type: BridgeType(name: 'Float32List'),
            zeroCopy: true,
          ),
          BridgeField(
            name: 'length',
            type: BridgeType(name: 'int'),
          ),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'processFloats',
        cSymbol: 'verification_module_process_floats',
        isAsync: false,
        returnType: BridgeType(name: 'FloatBuffer'),
        params: [
          BridgeParam(
            name: 'inputs',
            type: BridgeType(name: 'Float32List'),
          ),
        ],
      ),
    ],
  );
}

/// A spec with multiple typed-list param types to verify all element types.
BridgeSpec _multiTypedListSpec() {
  return BridgeSpec(
    dartClassName: 'Buf',
    lib: 'buf',
    namespace: 'buf_module',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'buf.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'writeBytes',
        cSymbol: 'buf_module_write_bytes',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'data',
            type: BridgeType(name: 'Uint8List'),
          ),
        ],
      ),
      BridgeFunction(
        dartName: 'writeDoubles',
        cSymbol: 'buf_module_write_doubles',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'samples',
            type: BridgeType(name: 'Float64List'),
          ),
        ],
      ),
      BridgeFunction(
        dartName: 'writeInts',
        cSymbol: 'buf_module_write_ints',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'values',
            type: BridgeType(name: 'Int32List'),
          ),
        ],
      ),
    ],
  );
}

/// A spec with a non-typed-list param to confirm ordinary params are unaffected.
BridgeSpec _mixedParamSpec() {
  return BridgeSpec(
    dartClassName: 'Mix',
    lib: 'mix',
    namespace: 'mix_module',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'mix.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'process',
        cSymbol: 'mix_module_process',
        isAsync: false,
        returnType: BridgeType(name: 'double'),
        params: [
          BridgeParam(
            name: 'label',
            type: BridgeType(name: 'String'),
          ),
          BridgeParam(
            name: 'data',
            type: BridgeType(name: 'Float32List'),
          ),
          BridgeParam(
            name: 'scale',
            type: BridgeType(name: 'double'),
          ),
        ],
      ),
    ],
  );
}

void main() {
  // ── CppHeaderGenerator ─────────────────────────────────────────────────────

  group('CppHeaderGenerator — typed-list length param', () {
    test('Float32List param gets a companion int64_t <name>_length param', () {
      final out = CppHeaderGenerator.generate(_floatSpec());
      expect(
        out,
        contains('float* inputs, int64_t inputs_length'),
        reason: 'C header must declare the pointer AND a length param',
      );
    });

    test('bare float* without length is not present', () {
      final out = CppHeaderGenerator.generate(_floatSpec());
      // The only occurrence of "float* inputs" must be followed by ", int64_t"
      expect(
        out,
        isNot(contains('float* inputs)')),
        reason: 'length-less signature must not appear',
      );
    });

    test('Uint8List param gets uint8_t* + int64_t length', () {
      final out = CppHeaderGenerator.generate(_multiTypedListSpec());
      expect(out, contains('uint8_t* data, int64_t data_length'));
    });

    test('Float64List param gets double* + int64_t length', () {
      final out = CppHeaderGenerator.generate(_multiTypedListSpec());
      expect(out, contains('double* samples, int64_t samples_length'));
    });

    test('Int32List param gets int32_t* + int64_t length', () {
      final out = CppHeaderGenerator.generate(_multiTypedListSpec());
      expect(out, contains('int32_t* values, int64_t values_length'));
    });

    test('non-typed-list params are not given a length companion', () {
      final out = CppHeaderGenerator.generate(_mixedParamSpec());
      // String param "label" must NOT gain a label_length
      expect(out, isNot(contains('label_length')));
      // double param "scale" must NOT gain a scale_length
      expect(out, isNot(contains('scale_length')));
    });

    test('mixed-param signature has correct order: label, data, data_length, scale', () {
      final out = CppHeaderGenerator.generate(_mixedParamSpec());
      expect(
        out,
        contains('const char* label, float* data, int64_t data_length, double scale'),
      );
    });
  });

  // ── CppBridgeGenerator ─────────────────────────────────────────────────────

  group('CppBridgeGenerator — iOS section typed-list length', () {
    test('extern _call_ declaration includes length param', () {
      final out = CppBridgeGenerator.generate(_floatSpec());
      expect(
        out,
        contains('extern void* _call_processFloats(float* inputs, int64_t inputs_length)'),
        reason: 'extern C declaration must forward the length to Swift',
      );
    });

    test('outer C function signature includes length param', () {
      final out = CppBridgeGenerator.generate(_floatSpec());
      expect(
        out,
        contains(
          'void* verification_module_process_floats(float* inputs, int64_t inputs_length)',
        ),
      );
    });

    test('call to _call_ stub forwards both pointer and length', () {
      final out = CppBridgeGenerator.generate(_floatSpec());
      expect(
        out,
        contains('_call_processFloats(inputs, inputs_length)'),
        reason: 'bridge must pass the length through to Swift',
      );
    });

    test('Android JNI outer function also has length param (signature parity)', () {
      final out = CppBridgeGenerator.generate(_floatSpec());
      // Both the Android and Apple sections compile the same outer symbol;
      // the declaration before #ifdef must include the length.
      expect(
        out,
        contains(
          'verification_module_process_floats(float* inputs, int64_t inputs_length)',
        ),
      );
    });

    test('Uint8List extern includes data_length', () {
      final out = CppBridgeGenerator.generate(_multiTypedListSpec());
      expect(out, contains('extern void _call_writeBytes(uint8_t* data, int64_t data_length)'));
    });

    test('mixed spec: only data param gets length, not label or scale', () {
      final out = CppBridgeGenerator.generate(_mixedParamSpec());
      expect(out, contains('data_length'));
      expect(out, isNot(contains('label_length')));
      expect(out, isNot(contains('scale_length')));
    });

    test('mixed spec: call to _call_process forwards all params in correct order', () {
      final out = CppBridgeGenerator.generate(_mixedParamSpec());
      expect(out, contains('_call_process(label, data, data_length, scale)'));
    });
  });

  // ── DartFfiGenerator ───────────────────────────────────────────────────────

  group('DartFfiGenerator — typed-list length in function pointer & call', () {
    test('lookupFunction native type includes Int64 after Pointer<Float>', () {
      final out = DartFfiGenerator.generate(_floatSpec());
      // The lookup signature must be: Pointer<Void> Function(Pointer<Float>, Int64)
      expect(
        out,
        contains('Pointer<Void> Function(Pointer<Float>, Int64)'),
        reason: 'native FFI type must include Int64 for the length',
      );
    });

    test('lookupFunction dart type includes int after Pointer<Float>', () {
      final out = DartFfiGenerator.generate(_floatSpec());
      expect(
        out,
        contains('Pointer<Void> Function(Pointer<Float>, int)'),
        reason: 'Dart FFI type must include int for the length',
      );
    });

    test('processFloats call passes inputs.length as second arg', () {
      final out = DartFfiGenerator.generate(_floatSpec());
      expect(
        out,
        contains('_processFloatsPtr(inputs.toPointer(arena), inputs.length)'),
        reason: 'Dart call must pass .length alongside the pointer',
      );
    });

    test('Uint8List lookup includes Int64 length', () {
      final out = DartFfiGenerator.generate(_multiTypedListSpec());
      expect(out, contains('Void Function(Pointer<Uint8>, Int64)'));
    });

    test('Float64List lookup includes Int64 length', () {
      final out = DartFfiGenerator.generate(_multiTypedListSpec());
      expect(out, contains('Void Function(Pointer<Double>, Int64)'));
    });

    test('Int32List lookup includes Int64 length', () {
      final out = DartFfiGenerator.generate(_multiTypedListSpec());
      expect(out, contains('Void Function(Pointer<Int32>, Int64)'));
    });

    test('non-typed-list params do not get an extra Int64 in the lookup', () {
      final out = DartFfiGenerator.generate(_mixedParamSpec());
      // label (String) → Pointer<Utf8>; scale (double) → Double
      // The signature must be exactly: Double Function(Pointer<Utf8>, Pointer<Float>, Int64, Double)
      expect(
        out,
        contains(
          'Double Function(Pointer<Utf8>, Pointer<Float>, Int64, Double)',
        ),
      );
    });

    test('mixed-param Dart call passes pointer, length, and plain double', () {
      final out = DartFfiGenerator.generate(_mixedParamSpec());
      expect(
        out,
        contains('_processPtr(label.toNativeUtf8(allocator: arena), data.toPointer(arena), data.length, scale)'),
      );
    });
  });

  // ── SwiftGenerator ─────────────────────────────────────────────────────────

  group('SwiftGenerator — @_cdecl C-ABI types for typed-list params', () {
    test('Float32List param uses UnsafeMutablePointer<Float>? not [Float]', () {
      final out = SwiftGenerator.generate(_floatSpec());
      // Regression: [Float] is a Swift Array — NOT C-ABI compatible.
      expect(
        out,
        contains('_ inputs: UnsafeMutablePointer<Float>?'),
        reason: '@_cdecl must use C-compatible pointer type for Float32List',
      );
      expect(
        out,
        isNot(contains('_ inputs: [Float]')),
        reason: 'Swift [Float] Array must never appear as a @_cdecl param',
      );
    });

    test('Float32List param gets a companion _ inputs_length: Int64', () {
      final out = SwiftGenerator.generate(_floatSpec());
      expect(
        out,
        contains('_ inputs_length: Int64'),
        reason: 'length must be passed as a separate C-ABI-compatible Int64',
      );
    });

    test('bridge body converts pointer+length to Swift Array via UnsafeBufferPointer', () {
      final out = SwiftGenerator.generate(_floatSpec());
      expect(
        out,
        contains(
          'let inputsArr = inputs.map { Array(UnsafeBufferPointer(start: \$0, count: Int(inputs_length))) } ?? []',
        ),
        reason: 'must construct [Float] from the raw pointer + length before calling impl',
      );
    });

    test('protocol call uses the converted Arr variable, not the raw pointer', () {
      final out = SwiftGenerator.generate(_floatSpec());
      expect(out, contains('inputs: inputsArr'));
      expect(
        out,
        isNot(contains('inputs: inputs)')),
        reason: 'passing raw UnsafeMutablePointer<Float>? to [Float] param would crash',
      );
    });

    test('Uint8List uses UnsafeMutablePointer<UInt8>? in @_cdecl', () {
      final out = SwiftGenerator.generate(_multiTypedListSpec());
      expect(out, contains('_ data: UnsafeMutablePointer<UInt8>?'));
      expect(out, isNot(contains('_ data: Data')));
      expect(out, isNot(contains('_ data: [UInt8]')));
    });

    test('Uint8List bridge body converts via UnsafeBufferPointer<UInt8>', () {
      final out = SwiftGenerator.generate(_multiTypedListSpec());
      expect(
        out,
        contains(
          'let dataArr = data.map { Array(UnsafeBufferPointer(start: \$0, count: Int(data_length))) } ?? []',
        ),
      );
    });

    test('Float64List uses UnsafeMutablePointer<Double>? in @_cdecl', () {
      final out = SwiftGenerator.generate(_multiTypedListSpec());
      expect(out, contains('_ samples: UnsafeMutablePointer<Double>?'));
      expect(out, isNot(contains('_ samples: [Double]')));
    });

    test('Int32List uses UnsafeMutablePointer<Int32>? in @_cdecl', () {
      final out = SwiftGenerator.generate(_multiTypedListSpec());
      expect(out, contains('_ values: UnsafeMutablePointer<Int32>?'));
      expect(out, isNot(contains('_ values: [Int32]')));
    });

    test('non-typed-list params are unaffected in mixed spec', () {
      final out = SwiftGenerator.generate(_mixedParamSpec());
      // String param must still use UnsafePointer<CChar>?
      expect(out, contains('_ label: UnsafePointer<CChar>?'));
      // double param stays as Double
      expect(out, contains('_ scale: Double'));
      // No spurious length params for non-list types
      expect(out, isNot(contains('label_length')));
      expect(out, isNot(contains('scale_length')));
    });

    test('no @_cdecl function uses a bare Swift Array type for any typed-list param', () {
      for (final spec in [_floatSpec(), _multiTypedListSpec(), _mixedParamSpec()]) {
        final out = SwiftGenerator.generate(spec);
        final lines = out.split('\n');
        bool inCdecl = false;
        for (final line in lines) {
          if (line.contains('@_cdecl(')) inCdecl = true;
          if (inCdecl && line.contains('public func')) {
            // Param line of a @_cdecl stub must not use a bare Swift array type
            expect(
              line,
              isNot(matches(r':\s+\[Float\]')),
              reason: 'Float32List must not appear as [Float] in @_cdecl',
            );
            expect(
              line,
              isNot(matches(r':\s+\[Double\]')),
              reason: 'Float64List must not appear as [Double] in @_cdecl',
            );
            expect(
              line,
              isNot(matches(r':\s+\[Int32\]')),
              reason: 'Int32List must not appear as [Int32] in @_cdecl',
            );
            expect(
              line,
              isNot(matches(r':\s+\[UInt8\]')),
              reason: 'Uint8List must not appear as [UInt8] in @_cdecl',
            );
            inCdecl = false;
          }
        }
      }
    });
  });

  // ── CppBridgeGenerator — __OBJC__ / NSException error propagation ──────────
  //
  // Regression: bridge .cpp files on iOS were compiled as pure C++, so
  // __OBJC__ was never defined. The @try/@catch blocks were dead code and any
  // NSException from Swift propagated uncaught → crash.
  // Fix: bridge files must be renamed .mm in ios/Classes/ (done by the link
  // command). These tests verify the generated source contains the right
  // structure so the rename actually helps.

  group('CppBridgeGenerator — __OBJC__ exception-catch structure', () {
    test('Apple section wraps every call in #ifdef __OBJC__ @try/@catch', () {
      final out = CppBridgeGenerator.generate(_floatSpec());
      expect(
        out,
        contains('#ifdef __OBJC__'),
        reason:
            'iOS bridge must guard the @try/@catch with __OBJC__ so it '
            'compiles correctly when the file is renamed to .mm',
      );
      expect(out, contains('@try {'));
      expect(out, contains('@catch (NSException* e) {'));
    });

    test('Apple section stores NSException via nitro_report_error', () {
      final out = CppBridgeGenerator.generate(_floatSpec());
      expect(
        out,
        contains('nitro_report_error([e.name UTF8String], [e.reason UTF8String]'),
      );
    });

    test('Apple section has #else fallback for non-ObjC++ compilation', () {
      // When compiled without __OBJC__ (shouldn't happen after .mm rename but
      // belt-and-suspenders), the bridge must still call the stub.
      final out = CppBridgeGenerator.generate(_floatSpec());
      expect(out, contains('#else'));
      expect(out, contains('#endif'));
    });

    test('throwError spec: void function @try block does not attempt return', () {
      final spec = BridgeSpec(
        dartClassName: 'Err',
        lib: 'err',
        namespace: 'err_module',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'err.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'throwError',
            cSymbol: 'err_module_throw_error',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'message',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // For void return, the @catch block must NOT emit a bare "return;"
      // before the closing brace — that would skip nitro_report_error.
      final appleSection = out.substring(out.indexOf('#elif __APPLE__'));
      final catchBlock = appleSection.substring(
        appleSection.indexOf('@catch (NSException* e) {'),
      );
      // nitro_report_error must appear before any closing brace
      final reportIdx = catchBlock.indexOf('nitro_report_error');
      final firstBrace = catchBlock.indexOf('}');
      expect(
        reportIdx < firstBrace,
        isTrue,
        reason: 'nitro_report_error must be called inside the @catch block',
      );
    });

    test('non-void function @catch block returns a default value after reporting', () {
      final spec = BridgeSpec(
        dartClassName: 'Calc',
        lib: 'calc',
        namespace: 'calc_module',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'calc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'compute',
            cSymbol: 'calc_module_compute',
            isAsync: false,
            returnType: BridgeType(name: 'double'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      final appleSection = out.substring(out.indexOf('#elif __APPLE__'));
      // @catch block for a double return must return 0.0 (the default value)
      expect(appleSection, contains('return 0.0;'));
    });

    test('every function in the spec has exactly one @try/@catch pair', () {
      final out = CppBridgeGenerator.generate(_multiTypedListSpec());
      final appleSection = out.substring(out.indexOf('#elif __APPLE__'));
      final tryCount = '@try {'.allMatches(appleSection).length;
      final catchCount = '@catch (NSException* e) {'.allMatches(appleSection).length;
      expect(tryCount, equals(3), reason: '_multiTypedListSpec has 3 functions');
      expect(catchCount, equals(3));
      expect(tryCount, equals(catchCount));
    });
  });
}
