// Integration tests for the Nitro generator — multiple real-world specs.
//
// Each group exercises a different module spec you'd find in an example app.
// They act as end-to-end regression guards: run all generators and assert
// that the produced code is structurally correct and complete.
//
// Specs:
//   Spec A — MathMod:     primitives, optional primitives, enums, sync/async
//   Spec B — MediaMod:    TypedData (Uint8List), @HybridRecord, stream<struct>
//   Spec C — SettingsMod: @HybridRecord params/returns, Map-like NitroAnyMap
//   Spec D — SensorMod:   multiple streams, nullable types, callbacks
//   Spec E — EdgeMod:     edge cases — no params, max params, nested types,
//                         same-type overloads, String? nullable, empty returns
//
// §A  MathMod — primitive + optional-primitive + enum
// §B  MediaMod — TypedData, @HybridRecord, struct stream
// §C  SettingsMod — @HybridRecord params, NitroAnyMap param + return
// §D  SensorMod — multiple streams, nullable types, callbacks
// §E  EdgeMod — edge cases across all generators

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:test/test.dart';
import 'spec_from_source.dart';
import 'spec_tester.dart';

// ── Source helper ─────────────────────────────────────────────────────────────

SpecSource _src(String body) => SpecSource(body.trim());

// ══════════════════════════════════════════════════════════════════════════════
// §A  MathMod — primitives, optional primitives, @HybridEnum, sync + async
// ══════════════════════════════════════════════════════════════════════════════

final _mathSrc = _src('''
  @HybridEnum(startValue: 1)
  enum Rounding { floor, ceil, round }

  @NitroModule(
    ios: NativeImpl.swift,
    android: NativeImpl.kotlin,
    lib: 'math_mod',
    cSymbolPrefix: 'math',
  )
  abstract class MathMod {
    // sync primitives
    double add(double a, double b);
    int multiply(int a, int b);
    bool isEven(int n);

    // optional-primitive params and returns
    Future<void> compute({int? iterations, double? tolerance, bool? verbose});
    int? tryDivide(int numerator, int denominator);
    double? clamp(double value, {double? min, double? max});

    // enum param
    double round(double value, Rounding mode);

    // async
    Future<double> heavyCompute(double x);

    // properties
    double get pi;
    int get precision;
    set precision(int value);

    // stream
    Stream<double> ticker();
  }
''');

