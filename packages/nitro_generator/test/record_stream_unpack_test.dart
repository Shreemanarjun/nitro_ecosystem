// Tests covering the int-to-Pointer conversion in generated record-stream
// unpack closures.
//
// Root cause that prompted these tests:
//   `Dart_PostCObject_DL` with `Dart_CObject_kInt64` delivers the native
//   pointer to the Dart `ReceivePort` as a plain Dart `int`.  The generated
//   unpack closure MUST convert that int to `Pointer<Uint8>` via
//   `Pointer.fromAddress(message as int)` before passing it to
//   `XxxRecordExt.fromNative` or `malloc.free`.  Failing to do so produces
//   a runtime `type 'int' is not a subtype of type 'Pointer<NativeType>'`
//   crash on the very first stream event.
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

/// A `@HybridRecord` stream with a flat-primitive record item.
/// Models `Stream<Event>` where `Event` has a String field.
BridgeSpec _flatRecordStreamSpec() => BridgeSpec(
  dartClassName: 'Notifier',
  lib: 'notifier',
  namespace: 'notifier',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'notifier.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Event',
      fields: [
        BridgeRecordField(
          name: 'type',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'value',
          dartType: 'double',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'events',
      registerSymbol: 'notifier_register_events_stream',
      releaseSymbol: 'notifier_release_events_stream',
      itemType: BridgeType(name: 'Event', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// A `@HybridRecord` stream whose item is a `List<double>`.
/// This is the exact `PackageBoxes` scenario: `{ final List<double> boxes; }`.
BridgeSpec _primitiveDoubleListStreamSpec() => BridgeSpec(
  dartClassName: 'ArModule',
  lib: 'ar_module',
  namespace: 'ar_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'ar_module.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'PackageBoxes',
      fields: [
        BridgeRecordField(
          name: 'boxes',
          dartType: 'List<double>',
          kind: RecordFieldKind.listPrimitive,
          itemTypeName: 'double',
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'detectedPackages',
      registerSymbol: 'ar_module_register_detected_packages_stream',
      releaseSymbol: 'ar_module_release_detected_packages_stream',
      itemType: BridgeType(name: 'PackageBoxes', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// A `@HybridRecord` stream whose item is a `List<int>`.
BridgeSpec _primitiveIntListStreamSpec() => BridgeSpec(
  dartClassName: 'Counter',
  lib: 'counter',
  namespace: 'counter',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'counter.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Snapshot',
      fields: [
        BridgeRecordField(
          name: 'values',
          dartType: 'List<int>',
          kind: RecordFieldKind.listPrimitive,
          itemTypeName: 'int',
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'snapshots',
      registerSymbol: 'counter_register_snapshots_stream',
      releaseSymbol: 'counter_release_snapshots_stream',
      itemType: BridgeType(name: 'Snapshot', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// A `@HybridRecord` stream whose item contains nested record objects.
BridgeSpec _nestedRecordStreamSpec() => BridgeSpec(
  dartClassName: 'Tracker',
  lib: 'tracker',
  namespace: 'tracker',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'tracker.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Point',
      fields: [
        BridgeRecordField(
          name: 'x',
          dartType: 'double',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'y',
          dartType: 'double',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
    BridgeRecordType(
      name: 'Track',
      fields: [
        BridgeRecordField(
          name: 'points',
          dartType: 'List<Point>',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Point',
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'tracks',
      registerSymbol: 'tracker_register_tracks_stream',
      releaseSymbol: 'tracker_release_tracks_stream',
      itemType: BridgeType(name: 'Track', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// Spec with two independent record streams to verify both get the fix.
BridgeSpec _twoRecordStreamsSpec() => BridgeSpec(
  dartClassName: 'Hub',
  lib: 'hub',
  namespace: 'hub',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'hub.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Alpha',
      fields: [
        BridgeRecordField(
          name: 'v',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
    BridgeRecordType(
      name: 'Beta',
      fields: [
        BridgeRecordField(
          name: 'label',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'alphas',
      registerSymbol: 'hub_register_alphas_stream',
      releaseSymbol: 'hub_release_alphas_stream',
      itemType: BridgeType(name: 'Alpha', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'betas',
      registerSymbol: 'hub_register_betas_stream',
      releaseSymbol: 'hub_release_betas_stream',
      itemType: BridgeType(name: 'Beta', isRecord: true),
      backpressure: Backpressure.bufferDrop,
    ),
  ],
);

/// Spec mixing a record stream and a struct stream.
/// The record stream must use `fromAddress` + `fromNative`;
/// the struct stream must use the zero-copy NativeProxy path.
BridgeSpec _mixedRecordStructStreamSpec() => BridgeSpec(
  dartClassName: 'Mixed',
  lib: 'mixed',
  namespace: 'mixed',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mixed.native.dart',
  structs: [
    BridgeStruct(
      name: 'Frame',
      packed: false,
      fields: [
        BridgeField(
          name: 'width',
          type: BridgeType(name: 'int'),
        ),
        BridgeField(
          name: 'height',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Config',
      fields: [
        BridgeRecordField(
          name: 'key',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'frames',
      registerSymbol: 'mixed_register_frames_stream',
      releaseSymbol: 'mixed_release_frames_stream',
      itemType: BridgeType(name: 'Frame'),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'configs',
      registerSymbol: 'mixed_register_configs_stream',
      releaseSymbol: 'mixed_release_configs_stream',
      itemType: BridgeType(name: 'Config', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('Record stream unpack — int-to-Pointer conversion', () {
    // ── core correctness ─────────────────────────────────────────────────────

    test(
      'flat record stream: unpack converts message to Pointer<Uint8> via fromAddress',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(
          out,
          contains('Pointer<Uint8>.fromAddress(message as int)'),
          reason: 'ReceivePort delivers kInt64 as Dart int; must use fromAddress',
        );
      },
    );

    test(
      'flat record stream: unpack calls fromNative on the converted pointer',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, contains('EventRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'flat record stream: unpack has null guard before fromAddress',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, contains('message == null'));
      },
    );

    test(
      'non-nullable record stream: null guard throws StateError, not return null',
      () {
        // Stream<Event> is non-nullable — returning null would cause a type
        // error ('Null' is not a subtype of 'Event'). Generator must throw.
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, contains('throw StateError('));
        expect(
          out,
          isNot(contains('if (message == null) return null')),
          reason: 'non-nullable stream must not return null on null message',
        );
      },
    );

    test(
      'flat record stream: malloc.free is called on rawPtr in finally block',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, contains('malloc.free(rawPtr)'));
        // Verify try/finally structure — finally must come after try
        final tryIdx = out.indexOf('try {');
        final finallyIdx = out.indexOf('} finally {');
        final freeIdx = out.indexOf('malloc.free(rawPtr)');
        expect(tryIdx, lessThan(finallyIdx));
        expect(finallyIdx, lessThan(freeIdx));
      },
    );

    test(
      'flat record stream: unpack does NOT pass raw message directly to fromNative',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        // The old broken pattern passed `rawPtr` (which was the ReceivePort
        // message — a Dart int) directly to fromNative without fromAddress.
        expect(out, isNot(contains('EventRecordExt.fromNative(message)')));
        expect(out, isNot(contains('fromNative(rawPtr as')));
      },
    );

    test(
      'flat record stream: register/release lookup symbols are correct',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, contains("'notifier_register_events_stream'"));
        expect(out, contains("'notifier_release_events_stream'"));
      },
    );

    // ── PackageBoxes scenario: List<double> primitive-list record ────────────

    test(
      'List<double> record stream (PackageBoxes): unpack uses fromAddress',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(
          out,
          contains('Pointer<Uint8>.fromAddress(message as int)'),
          reason: 'PackageBoxes stream must convert int port message to pointer',
        );
      },
    );

    test(
      'List<double> record stream: unpack calls PackageBoxesRecordExt.fromNative',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('PackageBoxesRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'List<double> record stream: unpack frees rawPtr in finally',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('malloc.free(rawPtr)'));
      },
    );

    test(
      'List<double> record stream: register/release symbols are correct',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(
          out,
          contains("'ar_module_register_detected_packages_stream'"),
        );
        expect(
          out,
          contains("'ar_module_release_detected_packages_stream'"),
        );
      },
    );

    test(
      'List<double> record stream: openStream is typed to record class, not List',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('NitroRuntime.openStream<PackageBoxes>'));
        expect(out, isNot(contains('openStream<List<double>>')));
      },
    );

    test(
      'List<double> record stream: stream getter returns Stream<PackageBoxes>',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('Stream<PackageBoxes> get detectedPackages'));
      },
    );

    // ── List<int> primitive-list record ──────────────────────────────────────

    test(
      'List<int> record stream: unpack uses fromAddress',
      () {
        final out = DartFfiGenerator.generate(_primitiveIntListStreamSpec());
        expect(out, contains('Pointer<Uint8>.fromAddress(message as int)'));
      },
    );

    test(
      'List<int> record stream: unpack calls SnapshotRecordExt.fromNative',
      () {
        final out = DartFfiGenerator.generate(_primitiveIntListStreamSpec());
        expect(out, contains('SnapshotRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'List<int> record stream: malloc.free present for native memory cleanup',
      () {
        final out = DartFfiGenerator.generate(_primitiveIntListStreamSpec());
        expect(out, contains('malloc.free(rawPtr)'));
      },
    );

    // ── nested record-object list stream ─────────────────────────────────────

    test(
      'List<record> record stream: unpack uses fromAddress',
      () {
        final out = DartFfiGenerator.generate(_nestedRecordStreamSpec());
        expect(out, contains('Pointer<Uint8>.fromAddress(message as int)'));
      },
    );

    test(
      'List<record> record stream: unpack calls TrackRecordExt.fromNative',
      () {
        final out = DartFfiGenerator.generate(_nestedRecordStreamSpec());
        expect(out, contains('TrackRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'List<record> record stream: malloc.free present',
      () {
        final out = DartFfiGenerator.generate(_nestedRecordStreamSpec());
        expect(out, contains('malloc.free(rawPtr)'));
      },
    );

    // ── two record streams in same spec ──────────────────────────────────────

    test(
      'two record streams: both unpack closures use fromAddress',
      () {
        final out = DartFfiGenerator.generate(_twoRecordStreamsSpec());
        // Both streams must emit fromAddress — use allMatches to count occurrences
        final matches = 'Pointer<Uint8>.fromAddress(message as int)'.allMatches(out).length;
        expect(
          matches,
          greaterThanOrEqualTo(2),
          reason: 'Each record stream needs its own fromAddress conversion',
        );
      },
    );

    test(
      'two record streams: AlphaRecordExt.fromNative is present',
      () {
        final out = DartFfiGenerator.generate(_twoRecordStreamsSpec());
        expect(out, contains('AlphaRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'two record streams: BetaRecordExt.fromNative is present',
      () {
        final out = DartFfiGenerator.generate(_twoRecordStreamsSpec());
        expect(out, contains('BetaRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'two record streams: both register/release symbols are emitted',
      () {
        final out = DartFfiGenerator.generate(_twoRecordStreamsSpec());
        expect(out, contains("'hub_register_alphas_stream'"));
        expect(out, contains("'hub_release_alphas_stream'"));
        expect(out, contains("'hub_register_betas_stream'"));
        expect(out, contains("'hub_release_betas_stream'"));
      },
    );

    test(
      'two record streams: second stream backpressure (bufferDrop) is emitted',
      () {
        final out = DartFfiGenerator.generate(_twoRecordStreamsSpec());
        expect(out, contains('Backpressure.bufferDrop'));
      },
    );

    // ── mixed record + struct streams ─────────────────────────────────────────

    test(
      'mixed spec: record stream uses fromAddress + fromNative',
      () {
        final out = DartFfiGenerator.generate(_mixedRecordStructStreamSpec());
        expect(out, contains('Pointer<Uint8>.fromAddress(message as int)'));
        expect(out, contains('ConfigRecordExt.fromNative(rawPtr)'));
      },
    );

    test(
      'mixed spec: struct stream uses zero-copy NativeProxy (no fromAddress)',
      () {
        final out = DartFfiGenerator.generate(_mixedRecordStructStreamSpec());
        // Struct stream must use FrameProxy, not fromAddress
        expect(out, contains('FrameProxy(Pointer<FrameFfi>.fromAddress'));
        expect(out, contains('NitroRuntime.openStream<FrameProxy>'));
      },
    );

    test(
      'mixed spec: struct stream does NOT use malloc.free (zero-copy)',
      () {
        final out = DartFfiGenerator.generate(_mixedRecordStructStreamSpec());
        // malloc.free is for the record stream only; struct proxy uses NativeFinalizer
        // We check that malloc.free is only for rawPtr, not for a struct ptr
        expect(out, isNot(contains('malloc.free(framePtr)')));
        expect(out, isNot(contains('malloc.free(ptr)')));
      },
    );

    test(
      'mixed spec: no cross-contamination — struct stream has no fromNative call',
      () {
        final out = DartFfiGenerator.generate(_mixedRecordStructStreamSpec());
        // FrameRecordExt should not appear since Frame is a @HybridStruct
        expect(out, isNot(contains('FrameRecordExt')));
      },
    );

    // ── regression guards ────────────────────────────────────────────────────

    test(
      'record stream: no old direct-message-to-fromNative pattern',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        // Old broken pattern: unpack: (rawPtr) { return Xxx.fromNative(rawPtr); }
        // where rawPtr was actually the raw ReceivePort message (int)
        expect(out, isNot(contains('fromNative(message)')));
      },
    );

    test(
      'record stream: no JSON decode path used for binary records',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, isNot(contains('jsonDecode')));
        expect(out, isNot(contains('toDartStringWithFree')));
      },
    );

    test(
      'record stream: openStream unpack is NOT typed as returning void',
      () {
        final out = DartFfiGenerator.generate(_flatRecordStreamSpec());
        expect(out, isNot(contains('unpack: (message) => null')));
      },
    );

    test(
      'PackageBoxes stream: no Pointer<NativeType> coercion from raw int',
      () {
        final out = DartFfiGenerator.generate(_primitiveDoubleListStreamSpec());
        // The old crash: `malloc.free(rawPtr)` where rawPtr was an int
        // Verify the pointer variable is obtained via fromAddress before free
        final fromAddrIdx = out.indexOf('fromAddress(message as int)');
        final freeIdx = out.indexOf('malloc.free(rawPtr)');
        expect(fromAddrIdx, isNot(-1), reason: 'fromAddress must be present');
        expect(freeIdx, isNot(-1), reason: 'malloc.free must be present');
        expect(
          fromAddrIdx,
          lessThan(freeIdx),
          reason: 'fromAddress must precede malloc.free',
        );
      },
    );

    test(
      'primitive stream (double) still uses direct cast, not fromAddress',
      () {
        // Non-record primitive streams pass the value directly; they must NOT
        // be altered by the record stream fix.
        final out = DartFfiGenerator.generate(richSpec());
        expect(out, contains('(message) => message as double'));
        // Primitive streams must NOT introduce fromAddress
        expect(
          out,
          isNot(contains('Pointer<Uint8>.fromAddress(message as double)')),
        );
      },
    );

    test(
      'struct stream (zero-copy) still uses fromAddress for Pointer<XxxFfi>, not Pointer<Uint8>',
      () {
        final out = DartFfiGenerator.generate(structStreamSpec());
        // Struct streams use Pointer<CameraFrameFfi>.fromAddress — different type
        expect(
          out,
          contains('Pointer<CameraFrameFfi>.fromAddress('),
        );
        // Must NOT use Pointer<Uint8>.fromAddress for struct streams
        expect(
          out,
          isNot(contains('Pointer<Uint8>.fromAddress')),
        );
      },
    );
  });

  // ── C++ bridge generator — JNI record-stream emission ──────────────────────
  group('C++ bridge — record stream JNI emit', () {
    test(
      'JNI bridge emits g_cls_PackageBoxes global for record stream type',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('g_cls_PackageBoxes'));
      },
    );

    test(
      'JNI bridge emits g_mid_PackageBoxes_encode global for record stream type',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('g_mid_PackageBoxes_encode'));
      },
    );

    test(
      'JNI_OnLoad caches PackageBoxes class via FindClass',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('FindClass'));
        expect(out, contains('g_cls_PackageBoxes'));
        expect(out, contains('NewGlobalRef'));
      },
    );

    test(
      'JNI_OnLoad caches PackageBoxes encode() method ID',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('g_mid_PackageBoxes_encode = env->GetMethodID'));
        expect(out, contains('"encode"'));
        expect(out, contains('"()[B"'));
      },
    );

    test(
      'JNI emit function calls encode() to get jbyteArray',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('jbyteArray encoded'));
        expect(out, contains('g_mid_PackageBoxes_encode'));
        expect(out, contains('CallObjectMethod(item, g_mid_PackageBoxes_encode)'));
      },
    );

    test(
      'JNI emit function copies bytes to malloc\'d buffer',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('malloc'));
        expect(out, contains('GetByteArrayRegion'));
      },
    );

    test(
      'JNI emit function sends native pointer as kInt64, not kNull',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        final emitSection = out.contains('emit_detectedPackages');
        expect(emitSection, isTrue);
        expect(out, contains('Dart_CObject_kInt64'));
        // Must NOT emit kNull for record stream items
        expect(
          out,
          isNot(contains('Dart_CObject_kNull')),
          reason: 'record stream items must be sent as kInt64, never kNull',
        );
      },
    );

    test(
      'JNI emit function deletes local ref to encoded array',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        expect(out, contains('DeleteLocalRef(encoded)'));
      },
    );

    test(
      'iOS Swift emit function sends record pointer as kInt64, not kNull',
      () {
        final spec = _primitiveDoubleListStreamSpec();
        // iOS-only generation to isolate the Swift bridge section
        final out = CppBridgeGenerator.generate(spec);
        // The _emit_detectedPackages_to_dart function for Swift must use kInt64
        final emitFnIdx = out.indexOf('_emit_detectedPackages_to_dart');
        expect(emitFnIdx, isNot(-1));
        // Whole file must not emit kNull (only one stream in this spec)
        expect(out, isNot(contains('Dart_CObject_kNull')));
      },
    );

    test(
      'iOS Swift emit function parameter type for record is void*',
      () {
        final out = CppBridgeGenerator.generate(_primitiveDoubleListStreamSpec());
        // The Swift emit helper must accept void* for encoded record bytes
        expect(out, contains('void _emit_detectedPackages_to_dart(int64_t dartPort, void* item)'));
      },
    );

    test(
      'C++ (non-JNI) emit helper sends record pointer as kInt64',
      () {
        // For pure C++ targets (not JNI), the Hybrid class emit_ function
        // must also send the serialized void* as kInt64.
        final spec = _primitiveDoubleListStreamSpec();
        final out = CppBridgeGenerator.generate(spec);
        // The Hybrid::emit_ function sends the item pointer
        expect(out, contains('Dart_CObject_kInt64'));
        expect(out, isNot(contains('Dart_CObject_kNull')));
      },
    );

    test(
      'duplicate record type across two streams only emits one set of globals',
      () {
        // Two streams with the same record type must not produce two copies
        // of g_cls_PackageBoxes.
        final spec = BridgeSpec(
          dartClassName: 'Dual',
          lib: 'dual',
          namespace: 'dual',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'dual.native.dart',
          recordTypes: [
            BridgeRecordType(
              name: 'PackageBoxes',
              fields: [
                BridgeRecordField(name: 'boxes', dartType: 'List<double>', kind: RecordFieldKind.listPrimitive, itemTypeName: 'double'),
              ],
            ),
          ],
          streams: [
            BridgeStream(
              dartName: 'streamA',
              registerSymbol: 'dual_register_streamA_stream',
              releaseSymbol: 'dual_release_streamA_stream',
              itemType: BridgeType(name: 'PackageBoxes', isRecord: true),
              backpressure: Backpressure.dropLatest,
            ),
            BridgeStream(
              dartName: 'streamB',
              registerSymbol: 'dual_register_streamB_stream',
              releaseSymbol: 'dual_release_streamB_stream',
              itemType: BridgeType(name: 'PackageBoxes', isRecord: true),
              backpressure: Backpressure.dropLatest,
            ),
          ],
        );
        final out = CppBridgeGenerator.generate(spec);
        // Count the static declaration — must appear exactly once (dedup).
        // Use the full declaration pattern to avoid matching `== nullptr` guards.
        final count = RegExp(r'static jclass g_cls_PackageBoxes = nullptr').allMatches(out).length;
        expect(count, equals(1), reason: 'g_cls_PackageBoxes must be declared exactly once');
      },
    );
  });
}
