// Missing Swift generator coverage from §8.2 of the plan.
//
// Covers:
//   Section 1: Future<TypedData> async protocol signatures
//   Section 2: Future<Uint8List> async C bridge stub (DispatchSemaphore pattern)
//   Section 3: Synchronous TypedData return protocol signature

import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _asyncTypedDataSpec(String returnType) => BridgeSpec(
  dartClassName: 'Buf',
  lib: 'buf',
  namespace: 'buf',
  iosImpl: NativeImpl.swift,
  sourceUri: 'buf.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getData',
      cSymbol: 'buf_get_data',
      isAsync: true,
      returnType: BridgeType(name: returnType),
      params: [],
    ),
  ],
);

BridgeSpec _syncTypedDataReturnSpec(String returnType) => BridgeSpec(
  dartClassName: 'Buf',
  lib: 'buf',
  namespace: 'buf',
  iosImpl: NativeImpl.swift,
  sourceUri: 'buf.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'read',
      cSymbol: 'buf_read',
      isAsync: false,
      returnType: BridgeType(name: returnType),
      params: [],
    ),
  ],
);

void main() {
  // ── Section 1: Future<TypedData> async protocol signatures ───────────────────

  group('SwiftGenerator — Future<TypedData> async protocol signatures', () {
    test('Future<Uint8List> → async throws -> Data in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('async throws -> Data'));
    });

    test('Future<Int8List> → async throws -> Data in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Int8List'));
      expect(out, contains('async throws -> Data'));
    });

    test('Future<Int16List> → async throws -> [Int16] in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Int16List'));
      expect(out, contains('async throws -> [Int16]'));
    });

    test('Future<Int32List> → async throws -> [Int32] in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Int32List'));
      expect(out, contains('async throws -> [Int32]'));
    });

    test('Future<Float32List> → async throws -> [Float] in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Float32List'));
      expect(out, contains('async throws -> [Float]'));
    });

    test('Future<Float64List> → async throws -> [Double] in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Float64List'));
      expect(out, contains('async throws -> [Double]'));
    });

    test('Future<Int64List> → async throws -> [Int64] in protocol', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Int64List'));
      expect(out, contains('async throws -> [Int64]'));
    });
  });

  // ── Section 2: Future<Uint8List> async C bridge stub ────────────────────────

  group('SwiftGenerator — Future<Uint8List> async C bridge stub', () {
    test('Future<Uint8List> async stub emits DispatchSemaphore pattern', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('sema.wait()'));
    });

    test('Future<Uint8List> async stub stores result as Data?', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('var result: Data?'));
    });

    test('Future<Uint8List> async stub uses Task.detached', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('Task.detached'));
    });

    test('Future<Uint8List> async stub calls impl.getData via try? await', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('try? await impl.getData()'));
    });

    test('Future<Uint8List> async stub signals semaphore after await', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('sema.signal()'));
    });

    test('Future<Uint8List> async stub returns malloc-owned length-prefixed buffer', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Uint8List'));
      expect(out, contains('private func _nitroCopyTypedDataReturn(_ bytes: UnsafeRawBufferPointer)'));
      expect(out, contains('raw.storeBytes(of: Int64(byteLength), as: Int64.self)'));
      expect(out, contains('memcpy(raw.advanced(by: headerSize), base, byteLength)'));
      expect(out, contains('return r.withUnsafeBytes { _nitroCopyTypedDataReturn(\$0) }'));
    });

    test('Future<Float32List> async stub copies array return as bytes', () {
      final out = SwiftGenerator.generate(_asyncTypedDataSpec('Float32List'));
      expect(out, contains('var result: [Float]?'));
      expect(out, contains('return _nitroCopyTypedDataArrayReturn(r)'));
    });
  });

  // ── Section 3: Synchronous TypedData return in protocol ─────────────────────

  group('SwiftGenerator — synchronous TypedData return in protocol', () {
    test('Uint8List sync return → func read() -> Data in protocol', () {
      final out = SwiftGenerator.generate(_syncTypedDataReturnSpec('Uint8List'));
      expect(out, contains('func read() -> Data'));
    });

    test('Int8List sync return → func read() -> Data in protocol', () {
      final out = SwiftGenerator.generate(_syncTypedDataReturnSpec('Int8List'));
      expect(out, contains('func read() -> Data'));
    });

    test('Int16List sync return → func read() -> [Int16] in protocol', () {
      final out = SwiftGenerator.generate(_syncTypedDataReturnSpec('Int16List'));
      expect(out, contains('func read() -> [Int16]'));
    });

    test('Float32List sync return → func read() -> [Float] in protocol', () {
      final out = SwiftGenerator.generate(_syncTypedDataReturnSpec('Float32List'));
      expect(out, contains('func read() -> [Float]'));
    });
  });
}
