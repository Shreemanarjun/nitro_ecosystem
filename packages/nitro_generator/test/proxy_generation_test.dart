import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  // ── Proxy class generation ──────────────────────────────────────────────────
  group('StructGenerator.generateDartProxies', () {
    test('no output when spec has no structs', () {
      final out = StructGenerator.generateDartProxies(simpleSpec());
      expect(out, isEmpty);
    });

    test('generates a proxy class for each struct', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('final class CameraFrameProxy'));
    });

    test('proxy implements Finalizable', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('final class CameraFrameProxy implements Finalizable'));
    });

    test('proxy has nullable static NativeFinalizer field', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('static NativeFinalizer? _finalizer;'));
    });

    test('proxy does NOT use malloc.nativeFree directly as finalizer', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, isNot(contains('malloc.nativeFree')));
    });

    test('proxy has static _init(DynamicLibrary) method', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('static void _init(DynamicLibrary dylib)'));
    });

    test('_init looks up correct generated release symbol', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      // lib = 'my_camera' → libStem = 'my_camera', struct = 'CameraFrame'
      expect(out, contains("'my_camera_release_CameraFrame'"));
    });

    test('_init uses ??= (idempotent, safe to call multiple times)', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('_finalizer ??= NativeFinalizer('));
    });

    test('proxy constructor calls assert on uninitialized finalizer', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains("assert(_finalizer != null"));
    });

    test('proxy constructor calls _finalizer!.attach()', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('_finalizer!.attach(this, _native.cast(), detach: this)'));
    });

    test('proxy has int lazy getter for int field', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('int get width => _native.ref.width;'));
      expect(out, contains('int get height => _native.ref.height;'));
    });

    test('proxy has bool lazy getter using != 0', () {
      final out = StructGenerator.generateDartProxies(richSpec());
      expect(out, contains('bool get valid => _native.ref.valid != 0;'));
    });

    test('proxy has double lazy getter for double field', () {
      final out = StructGenerator.generateDartProxies(richSpec());
      expect(out, contains('double get value => _native.ref.value;'));
    });

    test('proxy has TypedData lazy getter using asTypedList with length field', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      // 'stride' is the length field for 'data' (Uint8List)
      expect(out, contains('_native.ref.data.asTypedList(_native.ref.stride)'));
    });

    test('proxy has toDartAndRelease() method', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('CameraFrame toDartAndRelease()'));
    });

    test('toDartAndRelease detaches finalizer before freeing', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      final detachPos = out.indexOf('_finalizer?.detach(this)');
      final freePos = out.indexOf('malloc.free(_native)');
      expect(detachPos, greaterThan(0), reason: 'detach must appear');
      expect(freePos, greaterThan(0), reason: 'free must appear');
      expect(freePos, greaterThan(detachPos),
          reason: 'must detach before freeing to avoid finalizer double-free');
    });

    test('toDartAndRelease calls toDart() then frees', () {
      final out = StructGenerator.generateDartProxies(structStreamSpec());
      expect(out, contains('_native.ref.toDart()'));
      expect(out, contains('malloc.free(_native)'));
    });

    test('multiple structs each get a proxy class', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'Alpha',
            packed: false,
            fields: [BridgeField(name: 'x', type: BridgeType(name: 'int'))],
          ),
          BridgeStruct(
            name: 'Beta',
            packed: false,
            fields: [BridgeField(name: 'y', type: BridgeType(name: 'double'))],
          ),
        ],
      );
      final out = StructGenerator.generateDartProxies(spec);
      expect(out, contains('final class AlphaProxy'));
      expect(out, contains('final class BetaProxy'));
      expect(out, contains("'mod_release_Alpha'"));
      expect(out, contains("'mod_release_Beta'"));
    });

    test('lib name with hyphens is converted to underscores in release symbol', () {
      final spec = BridgeSpec(
        dartClassName: 'Cam',
        lib: 'my-camera-lib',
        namespace: 'cam',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'cam.native.dart',
        structs: [
          BridgeStruct(
            name: 'Frame',
            packed: false,
            fields: [BridgeField(name: 'ts', type: BridgeType(name: 'int'))],
          ),
        ],
      );
      final out = StructGenerator.generateDartProxies(spec);
      expect(out, contains("'my_camera_lib_release_Frame'"));
    });

    test('packed struct proxy is still generated', () {
      final out = StructGenerator.generateDartProxies(cppStreamStructSpec());
      expect(out, contains('final class LidarPointProxy implements Finalizable'));
    });
  });

  // ── DartFfiGenerator: impl constructor initialises proxies ─────────────────
  group('DartFfiGenerator — proxy initialisation in impl constructor', () {
    test('impl constructor calls StructProxy._init(_dylib) for each struct', () {
      final out = DartFfiGenerator.generate(structStreamSpec());
      expect(out, contains('CameraFrameProxy._init(_dylib);'));
    });

    test('no proxy _init calls when spec has no structs', () {
      final out = DartFfiGenerator.generate(simpleSpec());
      expect(out, isNot(contains('Proxy._init(')));
    });

    test('proxy _init call appears inside the impl constructor body', () {
      final out = DartFfiGenerator.generate(structStreamSpec());
      // The constructor body ends with '}' before the first 'late final'
      final ctorStart = out.indexOf('_MyCameraImpl()');
      final firstLate = out.indexOf('  late final', ctorStart);
      final initCall = out.indexOf('CameraFrameProxy._init(_dylib)', ctorStart);
      expect(initCall, greaterThan(ctorStart));
      expect(initCall, lessThan(firstLate));
    });

    test('cpp spec structs also get proxy _init', () {
      final out = DartFfiGenerator.generate(cppStreamStructSpec());
      expect(out, contains('LidarPointProxy._init(_dylib);'));
    });

    test('stream returns Stream<StructProxy> type (proxy is the stream item)', () {
      final out = DartFfiGenerator.generate(structStreamSpec());
      expect(out, contains('Stream<CameraFrameProxy>'));
    });

    test('stream unpack uses proxy constructor, not toDart()+free', () {
      final out = DartFfiGenerator.generate(structStreamSpec());
      expect(
        out,
        contains('CameraFrameProxy(Pointer<CameraFrameFfi>.fromAddress(rawPtr))'),
      );
      expect(out, isNot(contains('malloc.free(ptr)')));
    });
  });

  // ── CppBridgeGenerator: release symbols ────────────────────────────────────
  group('CppBridgeGenerator — struct release symbols', () {
    test('generates release function for each struct (C++ direct path)', () {
      final out = CppBridgeGenerator.generate(cppStreamStructSpec());
      expect(out, contains('void lidar_release_LidarPoint(void* ptr)'));
    });

    test('release function calls free(ptr)', () {
      final out = CppBridgeGenerator.generate(cppStreamStructSpec());
      expect(out, contains('free(ptr)'));
    });

    test('release function guards against null pointer', () {
      final out = CppBridgeGenerator.generate(cppStreamStructSpec());
      expect(out, contains('if (!ptr) return;'));
    });

    test('release function is inside extern "C" block', () {
      final out = CppBridgeGenerator.generate(cppStreamStructSpec());
      final externCPos = out.indexOf('extern "C" {');
      final releasePos = out.indexOf('lidar_release_LidarPoint');
      final closingPos = out.indexOf('} // extern "C"');
      expect(releasePos, greaterThan(externCPos));
      expect(releasePos, lessThan(closingPos));
    });

    test('release function NOT generated when spec has no structs', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, isNot(contains('_release_')));
    });

    test('JNI+Swift path also generates release function', () {
      final out = CppBridgeGenerator.generate(structStreamSpec());
      // JNI+Swift path uses libStem = my_camera, struct = CameraFrame
      expect(out, contains('void my_camera_release_CameraFrame(void* ptr)'));
    });

    test('JNI+Swift release function has null guard and free', () {
      final out = CppBridgeGenerator.generate(structStreamSpec());
      // Check the release function body in JNI+Swift output
      final releaseIdx = out.indexOf('my_camera_release_CameraFrame');
      expect(releaseIdx, greaterThan(0));
      final end = (releaseIdx + 200).clamp(0, out.length);
      final releaseBlock = out.substring(releaseIdx, end);
      expect(releaseBlock, contains('if (!ptr) return;'));
      expect(releaseBlock, contains('free(ptr)'));
    });

    test('multiple structs each get a release function', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'PointA',
            packed: false,
            fields: [BridgeField(name: 'x', type: BridgeType(name: 'double'))],
          ),
          BridgeStruct(
            name: 'PointB',
            packed: false,
            fields: [BridgeField(name: 'y', type: BridgeType(name: 'double'))],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('void mod_release_PointA(void* ptr)'));
      expect(out, contains('void mod_release_PointB(void* ptr)'));
    });

    test('release symbol name matches _init lookup in proxy', () {
      // The C++ symbol and the Dart lookup string must be identical.
      final cppOut = CppBridgeGenerator.generate(cppStreamStructSpec());
      final dartOut = DartFfiGenerator.generate(cppStreamStructSpec());
      // The symbol 'lidar_release_LidarPoint' must appear in both.
      expect(cppOut, contains('lidar_release_LidarPoint'));
      expect(dartOut, contains("'lidar_release_LidarPoint'"));
    });
  });
}
