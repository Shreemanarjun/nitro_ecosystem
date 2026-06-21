// S8 runtime tests for NitroRuntime.throwIfOutParamError.
//
// Tests the correctness of the out-param error slot at the Dart runtime level:
//   - No-op when hasError == 0
//   - Throws HybridException with correct fields when hasError != 0
//   - Resets the slot (hasError → 0, pointers → nullptr) after throwing
//   - Handles nullptr name/message fields gracefully (uses fallback strings)
//   - Slot can be reused immediately after an error (hasError is reset)

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

// Helper: allocate a NitroErrorFfi slot, populate fields, return ptr.
// Caller is responsible for calloc.free(ptr) AFTER the test assertion
// (throwIfOutParamError frees the string fields but not the struct itself).
Pointer<NitroErrorFfi> _makeError({
  required int hasError,
  String? name,
  String? message,
  String? code,
  String? stackTrace,
}) {
  final ptr = calloc<NitroErrorFfi>();
  ptr.ref.hasError = hasError;
  ptr.ref.name = name != null ? name.toNativeUtf8() : nullptr;
  ptr.ref.message = message != null ? message.toNativeUtf8() : nullptr;
  ptr.ref.code = code != null ? code.toNativeUtf8() : nullptr;
  ptr.ref.stackTrace = stackTrace != null ? stackTrace.toNativeUtf8() : nullptr;
  return ptr;
}

void main() {
  group('NitroRuntime.throwIfOutParamError', () {
    test('no-op when hasError == 0 (happy path)', () {
      final ptr = calloc<NitroErrorFfi>();
      ptr.ref.hasError = 0;
      expect(() => NitroRuntime.throwIfOutParamError(ptr), returnsNormally);
      calloc.free(ptr);
    });

    test('throws HybridException when hasError != 0', () {
      final ptr = _makeError(hasError: 1, name: 'TestError', message: 'bang');
      expect(
        () => NitroRuntime.throwIfOutParamError(ptr),
        throwsA(isA<HybridException>()),
      );
      calloc.free(ptr);
    });

    test('exception carries correct name and message', () {
      final ptr = _makeError(
          hasError: 1, name: 'CppException', message: 'division by zero');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
        fail('should have thrown');
      } on HybridException catch (e) {
        expect(e.name, 'CppException');
        expect(e.message, 'division by zero');
      }
      calloc.free(ptr);
    });

    test('exception carries optional code when provided', () {
      final ptr = _makeError(
          hasError: 1, name: 'E', message: 'm', code: 'ERR_404');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.code, 'ERR_404');
      }
      calloc.free(ptr);
    });

    test('exception carries optional stackTrace when provided', () {
      final ptr = _makeError(
          hasError: 1, name: 'E', message: 'm', stackTrace: 'at foo:42');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.stackTrace, 'at foo:42');
      }
      calloc.free(ptr);
    });

    test('resets hasError to 0 after throwing', () {
      final ptr = _makeError(hasError: 1, name: 'E', message: 'msg');
      try { NitroRuntime.throwIfOutParamError(ptr); } catch (_) {}
      expect(ptr.ref.hasError, 0);
      calloc.free(ptr);
    });

    test('resets name pointer to nullptr after freeing', () {
      final ptr = _makeError(hasError: 1, name: 'E', message: 'msg');
      try { NitroRuntime.throwIfOutParamError(ptr); } catch (_) {}
      expect(ptr.ref.name, equals(nullptr));
      calloc.free(ptr);
    });

    test('resets message pointer to nullptr after freeing', () {
      final ptr = _makeError(hasError: 1, name: 'E', message: 'msg');
      try { NitroRuntime.throwIfOutParamError(ptr); } catch (_) {}
      expect(ptr.ref.message, equals(nullptr));
      calloc.free(ptr);
    });

    test('slot can be reused immediately after error (hasError reset)', () {
      final ptr = _makeError(hasError: 1, name: 'E', message: 'first');
      try { NitroRuntime.throwIfOutParamError(ptr); } catch (_) {}
      // Slot is now clean — reuse it for a second error
      ptr.ref.hasError = 1;
      ptr.ref.name = 'second'.toNativeUtf8();
      ptr.ref.message = 'error'.toNativeUtf8();
      try {
        NitroRuntime.throwIfOutParamError(ptr);
        fail('should throw second time too');
      } on HybridException catch (e) {
        expect(e.name, 'second');
      }
      calloc.free(ptr);
    });

    test('null name uses fallback "NativeException"', () {
      final ptr = _makeError(hasError: 1, message: 'boom');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.name, 'NativeException');
      }
      calloc.free(ptr);
    });

    test('null message uses fallback non-empty string', () {
      final ptr = _makeError(hasError: 1, name: 'E');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.message, isNotEmpty);
      }
      calloc.free(ptr);
    });

    test('code == nullptr → exception.code is null', () {
      final ptr = _makeError(hasError: 1, name: 'E', message: 'm');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.code, isNull);
      }
      calloc.free(ptr);
    });

    test('stackTrace == nullptr → exception.stackTrace is null', () {
      final ptr = _makeError(hasError: 1, name: 'E', message: 'm');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.stackTrace, isNull);
      }
      calloc.free(ptr);
    });

    test('1000 rapid no-error calls — slot stays clean throughout', () {
      final ptr = calloc<NitroErrorFfi>();
      ptr.ref.hasError = 0;
      for (var i = 0; i < 1000; i++) {
        expect(() => NitroRuntime.throwIfOutParamError(ptr), returnsNormally);
        expect(ptr.ref.hasError, 0);
      }
      calloc.free(ptr);
    });

    test('error with non-ASCII characters in message', () {
      final ptr = _makeError(
          hasError: 1, name: 'UnicodeError', message: 'Héllo Wörld — 日本語');
      try {
        NitroRuntime.throwIfOutParamError(ptr);
      } on HybridException catch (e) {
        expect(e.message, isNotEmpty);
      }
      calloc.free(ptr);
    });
  });
}
