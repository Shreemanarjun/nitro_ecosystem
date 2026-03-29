import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('DartFfiGenerator', () {
    test('emits part directive', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(out, contains("part of 'my_camera.native.dart';"));
    });

    test('emits impl class name', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(out, contains('class _MyCameraImpl extends MyCamera'));
    });

    test('emits loadLib call with correct lib name', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(out, contains("NitroRuntime.loadLib('my_camera')"));
    });

    test('sync double function uses lookupFunction', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(
        out,
        contains(
          "lookupFunction<Double Function(Double, Double), double Function(double, double)>('my_camera_add')",
        ),
      );
    });

    test('async String function returns NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(out, contains('NitroRuntime.callAsync'));
    });

    test('enum return type uses Int64 FFI type', () {
      final out = DartFfiGenerator.generate(enumSpec());
      expect(out, contains('Int64 Function()'));
      expect(
        out,
        contains(
          "lookupFunction<Int64 Function(), int Function()>('complex_module_get_status')",
        ),
      );
    });

    test('enum return calls toDeviceStatus()', () {
      final out = DartFfiGenerator.generate(enumSpec());
      expect(out, contains('.toDeviceStatus()'));
    });

    test('stream register/release pointers emitted', () {
      final out = DartFfiGenerator.generate(structStreamSpec());
      expect(
        out,
        contains(
          "lookupFunction<Void Function(Int64), void Function(int)>('my_camera_register_frames_stream')",
        ),
      );
      expect(
        out,
        contains(
          "lookupFunction<Void Function(Int64), void Function(int)>('my_camera_release_frames_stream')",
        ),
      );
    });

    test(
      'struct stream uses NitroRuntime.openStream with fromAddress unpack',
      () {
        final out = DartFfiGenerator.generate(structStreamSpec());
        expect(out, contains('NitroRuntime.openStream<CameraFrame>'));
        expect(
          out,
          contains('Pointer<CameraFrameFfi>.fromAddress(rawPtr)'),
        );
        expect(out, contains('.ref.toDart()'));
      },
    );

    test(
      'struct stream unpack frees the malloc\'d pointer (no leak)',
      () {
        final out = DartFfiGenerator.generate(structStreamSpec());
        // The unpack closure must call malloc.free after copying to Dart.
        expect(
          out,
          contains('malloc.free(ptr)'),
          reason:
              'emit_dataStream mallocs a struct pointer; unpack must free it '
              'after toDart() to avoid a per-event memory leak.',
        );
      },
    );

    test(
      'struct stream unpack frees AFTER toDart (order check)',
      () {
        final out = DartFfiGenerator.generate(structStreamSpec());
        final toDartPos = out.indexOf('.ref.toDart()');
        final freePos = out.indexOf('malloc.free(ptr)');
        expect(toDartPos, greaterThan(0), reason: 'toDart() must appear');
        expect(freePos, greaterThan(0), reason: 'malloc.free must appear');
        expect(
          freePos,
          greaterThan(toDartPos),
          reason:
              'malloc.free must come AFTER toDart() so we do not '
              'read freed memory',
        );
      },
    );

    test(
      'cpp struct stream unpack also frees the malloc\'d pointer',
      () {
        final out = DartFfiGenerator.generate(cppStreamStructSpec());
        expect(out, contains('NitroRuntime.openStream'));
        expect(out, contains('malloc.free(ptr)'));
      },
    );
  });

  group('DartFfiGenerator (edge cases)', () {
    test('bool return converts via != 0', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('final res = _isReadyPtr(strict ? 1 : 0);'));
      expect(out, contains('NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);'));
      expect(out, contains('return res != 0;'));
    });

    test('bool param passes value ? 1 : 0', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('strict ? 1 : 0'));
    });

    test('int return is passed through directly', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('final res = _countPtr();'));
      expect(out, contains('NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);'));
      expect(out, contains('return res;'));
    });

    test('String return calls toDartStringWithFree', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('toDartStringWithFree()'));
    });

    test('String param uses toNativeUtf8 inside withArena', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('toNativeUtf8(allocator: arena)'));
      expect(out, contains('withArena'));
    });

    test('async struct return uses Pointer<ReadingFfi>.fromAddress', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('Pointer<ReadingFfi>.fromAddress'));
    });

    test('struct param uses toNative(arena).cast<Void>()', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('.toNative(arena).cast<Void>()'));
    });

    test('async enum return calls toState()', () {
      final out = DartFfiGenerator.generate(asyncEnumSpec());
      expect(out, contains('.toState()'));
    });

    test('property with setter emits set accessor', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('set enabled('));
    });

    test('property bool getter converts != 0', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(
        out,
        contains(
          '  bool get enabled {\n'
          '    checkDisposed();\n'
          '    final res = _getEnabledPtr();\n'
          '    NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);\n'
          '    return res != 0;\n'
          '  }',
        ),
      );
    });

    test('property enum getter calls toSensorMode()', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('.toSensorMode()'));
    });

    test('property bool setter converts value ? 1 : 0', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(
        out,
        contains(
          'set enabled(bool value) { checkDisposed(); _setEnabledPtr(value ? 1 : 0); NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr); }',
        ),
      );
    });

    test('property enum setter passes nativeValue', () {
      final out = DartFfiGenerator.generate(richSpec());
      // pointer name = _set{Cap(dartName)}Ptr; dartName='mode' → _setModePtr
      expect(out, contains('_setModePtr(value.nativeValue)'));
    });

    test('dispose() override is emitted in generated impl', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(
        out,
        contains(
          '@override\n  // ignore: unnecessary_overrides\n  void dispose() {',
        ),
      );
      expect(out, contains('super.dispose();'));
    });

    test('methods have checkDisposed() guard', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      // add(double, double) should guard
      expect(out, contains('checkDisposed();'));
    });

    test('stream getter has checkDisposed() guard', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('Stream<double> get ticks {\n    checkDisposed();'));
    });

    test('property getter has checkDisposed() in block body', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('{\n    checkDisposed();'));
    });

    test('primitive double stream uses direct rawPtr cast', () {
      final out = DartFfiGenerator.generate(richSpec());
      // double stream item: unpack is cast to double
      expect(out, contains('(rawPtr) => rawPtr as double'));
    });

    test('primitive int stream uses direct rawPtr cast', () {
      final out = DartFfiGenerator.generate(richSpec());
      expect(out, contains('(rawPtr) => rawPtr as int'));
    });
  });

  group('DartFfiGenerator (@HybridRecord)', () {
    test('async single record return uses Pointer<Uint8> FFI lookup type', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(
        out,
        contains(
          "lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>"
          "('camera_module_get_device')",
        ),
      );
    });

    test('record param uses Pointer<Uint8> in FFI lookup', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(
        out,
        contains(
          "lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>"
          "('camera_module_set_device')",
        ),
      );
    });

    test('async single record return decodes via fromNative', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(out, contains('CameraDeviceRecordExt.fromNative'));
      // binary path — must NOT use JSON decode
      expect(out, isNot(contains('jsonDecode')));
      expect(out, isNot(contains('toDartStringWithFree')));
    });

    test('async single record return does not produce Map<String, dynamic>', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(out, isNot(contains('as Map<String, dynamic>')));
    });

    test('async List<record> return uses RecordReader.decodeList + fromReader', () {
      final out = DartFfiGenerator.generate(recordListSpec());
      expect(out, contains('RecordReader.decodeList'));
      expect(out, contains('CameraDeviceRecordExt.fromReader'));
    });

    test('record param uses .toNative(arena)', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(out, contains('device.toNative(arena)'));
      // Must NOT use JSON path
      expect(out, isNot(contains('jsonEncode(device')));
    });

    test('record param forces withArena even when no other arena params', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      // setDevice has only a record param — must still enter withArena
      final lines = out.split('\n');
      final idx = lines.indexWhere((l) => l.contains('void setDevice('));
      final body = lines.skip(idx).take(12).join('\n');
      expect(body, contains('withArena'));
    });

    test('binary extensions are included in .g.dart output', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(out, contains('@HybridRecord binary extensions'));
      expect(out, contains('extension CameraDeviceRecordExt'));
    });

    test('record property getter decodes via fromNative', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
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
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'Config', isRecord: true),
            getSymbol: 'foo_get_config',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('ConfigRecordExt.fromNative'));
      expect(out, isNot(contains('toDartStringWithFree')));
    });

    test('record property setter encodes via .toNative(arena)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
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
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'Config', isRecord: true),
            setSymbol: 'foo_set_config',
            hasGetter: false,
            hasSetter: true,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('value.toNative(arena)'));
      expect(out, isNot(contains('jsonEncode(value')));
    });

    test('record stream item unpack decodes via fromNative', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Event',
            fields: [
              BridgeRecordField(
                name: 'type',
                dartType: 'String',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'foo_register_events_stream',
            releaseSymbol: 'foo_release_events_stream',
            itemType: BridgeType(name: 'Event', isRecord: true),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('EventRecordExt.fromNative'));
      expect(out, isNot(contains('toDartStringWithFree')));
      expect(out, isNot(contains('jsonDecode')));
    });

    test('List<record> stream item unpack uses RecordReader.decodeList', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Item',
            fields: [
              BridgeRecordField(
                name: 'id',
                dartType: 'int',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'batch',
            registerSymbol: 'foo_register_batch_stream',
            releaseSymbol: 'foo_release_batch_stream',
            itemType: BridgeType(
              name: 'List<Item>',
              isRecord: true,
              recordListItemType: 'Item',
            ),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodeList'));
      expect(out, contains('ItemRecordExt.fromReader'));
    });

    test('List<String> return decodes via RecordReader.decodePrimitiveList + readString', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getTags',
            cSymbol: 'foo_get_tags',
            isAsync: true,
            returnType: BridgeType(
              name: 'List<String>',
              isRecord: true,
              recordListItemType: 'String',
              recordListItemIsPrimitive: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readString'));
      expect(out, isNot(contains('StringRecordExt')));
    });

    test('List<int> return decodes via RecordReader.decodePrimitiveList + readInt', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getCounts',
            cSymbol: 'foo_get_counts',
            isAsync: true,
            returnType: BridgeType(
              name: 'List<int>',
              isRecord: true,
              recordListItemType: 'int',
              recordListItemIsPrimitive: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readInt'));
    });

    test('List<double> return uses RecordReader.decodePrimitiveList + readDouble', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getScores',
            cSymbol: 'foo_get_scores',
            isAsync: true,
            returnType: BridgeType(
              name: 'List<double>',
              isRecord: true,
              recordListItemType: 'double',
              recordListItemIsPrimitive: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readDouble'));
    });

    test('List<String> param uses RecordWriter.encodePrimitiveList (no jsonEncode)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'setTags',
            cSymbol: 'foo_set_tags',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'tags',
                type: BridgeType(
                  name: 'List<String>',
                  isRecord: true,
                  recordListItemType: 'String',
                  recordListItemIsPrimitive: true,
                ),
              ),
            ],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordWriter.encodePrimitiveList(tags'));
      expect(out, contains('writeString'));
      expect(out, isNot(contains('jsonEncode(tags)')));
    });

    test('List<String> property setter uses RecordWriter.encodePrimitiveList', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'tags',
            type: BridgeType(
              name: 'List<String>',
              isRecord: true,
              recordListItemType: 'String',
              recordListItemIsPrimitive: true,
            ),
            setSymbol: 'foo_set_tags',
            hasGetter: false,
            hasSetter: true,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordWriter.encodePrimitiveList(value'));
      expect(out, contains('writeString'));
      expect(out, isNot(contains('jsonEncode(value)')));
    });

    test('List<int> stream item decodes via RecordReader.decodePrimitiveList + readInt', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        streams: [
          BridgeStream(
            dartName: 'counts',
            registerSymbol: 'foo_register_counts_stream',
            releaseSymbol: 'foo_release_counts_stream',
            itemType: BridgeType(
              name: 'List<int>',
              isRecord: true,
              recordListItemType: 'int',
              recordListItemIsPrimitive: true,
            ),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readInt'));
      expect(out, isNot(contains('RecordExt')));
    });

    test('Map<String, dynamic> return decodes via jsonDecode as Map<String, dynamic>', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getMetadata',
            cSymbol: 'foo_get_metadata',
            isAsync: true,
            returnType: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonDecode'));
      expect(out, contains('as Map<String, dynamic>'));
      expect(out, contains('Pointer<Utf8>'));
      // Must NOT call RecordExt
      expect(out, isNot(contains('RecordExt')));
    });

    test('Map<String, dynamic> param encodes via jsonEncode(param) with toNativeUtf8', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'setMetadata',
            cSymbol: 'foo_set_metadata',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'meta',
                type: BridgeType(
                  name: 'Map<String, dynamic>',
                  isRecord: true,
                  isMap: true,
                ),
              ),
            ],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonEncode(meta)'));
      expect(out, contains('toNativeUtf8'));
      expect(out, isNot(contains('meta.toJson()')));
    });

    test('Map<String, dynamic> property setter uses jsonEncode(value) directly', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'metadata',
            type: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            setSymbol: 'foo_set_metadata',
            hasGetter: false,
            hasSetter: true,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonEncode(value)'));
      expect(out, contains('toNativeUtf8'));
      expect(out, isNot(contains('value.toJson()')));
    });

    test('Map<String, dynamic> stream item decodes as Map<String, dynamic>', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        streams: [
          BridgeStream(
            dartName: 'updates',
            registerSymbol: 'foo_register_updates_stream',
            releaseSymbol: 'foo_release_updates_stream',
            itemType: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonDecode'));
      expect(out, contains('as Map<String, dynamic>'));
      expect(out, isNot(contains('RecordExt')));
    });

    test('Map<String, dynamic> property getter decodes as Map<String, dynamic>', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'metadata',
            type: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            getSymbol: 'foo_get_metadata',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonDecode'));
      expect(out, contains('as Map<String, dynamic>'));
      expect(out, isNot(contains('RecordExt')));
    });

    test(
      '@HybridRecord and @HybridStruct coexist in same spec without collision',
      () {
        final spec = BridgeSpec(
          dartClassName: 'Hybrid',
          lib: 'hybrid',
          namespace: 'hybrid',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'hybrid.native.dart',
          structs: [
            BridgeStruct(
              name: 'Frame',
              packed: false,
              fields: [
                BridgeField(
                  name: 'width',
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
          functions: [
            BridgeFunction(
              dartName: 'getConfig',
              cSymbol: 'hybrid_get_config',
              isAsync: true,
              returnType: BridgeType(name: 'Config', isRecord: true),
              params: [],
            ),
            BridgeFunction(
              dartName: 'processFrame',
              cSymbol: 'hybrid_process_frame',
              isAsync: true,
              returnType: BridgeType(name: 'Frame'),
              params: [],
            ),
          ],
        );
        final out = DartFfiGenerator.generate(spec);
        // Both record and struct extensions present
        expect(out, contains('extension ConfigRecordExt'));
        expect(out, contains('final class FrameFfi'));
        // Record method uses binary decode
        expect(out, contains('ConfigRecordExt.fromNative'));
        // Struct method uses fromAddress
        expect(out, contains('Pointer<FrameFfi>.fromAddress'));
        // No errors from spec validator either
        expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
      },
    );
  });
 
  group('DartFfiGenerator (v4 fixes)', () {
    test('initFunc check return values and throws on error', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(out, contains('final initCode = initFunc(NativeApi.initializeApiDLData);'));
      expect(out, contains('if (initCode != 0) {'));
      expect(out, contains("throw StateError('my_camera: Dart API DL initialization failed with code \$initCode.');"));
    });
 
    test('Fast (leaf) methods have checkDisposed() guard', () {
      final spec = BridgeSpec(
        dartClassName: 'Calc',
        lib: 'calc',
        namespace: 'calc',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'calc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'addFast',
            cSymbol: 'calc_add_fast',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      // It should still have checkDisposed
      expect(out, contains('int addFast() {\n    checkDisposed();'));
    });
 
    test('Fast (leaf) methods skip NitroRuntime.checkError', () {
      final spec = BridgeSpec(
        dartClassName: 'Calc',
        lib: 'calc',
        namespace: 'calc',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'calc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'addFast',
            cSymbol: 'calc_add_fast',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, isNot(contains('NitroRuntime.checkError')));
    });
 
    test('non-arena record return uses try/finally for malloc.free', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getRecord',
            cSymbol: 'mod_get_record',
            isAsync: false,
            returnType: BridgeType(name: 'Config', isRecord: true),
            params: [],
          ),
        ],
        recordTypes: [
          BridgeRecordType(name: 'Config', fields: []),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('final Config decoded;'));
      expect(out, contains('try {'));
      expect(out, contains('decoded = ConfigRecordExt.fromNative(res as Pointer<Uint8>);'));
      expect(out, contains('} finally {'));
      expect(out, contains('malloc.free(res);'));
      expect(out, contains('return decoded;'));
    });
  });
}