void main() {
  // ── §A: MathMod ─────────────────────────────────────────────────────────────

  group('§A MathMod — primitives + optional + enum', () {
    specTest(
      'all function names appear in every generator',
      _mathSrc,
      all: BridgeChecks(has: ['add', 'multiply', 'isEven', 'compute', 'clamp', 'round', 'heavyCompute']),
      skip: {Lang.cpp},
    );

    specTest(
      'Rounding enum appears in Dart and Kotlin',
      _mathSrc,
      dart: BridgeChecks(has: ['Rounding']),
      kotlin: BridgeChecks(has: ['Rounding']),
      skip: {Lang.cpp},
    );

    specTest(
      'optional int? param uses packInt in Dart',
      _mathSrc,
      dart: BridgeChecks(has: ['arena.packInt(iterations)']),
      skip: {Lang.cpp},
    );

    specTest(
      'optional double? param uses packDouble in Dart',
      _mathSrc,
      dart: BridgeChecks(has: ['arena.packDouble(tolerance)']),
      skip: {Lang.cpp},
    );

    specTest(
      'optional bool? param uses packBool in Dart',
      _mathSrc,
      dart: BridgeChecks(has: ['arena.packBool(verbose)']),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin decodes optional int? via NitroOptInt64',
      _mathSrc,
      kotlin: BridgeChecks(has: ['NitroOptInt64.decode(iterations)']),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin decodes optional double? via NitroOptFloat64',
      _mathSrc,
      kotlin: BridgeChecks(has: ['NitroOptFloat64.decode(tolerance)']),
      skip: {Lang.cpp},
    );

    specTest(
      'sync nullable return int? uses NitroOptInt64 struct by value',
      _mathSrc,
      dart: BridgeChecks(has: ['NitroOptInt64']),
      skip: {Lang.cpp},
    );

    specTest(
      'pi is a read-only property',
      _mathSrc,
      dart: BridgeChecks(has: ['double get pi']),
      kotlin: BridgeChecks(has: ['pi']),
      skip: {Lang.cpp},
    );

    specTest(
      'precision is a read-write property',
      _mathSrc,
      dart: BridgeChecks(has: ['int get precision', 'set precision']),
      kotlin: BridgeChecks(has: ['precision']),
      skip: {Lang.cpp},
    );

    specTest(
      'ticker stream emitted in Dart and Kotlin',
      _mathSrc,
      dart: BridgeChecks(has: ['Stream<double> get ticker']),
      kotlin: BridgeChecks(has: ['ticker']),
      skip: {Lang.cpp},
    );

    specTest(
      'no sentinel magic numbers leak into Dart output for non-nullable params',
      _mathSrc,
      dart: BridgeChecks(hasNot: [' ?? -9223372036854775808']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════════
  // §B  MediaMod — TypedData, @HybridRecord stats, struct stream
  // ══════════════════════════════════════════════════════════════════════════════

  final _mediaSrc = _src('''
    @HybridStruct(packed: true)
    class VideoFrame {
      int width;
      int height;
      int timestampMs;
    }

    @HybridRecord
    class EncodeStats {
      int frameCount;
      double avgBitrate;
      double peakBitrate;
      String codec;
    }

    @NitroModule(
      ios: NativeImpl.swift,
      android: NativeImpl.kotlin,
      lib: 'media_mod',
    )
    abstract class MediaMod {
      // TypedData params
      void uploadFrame(@zeroCopy Uint8List pixels, int width, int height);
      int processChunk(Uint8List data);

      // @HybridRecord return
      Future<EncodeStats> encode(String codec, {int? targetBitrate});

      // @HybridRecord param
      void applyStats(EncodeStats stats);

      // @HybridStruct param/return
      VideoFrame getLatestFrame();
      void queueFrame(VideoFrame frame);

      // stream of struct items
      Stream<VideoFrame> frames();
    }
  ''');

  group('§B MediaMod — TypedData + @HybridRecord + struct stream', () {
    specTest(
      'all method names present in all generators',
      _mediaSrc,
      all: BridgeChecks(has: ['uploadFrame', 'processChunk', 'encode', 'applyStats', 'getLatestFrame', 'queueFrame']),
      skip: {Lang.cpp},
    );

    specTest(
      'Dart uses Pointer<Uint8> + Int64 length for Uint8List params',
      _mediaSrc,
      dart: BridgeChecks(
        has: ['Pointer<Uint8>', 'pixels.length'],
        hasNot: ['List<int>'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin encode is suspend fun returning EncodeStats',
      _mediaSrc,
      kotlin: BridgeChecks(has: ['suspend fun encode(codec: String']),
      skip: {Lang.cpp},
    );

    specTest(
      'EncodeStats Kotlin data class has all four fields',
      _mediaSrc,
      kotlin: BridgeChecks(
        has: ['data class EncodeStats(', 'val frameCount', 'val avgBitrate', 'val peakBitrate', 'val codec'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'EncodeStats has decode() and encode() methods in Kotlin',
      _mediaSrc,
      kotlin: BridgeChecks(
        has: ['fun decode(bytes: ByteArray): EncodeStats', 'fun encode(): ByteArray'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'VideoFrame struct data class in Kotlin',
      _mediaSrc,
      kotlin: BridgeChecks(has: ['data class VideoFrame(val width: Long, val height: Long, val timestampMs: Long)']),
      skip: {Lang.cpp},
    );

    specTest(
      'Swift encode is async throws returning EncodeStats',
      _mediaSrc,
      swift: BridgeChecks(has: ['async throws -> EncodeStats']),
      skip: {Lang.cpp},
    );

    specTest(
      'frames stream emitted for VideoFrame struct item',
      _mediaSrc,
      dart: BridgeChecks(has: ['Stream<VideoFrame> get frames']),
      kotlin: BridgeChecks(has: ['frames']),
      skip: {Lang.cpp},
    );

    specTest(
      'targetBitrate optional int? param uses packInt in Dart',
      _mediaSrc,
      dart: BridgeChecks(has: ['arena.packInt(targetBitrate)']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════════
  // §C  SettingsMod — @HybridRecord, NitroAnyMap param + return
  // ══════════════════════════════════════════════════════════════════════════════

  final _settingsSrc = _src('''
    @HybridRecord
    class AppConfig {
      String theme;
      bool darkMode;
      int maxRetries;
    }

    @NitroModule(
      ios: NativeImpl.swift,
      android: NativeImpl.kotlin,
      lib: 'settings_mod',
    )
    abstract class SettingsMod {
      // record params/returns
      AppConfig getConfig();
      Future<void> applyConfig(AppConfig config);
      Future<AppConfig> mergeConfig(AppConfig base, AppConfig overlay);

      // NitroAnyMap — heterogeneous key-value storage
      NitroAnyMap getAll();
      Future<void> setAll(NitroAnyMap map);
      Future<NitroAnyMap> query(NitroAnyMap filters);

      // mixed: record + NitroAnyMap in same call
      Future<AppConfig> buildFromMap(NitroAnyMap rawMap);

      // properties using NitroAnyMap
      String get currentTheme;
      bool get isDarkMode;
    }
  ''');

  group('§C SettingsMod — @HybridRecord + NitroAnyMap', () {
    specTest(
      'all method names present in Dart',
      _settingsSrc,
      dart: BridgeChecks(has: ['getConfig', 'applyConfig', 'mergeConfig', 'getAll', 'setAll', 'query', 'buildFromMap']),
      skip: {Lang.cpp},
    );

    specTest(
      'AppConfig record data class in Kotlin has all fields',
      _settingsSrc,
      kotlin: BridgeChecks(has: ['data class AppConfig(', 'val theme: String', 'val darkMode: Boolean', 'val maxRetries: Long']),
      skip: {Lang.cpp},
    );

    specTest(
      'NitroAnyMap param encoded with toNative(arena) in Dart',
      _settingsSrc,
      dart: BridgeChecks(has: ['toNative(arena)']),
      skip: {Lang.cpp},
    );

    specTest(
      'NitroAnyMap return decoded with NitroAnyMap.fromNative in Dart',
      _settingsSrc,
      dart: BridgeChecks(has: ['NitroAnyMap.fromNative(']),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin bridge uses NitroAnyMapCodec for setAll param',
      _settingsSrc,
      kotlin: BridgeChecks(has: ['NitroAnyMapCodec']),
      skip: {Lang.cpp},
    );

    specTest(
      'NitroAnyMapCodec object emitted in Kotlin bridge',
      _settingsSrc,
      kotlin: BridgeChecks(has: ['private object NitroAnyMapCodec']),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin NitroAnyMapCodec includes all 7 AnyValue type tags',
      _settingsSrc,
      kotlin: BridgeChecks(
        has: ['ANY_NULL', 'ANY_BOOL', 'ANY_INT', 'ANY_DOUBLE', 'ANY_STRING', 'ANY_LIST', 'ANY_OBJECT'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin getAll bridge method returns ByteArray for NitroAnyMap',
      _settingsSrc,
      kotlin: BridgeChecks(has: ['fun getAll_call(instanceId: Long): ByteArray']),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin setAll bridge method takes ByteArray for NitroAnyMap',
      _settingsSrc,
      kotlin: BridgeChecks(has: ['fun setAll_call(instanceId: Long, map: ByteArray)']),
      skip: {Lang.cpp},
    );

    specTest(
      'NitroAnyMap does not use JSON library types (Gson, JSONObject) in output',
      _settingsSrc,
      dart: BridgeChecks(hasNot: ['jsonEncode', 'jsonDecode']),
      kotlin: BridgeChecks(hasNot: ['Gson', 'JSONObject', 'org.json']),
      skip: {Lang.cpp},
    );

    specTest(
      'currentTheme and isDarkMode properties emitted',
      _settingsSrc,
      dart: BridgeChecks(has: ['String get currentTheme', 'bool get isDarkMode']),
      kotlin: BridgeChecks(has: ['currentTheme', 'isDarkMode']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════════
  // §D  SensorMod — multiple streams, nullable types, callbacks
  // ══════════════════════════════════════════════════════════════════════════════

  final _sensorSrc = _src('''
    @HybridEnum(startValue: 0)
    enum SensorStatus { offline, online, error }

    @HybridStruct(packed: true)
    class SensorReading {
      double temperature;
      double humidity;
      int timestampMs;
    }

    @HybridRecord
    class CalibrationData {
      double offsetTemp;
      double offsetHumidity;
      String sensorId;
    }

    @NitroModule(
      ios: NativeImpl.swift,
      android: NativeImpl.kotlin,
      lib: 'sensor_mod',
    )
    abstract class SensorMod {
      // sync with nullable returns
      double? getTemperature();
      double? getHumidity();
      int? getLastTimestamp();
      SensorStatus getStatus();

      // async with optional params
      Future<void> calibrate({CalibrationData? data});
      Future<SensorReading> snapshot();

      // reading last result (may not exist yet)
      Future<SensorReading?> getLastReading();

      // nullable record return
      CalibrationData? getCalibration();

      // multiple streams — different item types
      Stream<double> temperature();
      Stream<double> humidity();
      Stream<SensorReading> readings();
      Stream<SensorStatus> status();

      // callback param
      void onReadingAvailable(void Function(SensorReading) callback);

      // properties
      bool get isConnected;
      String get sensorId;
    }
  ''');

  group('§D SensorMod — multiple streams + nullable + callbacks', () {
    specTest(
      'all method names present in Dart',
      _sensorSrc,
      dart: BridgeChecks(
        has: ['getTemperature', 'getHumidity', 'getLastTimestamp', 'getStatus', 'calibrate', 'snapshot', 'onReadingAvailable'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'SensorStatus enum in all bridge outputs',
      _sensorSrc,
      all: BridgeChecks(has: ['SensorStatus']),
      skip: {Lang.cpp},
    );

    specTest(
      '4 streams emitted: temperature, humidity, readings, status',
      _sensorSrc,
      dart: BridgeChecks(has: [
        'Stream<double> get temperature',
        'Stream<double> get humidity',
        'Stream<SensorReading> get readings',
        'Stream<SensorStatus> get status',
      ]),
      kotlin: BridgeChecks(has: ['temperature', 'humidity', 'readings', 'status']),
      skip: {Lang.cpp},
    );

    specTest(
      'Stream<SensorReading> uses struct-pointer unpack in Dart',
      _sensorSrc,
      dart: BridgeChecks(has: ['Pointer<SensorReadingFfi>.fromAddress(message as int)']),
      skip: {Lang.cpp},
    );

    specTest(
      'Stream<double> temperature uses direct cast unpack',
      _sensorSrc,
      dart: BridgeChecks(has: ['message as double']),
      skip: {Lang.cpp},
    );

    specTest(
      'Kotlin SensorReading struct data class present',
      _sensorSrc,
      kotlin: BridgeChecks(has: ['data class SensorReading(val temperature: Double, val humidity: Double, val timestampMs: Long)']),
      skip: {Lang.cpp},
    );

    specTest(
      'CalibrationData record has decode/encode in Kotlin',
      _sensorSrc,
      kotlin: BridgeChecks(has: ['fun decode(bytes: ByteArray): CalibrationData', 'fun encode(): ByteArray']),
      skip: {Lang.cpp},
    );

    specTest(
      'nullable double? return uses NitroOptFloat64 struct in Dart',
      _sensorSrc,
      dart: BridgeChecks(has: ['NitroOptFloat64']),
      skip: {Lang.cpp},
    );

    specTest(
      'nullable int? return uses NitroOptInt64 struct in Dart',
      _sensorSrc,
      dart: BridgeChecks(has: ['NitroOptInt64']),
      skip: {Lang.cpp},
    );

    specTest(
      'Swift has async throws for snapshot',
      _sensorSrc,
      swift: BridgeChecks(has: ['func snapshot()']),
      skip: {Lang.cpp},
    );

    specTest(
      'isConnected and sensorId properties emitted',
      _sensorSrc,
      dart: BridgeChecks(has: ['bool get isConnected', 'String get sensorId']),
      kotlin: BridgeChecks(has: ['isConnected', 'sensorId']),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════════
  // §E  EdgeMod — edge cases across all generators
  // ══════════════════════════════════════════════════════════════════════════════

  group('§E EdgeMod — edge cases', () {
    // ── E1: no-param, void-return function ────────────────────────────────────
    specTest(
      'E1: no-param void function generates correctly',
      _src('''
        abstract class EdgeMod {
          void reset();
          Future<void> softReset();
        }
      '''),
      dart: BridgeChecks(has: ['void reset()', 'Future<void> softReset()']),
      kotlin: BridgeChecks(has: ['fun reset_call(instanceId: Long)', 'suspend fun softReset(): Unit']),
      skip: {Lang.cpp},
    );

    // ── E2: max number of mixed params ────────────────────────────────────────
    specTest(
      'E2: many mixed-type params — all generated correctly',
      _src('''
        abstract class EdgeMod {
          double compute(
            double a, double b, double c,
            int x, int y,
            String label,
            bool flag,
            {int? optCount, double? optScale, bool? optVerbose}
          );
        }
      '''),
      dart: BridgeChecks(
        has: ['a', 'b', 'c', 'x', 'y', 'label', 'flag',
              'arena.packInt(optCount)', 'arena.packDouble(optScale)', 'arena.packBool(optVerbose)'],
      ),
      kotlin: BridgeChecks(
        has: ['NitroOptInt64.decode(optCount)', 'NitroOptFloat64.decode(optScale)', 'NitroOptBool.decode(optVerbose)'],
      ),
      skip: {Lang.cpp},
    );

    // ── E3: String? nullable param and return ─────────────────────────────────
    specTest(
      'E3: String? param uses nullptr sentinel (not packXxx)',
      _src('''
        abstract class EdgeMod {
          String? lookup(String? key);
        }
      '''),
      dart: BridgeChecks(
        has: ['Pointer<Utf8>'],
        hasNot: ['packString'],
      ),
      skip: {Lang.cpp},
    );

    // ── E4: same type used as param AND return ────────────────────────────────
    specTest(
      'E4: same record type as both param and return',
      _src('''
        @HybridRecord
        class Point {
          double x;
          double y;
        }
        abstract class EdgeMod {
          Point transform(Point input);
          Future<Point> asyncTransform(Point input);
        }
      '''),
      dart: BridgeChecks(has: ['transform', 'asyncTransform', 'Pointer<Uint8>']),
      kotlin: BridgeChecks(has: ['fun transform', 'suspend fun asyncTransform', 'Point']),
      skip: {Lang.cpp},
    );

    // ── E5: camelCase → snake_case C symbol conversion ────────────────────────
    specTest(
      'E5: camelCase method converted to snake_case C symbol',
      _src('''
        abstract class EdgeMod {
          void doHeavyWorkNow();
          Future<void> fetchRemoteConfigAsync();
          String getShortUserName();
        }
      '''),
      dart: BridgeChecks(
        has: ['do_heavy_work_now', 'fetch_remote_config_async', 'get_short_user_name'],
      ),
      skip: {Lang.cpp},
    );

    // ── E6: multiple enums in same spec ──────────────────────────────────────
    specTest(
      'E6: multiple enums — all appear in bridge output',
      _src('''
        @HybridEnum(startValue: 0)
        enum Priority { low, normal, high, critical }

        @HybridEnum(startValue: 1)
        enum Direction { north, south, east, west }

        abstract class EdgeMod {
          void schedule(Priority p);
          void move(Direction d);
          Priority getCurrentPriority();
        }
      '''),
      all: BridgeChecks(has: ['Priority', 'Direction']),
      dart: BridgeChecks(has: ['schedule', 'move', 'getCurrentPriority']),
      skip: {Lang.cpp},
    );

    // ── E7: multiple structs in same spec ─────────────────────────────────────
    specTest(
      'E7: multiple structs — all generated with correct field types',
      _src('''
        @HybridStruct(packed: true)
        class Vec2 { double x; double y; }

        @HybridStruct(packed: true)
        class Vec3 { double x; double y; double z; }

        @HybridStruct(packed: true)
        class RGBA { int r; int g; int b; int a; }

        abstract class EdgeMod {
          Vec3 cross(Vec2 a, Vec2 b);
          RGBA blendColors(RGBA src, RGBA dst, double alpha);
        }
      '''),
      kotlin: BridgeChecks(
        has: ['data class Vec2(val x: Double, val y: Double)',
              'data class Vec3(val x: Double, val y: Double, val z: Double)',
              'data class RGBA(val r: Long, val g: Long, val b: Long, val a: Long)'],
      ),
      skip: {Lang.cpp},
    );

    // ── E8: mixed @HybridRecord + NitroAnyMap + optional primitives ───────────
    specTest(
      'E8: @HybridRecord + NitroAnyMap + optional primitives in one spec',
      _src('''
        @HybridRecord
        class UserProfile {
          String name;
          int age;
          double score;
        }

        abstract class EdgeMod {
          // optional primitives
          Future<void> update({int? userId, double? score, bool? active});

          // record + anymap in same spec
          UserProfile fromMap(NitroAnyMap data);
          NitroAnyMap toMap(UserProfile profile);

          // anymap passing extra metadata
          Future<UserProfile> fetch(int userId, {NitroAnyMap? options});
        }
      '''),
      dart: BridgeChecks(
        has: ['arena.packInt(userId)', 'arena.packDouble(score)', 'arena.packBool(active)',
              'NitroAnyMap.fromNative(', 'toNative(arena)'],
      ),
      kotlin: BridgeChecks(
        has: ['NitroAnyMapCodec', 'NitroOptInt64', 'NitroOptFloat64', 'NitroOptBool',
              'data class UserProfile('],
      ),
      skip: {Lang.cpp},
    );

    // ── E9: stream of nullable primitive — Stream<double?> ───────────────────
    specTest(
      'E9: Stream<int> and Stream<String> both handled',
      _src('''
        abstract class EdgeMod {
          Stream<int> ids();
          Stream<String> names();
          Stream<bool> flags();
        }
      '''),
      dart: BridgeChecks(has: ['Stream<int> get ids', 'Stream<String> get names', 'Stream<bool> get flags']),
      kotlin: BridgeChecks(has: ['ids', 'names', 'flags']),
      skip: {Lang.cpp},
    );

    // ── E10: all-async module — no sync functions ─────────────────────────────
    specTest(
      'E10: all-async module — no sync FFI lookups',
      _src('''
        abstract class EdgeMod {
          Future<String> load(String url);
          Future<int> download(String url, String dest);
          Future<void> clear();
          Future<bool> exists(String path);
        }
      '''),
      dart: BridgeChecks(
        has: ['load', 'download', 'clear', 'exists'],
        hasNot: ['.asFunction(isLeaf:'],
      ),
      kotlin: BridgeChecks(
        has: ['suspend fun load', 'suspend fun download', 'suspend fun clear', 'suspend fun exists'],
      ),
      skip: {Lang.cpp},
    );

    // ── E11: NitroAnyMap only spec (no records/structs) ───────────────────────
    specTest(
      'E11: NitroAnyMap-only spec — codec emitted, no @HybridRecord data class',
      _src('''
        abstract class EdgeMod {
          NitroAnyMap get preferences;
          set preferences(NitroAnyMap value);
          Future<NitroAnyMap> fetchRemote();
        }
      '''),
      kotlin: BridgeChecks(
        has: ['NitroAnyMapCodec', 'ANY_NULL', 'ANY_BOOL', 'ANY_STRING'],
        hasNot: ['data class'],
      ),
      dart: BridgeChecks(
        has: ['NitroAnyMap', 'NitroAnyMap.fromNative('],
        hasNot: ['RecordReader'],
      ),
      skip: {Lang.cpp},
    );

    // ── E12: C++ impl (NativeImpl.cpp) spec ──────────────────────────────────
    specTest(
      'E12: C++ impl — C++ interface has pure-virtual signatures',
      _src('''
        @NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)
        abstract class CppMod {
          double lerp(double a, double b, double t);
          void reset();
          String describe();
        }
      '''),
      cpp: BridgeChecks(
        has: ['virtual double lerp(double a, double b, double t) = 0;',
              'virtual void reset() = 0;',
              'virtual std::string describe() = 0;'],
      ),
    );

    // ── E13: Kotlin-only module ────────────────────────────────────────────────
    specTest(
      'E13: android-only module — Kotlin output generated, Swift skipped',
      _src('''
        @NitroModule(ios: NativeImpl.cpp, android: NativeImpl.kotlin)
        abstract class KtOnlyMod {
          void ping();
          Future<String> fetch();
        }
      '''),
      kotlin: BridgeChecks(has: ['ping', 'fetch']),
      skip: {Lang.cpp},
    );

    // ── E14: all-primitive high-frequency module (leaf binding checks) ─────────
    specTest(
      'E14: all-primitive sync functions use isLeaf: true (fast path)',
      _src('''
        abstract class FastMod {
          double addD(double a, double b);
          int addI(int a, int b);
          bool andB(bool a, bool b);
        }
      '''),
      dart: BridgeChecks(has: ['isLeaf: true']),
      skip: {Lang.cpp},
    );

    // ── E15: module with no streams — no stream boilerplate ──────────────────
    specTest(
      'E15: stream-free module — no stream boilerplate in Dart',
      _src('''
        abstract class StaticMod {
          double compute(double x);
          String format(double v, int digits);
        }
      '''),
      dart: BridgeChecks(
        has: ['compute', 'format'],
        hasNot: ['register_', 'release_', 'NitroStreamController'],
      ),
      kotlin: BridgeChecks(
        hasNot: ['Flow<', 'kotlinx.coroutines'],
      ),
      skip: {Lang.cpp},
    );
  });

  // ══════════════════════════════════════════════════════════════════════════════
  // §F  Multi-spec cross-checks — verify specs don't bleed into each other
  // ══════════════════════════════════════════════════════════════════════════════

  group('§F Cross-spec isolation — generators are stateless', () {
    test('running two specs back-to-back produces independent outputs', () {
      final spec1 = SpecFromSource.parse('''
        abstract class Alpha {
          String greet(String name);
        }
      ''');
      final spec2 = SpecFromSource.parse('''
        abstract class Beta {
          int count();
        }
      ''');

      final dart1 = DartFfiGenerator.generate(spec1);
      final dart2 = DartFfiGenerator.generate(spec2);

      expect(dart1, contains('Alpha'));
      expect(dart1, isNot(contains('Beta')));

      expect(dart2, contains('Beta'));
      expect(dart2, isNot(contains('Alpha')));
    });

    test('NitroAnyMap spec does not pollute adjacent plain spec output', () {
      final specWithMap = SpecFromSource.parse('''
        abstract class MapMod {
          NitroAnyMap getMap();
        }
      ''');
      final specPlain = SpecFromSource.parse('''
        abstract class PlainMod {
          double add(double a, double b);
        }
      ''');

      final kotlinMap = KotlinGenerator.generate(specWithMap);
      final kotlinPlain = KotlinGenerator.generate(specPlain);

      expect(kotlinMap, contains('NitroAnyMapCodec'));
      expect(kotlinPlain, isNot(contains('NitroAnyMapCodec')));
    });

    test('enum from one spec does not appear in another spec output', () {
      final specA = SpecFromSource.parse('''
        @HybridEnum()
        enum Color { red, green, blue }

        abstract class PainterA {
          void paint(Color c);
        }
      ''');
      final specB = SpecFromSource.parse('''
        abstract class PainterB {
          void clear();
        }
      ''');

      final swiftA = SwiftGenerator.generate(specA);
      final swiftB = SwiftGenerator.generate(specB);

      expect(swiftA, contains('Color'));
      expect(swiftB, isNot(contains('Color')));
    });

    test('struct from one spec does not appear in another', () {
      final specA = SpecFromSource.parse('''
        @HybridStruct(packed: true)
        class Point { double x; double y; }
        abstract class GeoA {
          Point locate();
        }
      ''');
      final specB = SpecFromSource.parse('''
        abstract class GeoB {
          String ping();
        }
      ''');

      final ktA = KotlinGenerator.generate(specA);
      final ktB = KotlinGenerator.generate(specB);

      expect(ktA, contains('data class Point'));
      expect(ktB, isNot(contains('Point')));
    });

    test('C header from one spec does not bleed symbols into another', () {
      final specA = SpecFromSource.parse('''
        abstract class Alpha {
          double alpha_compute(double x);
        }
      ''');
      final specB = SpecFromSource.parse('''
        abstract class Beta {
          int beta_count();
        }
      ''');

      final hA = CppHeaderGenerator.generate(specA);
      final hB = CppHeaderGenerator.generate(specB);

      expect(hA, contains('alpha'));
      expect(hB, isNot(contains('alpha')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════════
  // §G  NitroAnyMap deep integration — generator correctness checks
  // ══════════════════════════════════════════════════════════════════════════════

  group('§G NitroAnyMap deep integration', () {
    specTest(
      'G1: NitroAnyMap param — Dart FFI uses Pointer<Uint8>',
      _src('''
        abstract class MapMod {
          void configure(NitroAnyMap options);
        }
      '''),
      dart: BridgeChecks(
        has: ['Pointer<Uint8>', 'toNative(arena)'],
        hasNot: ['jsonEncode'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'G2: NitroAnyMap return — Dart FFI decodes with fromNative',
      _src('''
        abstract class MapMod {
          NitroAnyMap getDefaults();
        }
      '''),
      dart: BridgeChecks(
        has: ['NitroAnyMap.fromNative(', 'NitroAnyMap'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'G3: async NitroAnyMap return — Kotlin suspend returns Map<String, Any?>',
      _src('''
        abstract class MapMod {
          Future<NitroAnyMap> fetchAll();
        }
      '''),
      kotlin: BridgeChecks(
        has: ['suspend fun fetchAll(): Map<String, Any?>',
              'NitroAnyMapCodec.encode'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'G4: NitroAnyMap appears as ByteArray in Kotlin bridge method',
      _src('''
        abstract class MapMod {
          void push(NitroAnyMap data);
          NitroAnyMap pull();
        }
      '''),
      kotlin: BridgeChecks(
        has: ['fun push_call(instanceId: Long, data: ByteArray)',
              'fun pull_call(instanceId: Long): ByteArray'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'G5: NitroAnyMap and @HybridRecord coexist — both codecs emitted',
      _src('''
        @HybridRecord
        class Metrics {
          int count;
          double avg;
        }

        abstract class MapMod {
          Metrics analyze(NitroAnyMap events);
          NitroAnyMap export(Metrics stats);
        }
      '''),
      kotlin: BridgeChecks(
        has: ['NitroAnyMapCodec', 'data class Metrics(', 'fun decode(bytes: ByteArray): Metrics'],
      ),
      dart: BridgeChecks(
        has: ['NitroAnyMap.fromNative(', 'toNative(arena)'],
      ),
      skip: {Lang.cpp},
    );

    specTest(
      'G6: multiple NitroAnyMap params — NitroAnyMapCodec emitted only once',
      _src('''
        abstract class MapMod {
          NitroAnyMap merge(NitroAnyMap base, NitroAnyMap overlay);
          Future<NitroAnyMap> filter(NitroAnyMap data, NitroAnyMap criteria);
        }
      '''),
      kotlin: BridgeChecks(has: ['NitroAnyMapCodec']),
      dart: BridgeChecks(
        has: ['merge', 'filter', 'NitroAnyMap', 'toNative(arena)'],
      ),
      skip: {Lang.cpp},
    );
  });
}
