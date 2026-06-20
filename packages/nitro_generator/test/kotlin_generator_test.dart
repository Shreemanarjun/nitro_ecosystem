import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('KotlinGenerator', () {
    BridgeSpec syncOnlySpec() => BridgeSpec(
      dartClassName: 'SyncOnly',
      lib: 'sync_only',
      namespace: 'sync_only',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'sync_only.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'add',
          cSymbol: 'sync_only_add',
          isAsync: false,
          returnType: BridgeType(name: 'int'),
          params: [
            BridgeParam(
              name: 'a',
              type: BridgeType(name: 'int'),
            ),
            BridgeParam(
              name: 'b',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
    );

    BridgeSpec streamOnlySpec() => BridgeSpec(
      dartClassName: 'StreamOnly',
      lib: 'stream_only',
      namespace: 'stream_only',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'stream_only.native.dart',
      streams: [
        BridgeStream(
          dartName: 'ticks',
          registerSymbol: 'stream_only_register_ticks_stream',
          releaseSymbol: 'stream_only_release_ticks_stream',
          itemType: BridgeType(name: 'int'),
          backpressure: Backpressure.dropLatest,
        ),
      ],
    );

    test('emits correct package', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('package nitro.my_camera_module'));
    });

    test('emits interface with correct name', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('interface HybridMyCameraSpec'));
    });

    test('emits JniBridge object', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('object MyCameraJniBridge'));
    });

    test('sync double function in interface', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('fun add(a: Double, b: Double): Double'));
    });

    test('enum class emitted with nativeValue', () {
      final out = KotlinGenerator.generate(enumSpec());
      expect(out, contains('enum class DeviceStatus'));
      expect(out, contains('nativeValue'));
    });

    test('enum function in interface uses enum type (not Long)', () {
      final out = KotlinGenerator.generate(enumSpec());
      expect(out, contains('fun getStatus(): DeviceStatus'));
    });

    test('JniBridge _call for enum returns Long', () {
      final out = KotlinGenerator.generate(enumSpec());
      expect(out, contains('fun getStatus_call(): Long'));
      expect(out, contains('.nativeValue'));
    });

    test('stream emits Flow<CameraFrame>', () {
      final out = KotlinGenerator.generate(structStreamSpec());
      expect(out, contains('val frames: Flow<CameraFrame>'));
    });

    test('pure sync bridge omits coroutine imports and async executor', () {
      final out = KotlinGenerator.generate(syncOnlySpec());
      expect(out, isNot(contains('import kotlinx.coroutines')));
      expect(out, isNot(contains('_asyncExecutor')));
      expect(out, isNot(contains('runBlocking')));
    });

    test('async bridge imports runBlocking but not stream-only coroutine APIs', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('import kotlinx.coroutines.runBlocking'));
      expect(out, contains('_asyncExecutor'));
      expect(out, isNot(contains('import kotlinx.coroutines.flow.Flow')));
      expect(out, isNot(contains('import kotlinx.coroutines.launch')));
      expect(out, isNot(contains('import kotlinx.coroutines.CoroutineScope')));
      expect(out, isNot(contains('import kotlinx.coroutines.Dispatchers')));
    });

    test('stream-only bridge imports Flow and launch APIs but not runBlocking or async executor', () {
      final out = KotlinGenerator.generate(streamOnlySpec());
      expect(out, contains('import kotlinx.coroutines.flow.Flow'));
      expect(out, contains('import kotlinx.coroutines.launch'));
      expect(out, contains('import kotlinx.coroutines.CoroutineScope'));
      expect(out, contains('import kotlinx.coroutines.Dispatchers'));
      expect(out, isNot(contains('import kotlinx.coroutines.runBlocking')));
      expect(out, isNot(contains('_asyncExecutor')));
    });

    test('stream register_call emitted', () {
      final out = KotlinGenerator.generate(structStreamSpec());
      expect(
        out,
        contains('fun my_camera_register_frames_stream_call(dartPort: Long)'),
      );
    });

    test('property val for read-only', () {
      final out = KotlinGenerator.generate(enumSpec());
      expect(out, contains('val batteryLevel: Double'));
    });

    test('property var for read-write', () {
      final out = KotlinGenerator.generate(enumSpec());
      expect(out, contains('var config: String'));
    });

    test('zero-copy TypedData params use direct ByteBuffer in interface and JNI bridge', () {
      final out = KotlinGenerator.generate(
        BridgeSpec(
          dartClassName: 'Dsp',
          lib: 'dsp',
          namespace: 'dsp',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'dsp.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'process',
              cSymbol: 'dsp_process',
              isAsync: false,
              returnType: BridgeType(name: 'void'),
              params: [
                BridgeParam(
                  name: 'samples',
                  type: BridgeType(name: 'Float32List'),
                  zeroCopy: true,
                ),
              ],
            ),
          ],
        ),
      );

      expect(out, contains('fun process(samples: java.nio.ByteBuffer)'));
      expect(out, contains('fun process_call(samples: java.nio.ByteBuffer)'));
      expect(out, isNot(contains('samples: FloatArray')));
    });
  });

  group('@HybridRecord Kotlin bridge', () {
    test('emits @Keep data class for each @HybridRecord type', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('data class CameraDevice('));
    });

    test('data class is annotated with @androidx.annotation.Keep', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('@androidx.annotation.Keep\ndata class CameraDevice('));
    });

    test('String field maps to Kotlin String', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('val id: String'));
      expect(out, contains('val name: String'));
    });

    test('bool field maps to Kotlin Boolean', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('val isFrontFacing: Boolean'));
    });

    test('int field maps to Kotlin Long', () {
      final out = KotlinGenerator.generate(recordListSpec());
      expect(out, contains('val width: Long'));
      expect(out, contains('val height: Long'));
    });

    test('List<@HybridRecord> field maps to Kotlin List<RecordType>', () {
      final out = KotlinGenerator.generate(recordListSpec());
      expect(out, contains('val resolutions: List<Resolution>'));
    });

    test('data class has a companion object with decode()', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('companion object {'));
      expect(out, contains('fun decode(bytes: ByteArray): CameraDevice'));
    });

    test('decode skips 4-byte length prefix', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('buf.position(4)'));
    });

    test('decode reads String fields with ByteBuffer', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('Charsets.UTF_8'));
    });

    test('decode reads bool field as byte comparison', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('buf.get().toInt() != 0'));
    });

    test('decode returns the constructed data class', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('return CameraDevice('));
    });

    test('data class has an encode() method returning ByteArray', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('fun encode(): ByteArray'));
    });

    test('encode writes strings via writeString local helper', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('writeString(id)'));
      expect(out, contains('writeString(name)'));
    });

    test('encode writes bool via writeBool local helper', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('writeBool(isFrontFacing)'));
    });

    test('encode prepends 4-byte little-endian length prefix', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('lenBuf.putInt(payload.size)'));
      expect(out, contains('return lenBuf.array() + payload'));
    });

    test('encode uses sequential list format for List<@HybridRecord>', () {
      final out = KotlinGenerator.generate(recordListSpec());
      // Sequential list format: writes count then iterates items.
      expect(out, contains('writeInt32(resolutions.size)'));
      expect(out, contains('resolutions.forEach { e -> e.writeFieldsTo(out, buf) }'));
    });

    test('all record types are emitted (Resolution AND CameraDevice)', () {
      final out = KotlinGenerator.generate(recordListSpec());
      expect(out, contains('data class Resolution('));
      expect(out, contains('data class CameraDevice('));
    });

    test('Resolution appears before CameraDevice in output (spec ordering)', () {
      final out = KotlinGenerator.generate(recordListSpec());
      final resPos = out.indexOf('data class Resolution(');
      final devPos = out.indexOf('data class CameraDevice(');
      expect(resPos, lessThan(devPos));
    });

    test('record header comment is emitted', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('@HybridRecord Kotlin data classes'));
    });

    test('record type name resolves in interface', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('fun setDevice(device: CameraDevice)'));
    });

    test('record return type in interface is real class name', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('suspend fun getDevice(): CameraDevice'));
    });

    test('JniBridge _call for record param uses real class name', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('fun setDevice_call(device: CameraDevice)'));
    });

    test('JniBridge _call for record return uses ByteArray', () {
      final out = KotlinGenerator.generate(singleRecordSpec());
      expect(out, contains('fun getDevice_call(): ByteArray'));
    });

    test('RecordGenerator.generateKotlin returns empty when no records', () {
      expect(RecordGenerator.generateKotlin(simpleSpec()), isEmpty);
    });

    test('simple spec produces valid Kotlin bridge', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('interface HybridMyCameraSpec'));
      expect(out, contains('object MyCameraJniBridge'));
    });
  });

  group('KotlinGenerator (edge cases)', () {
    test('async function emits suspend fun in interface', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('suspend fun fetchReading(): Reading'));
    });

    test('async function JniBridge uses runBlocking', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('runBlocking'));
    });

    test('bool type maps to Boolean', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('fun isReady(strict: Boolean): Boolean'));
    });

    test('int type maps to Long', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('fun count(): Long'));
    });

    test('struct data class emitted', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('data class Reading('));
    });

    test('struct data class emits @Keep', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('@androidx.annotation.Keep\ndata class Reading'));
    });

    test('property setter with bool type var in interface', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('var enabled: Boolean'));
    });

    test('property setter with enum uses fromNative in JniBridge', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(out, contains('SensorMode.fromNative(value)'));
    });

    test('stream external emit fun emitted', () {
      final out = KotlinGenerator.generate(richSpec());
      expect(
        out,
        contains('external fun emit_ticks(dartPort: Long, item: Double)'),
      );
    });
  });
}
