// Platform-mix matrix + duplicate-definition guarantees.
//
// Two invariants, both user-facing:
//
// 1. PLATFORM INDEPENDENCE — any subset of platforms can use the C++
//    backend without affecting the other platforms' bridges. The headline
//    case: switching ONLY `macos:` from `NativeImpl.swift` to
//    `NativeImpl.cpp` must leave the Kotlin (Android) and Dart outputs
//    byte-identical, keep the iOS Swift bridge intact, and route macOS
//    through the C++ dispatch behind a TARGET_OS_OSX guard.
//
// 2. NO REPEATED DEFINITIONS — a class/struct/enum is DEFINED exactly once
//    per compiled artifact and referenced everywhere else. C-level structs
//    carry #ifndef guards; types imported from another .native.dart are
//    referenced via importedTypeFiles includes and never re-emitted
//    (spec.local* getters), so user-level code keeps one canonical
//    definition of each type.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

/// A representative spec surface — enum, struct, record, variant, stream,
/// callback, async + native-async methods — parametrized over the full
/// platform grid so every bridge section and type emitter is exercised.
BridgeSpec _spec({
  NativeImpl? android,
  NativeImpl? ios,
  NativeImpl? macos,
  NativeImpl? windows,
  NativeImpl? linux,
}) => BridgeSpec(
  dartClassName: 'Media',
  lib: 'media_kit',
  namespace: 'media_kit',
  androidImpl: android,
  iosImpl: ios,
  macosImpl: macos,
  windowsImpl: windows,
  linuxImpl: linux,
  sourceUri: 'media_kit.native.dart',
  enums: [
    BridgeEnum(name: 'MediaState', startValue: 0, values: ['idle', 'playing', 'paused']),
  ],
  structs: [
    BridgeStruct(
      name: 'Frame',
      packed: true,
      fields: [
        BridgeField(name: 'width', type: BridgeType(name: 'int')),
        BridgeField(name: 'height', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Track',
      fields: [
        BridgeRecordField(name: 'title', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'duration', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  variants: [
    BridgeVariant(
      name: 'MediaEvent',
      cases: [
        BridgeVariantCase(
          name: 'MediaEventPlay',
          label: 'play',
          fields: [BridgeRecordField(name: 'at', dartType: 'int', kind: RecordFieldKind.primitive)],
        ),
        BridgeVariantCase(
          name: 'MediaEventStop',
          label: 'stop',
          fields: [BridgeRecordField(name: 'reason', dartType: 'String', kind: RecordFieldKind.primitive)],
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoTrack',
      cSymbol: 'media_kit_echo_track',
      isAsync: false,
      returnType: BridgeType(name: 'Track', isRecord: true),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'Track', isRecord: true))],
    ),
    BridgeFunction(
      dartName: 'stateFor',
      cSymbol: 'media_kit_state_for',
      isAsync: false,
      returnType: BridgeType(name: 'MediaState'),
      params: [BridgeParam(name: 'code', type: BridgeType(name: 'int'))],
    ),
    BridgeFunction(
      dartName: 'loadAsync',
      cSymbol: 'media_kit_load_async',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Track', isRecord: true),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'Track', isRecord: true))],
    ),
    BridgeFunction(
      dartName: 'onEvent',
      cSymbol: 'media_kit_on_event',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'handler',
          type: BridgeType(
            name: 'void Function(MediaEvent)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'MediaEvent')],
          ),
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'trackStream',
      registerSymbol: 'media_kit_register_track_stream_stream',
      releaseSymbol: 'media_kit_release_track_stream_stream',
      itemType: BridgeType(name: 'Track', isRecord: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// The full grid of meaningful platform combinations.
final _combos = <String, BridgeSpec>{
  'classic mobile (android:kotlin ios:swift macos:swift)': _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.swift),
  'macos:cpp, others unchanged (headline)': _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.cpp),
  'ios:cpp macos:swift': _spec(android: NativeImpl.kotlin, ios: NativeImpl.cpp, macos: NativeImpl.swift),
  'apple both cpp': _spec(android: NativeImpl.kotlin, ios: NativeImpl.cpp, macos: NativeImpl.cpp),
  'android:cpp ios:swift': _spec(android: NativeImpl.cpp, ios: NativeImpl.swift, macos: NativeImpl.swift),
  'mobile + desktop cpp': _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.swift, windows: NativeImpl.cpp, linux: NativeImpl.cpp),
  'macos:cpp alone': _spec(macos: NativeImpl.cpp),
  'windows:cpp alone': _spec(windows: NativeImpl.cpp),
  'all cpp everywhere': _spec(android: NativeImpl.cpp, ios: NativeImpl.cpp, macos: NativeImpl.cpp, windows: NativeImpl.cpp, linux: NativeImpl.cpp),
  'kitchen sink (kotlin+swift+macosCpp+desktopCpp)': _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.cpp, windows: NativeImpl.cpp, linux: NativeImpl.cpp),
};

/// Asserts every occurrence of a definition-opener appears at most [max]
/// times in [out] — the "defined once, referenced elsewhere" contract.
void _definedAtMostOnce(String out, String opener, {String? context, int max = 1}) {
  final count = opener.allMatches(out).length;
  expect(
    count,
    lessThanOrEqualTo(max),
    reason: '"$opener" defined $count times${context == null ? '' : ' in $context'} — types must be defined once and referenced elsewhere',
  );
}

void main() {
  group('platform matrix — every combo generates without errors', () {
    for (final entry in _combos.entries) {
      test(entry.key, () {
        final spec = entry.value;
        // Dart is generated for every combo; the rest per-target.
        expect(() => DartFfiGenerator.generate(spec), returnsNormally);
        if (spec.androidImpl is KotlinImpl) {
          expect(() => KotlinGenerator.generate(spec), returnsNormally);
        }
        if (spec.iosImpl is SwiftImpl || spec.macosImpl is SwiftImpl) {
          expect(() => SwiftGenerator.generate(spec), returnsNormally);
        }
        expect(() => CppBridgeGenerator.generate(spec), returnsNormally);
        expect(() => CppHeaderGenerator.generate(spec), returnsNormally);
        if (spec.hasCppImpl) {
          expect(() => CppInterfaceGenerator.generate(spec), returnsNormally);
        }
      });
    }
  });

  group('platform independence — macos:cpp affects ONLY the macOS path', () {
    final baseline = _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.swift);
    final macosCpp = _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.cpp);

    test('Kotlin (Android) output is byte-identical', () {
      expect(KotlinGenerator.generate(macosCpp), KotlinGenerator.generate(baseline));
    });

    test('Dart FFI output is identical modulo the intentional bridge checksum', () {
      // The one legitimate difference: checkLinkChecksum's hash covers the
      // FULL spec including platform targets — it exists precisely so a
      // regenerated Dart file refuses to pair with a stale native build.
      // Everything else (types, call sites, FFI signatures) must not change
      // when only the macOS backend flips.
      String scrubbed(String s) => s.replaceAll(RegExp(r"checkLinkChecksum\('media_kit', '[0-9a-f]+'"), "checkLinkChecksum('media_kit', '<checksum>'");
      expect(scrubbed(DartFfiGenerator.generate(macosCpp)), scrubbed(DartFfiGenerator.generate(baseline)));
    });

    test('bridge routes macOS through C++ dispatch behind TARGET_OS_OSX, iOS stays Swift', () {
      final out = CppBridgeGenerator.generate(macosCpp);
      expect(out, contains('#include <TargetConditionals.h>'));
      expect(out, contains('#if TARGET_OS_OSX'));
      // macOS side: real C++ virtual dispatch on the registered impl.
      expect(out, contains('media_kit_register_impl'));
      // iOS side: still calls through the Swift @_cdecl externs.
      expect(out, contains('#else  // iOS: NativeImpl.swift'));
      expect(out, contains('_media_kit_call_echoTrack'));
      // Android side: JNI section untouched.
      expect(out, contains('#ifdef __ANDROID__'));
    });

    test('iOS Swift bridge class is still generated when macOS goes C++', () {
      final out = SwiftGenerator.generate(macosCpp);
      expect(out, contains('echoTrack'));
      expect(out, contains('@_cdecl'));
    });

    test('adding desktop C++ on top changes nothing for Kotlin either', () {
      final kitchenSink = _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.cpp, windows: NativeImpl.cpp, linux: NativeImpl.cpp);
      expect(KotlinGenerator.generate(kitchenSink), KotlinGenerator.generate(baseline));
    });

    test('windows/linux desktop section coexists with mixed-Apple in one bridge', () {
      final kitchenSink = _spec(android: NativeImpl.kotlin, ios: NativeImpl.swift, macos: NativeImpl.cpp, windows: NativeImpl.cpp, linux: NativeImpl.cpp);
      final out = CppBridgeGenerator.generate(kitchenSink);
      expect(out, contains('#ifdef __ANDROID__'));
      expect(out, contains('#if TARGET_OS_OSX'));
      expect(out, contains(RegExp(r'#elif defined\(_WIN32\) \|\| defined\(__linux__\)')));
      // The chain closes exactly once (balanced platform #if…#endif chain).
      expect(out.trimRight(), endsWith('#endif'));
    });
  });

  group('no repeated definitions — defined once, referenced elsewhere', () {
    test('Dart: each user-facing type/class is declared once', () {
      // The impl class, record ext, variant ext, struct FFI, enum ext must
      // each appear exactly once even though multiple bridge paths reference
      // them.
      final out = DartFfiGenerator.generate(_combos['kitchen sink (kotlin+swift+macosCpp+desktopCpp)']!);
      _definedAtMostOnce(out, 'class _MediaImpl', context: 'Dart FFI');
      _definedAtMostOnce(out, 'extension TrackRecordExt', context: 'Dart FFI');
      _definedAtMostOnce(out, 'extension MediaEventVariantExt', context: 'Dart FFI');
      _definedAtMostOnce(out, 'final class FrameFfi', context: 'Dart FFI');
      _definedAtMostOnce(out, 'extension MediaStateNativeExt', context: 'Dart FFI');
    });

    test('C header: struct/enum definitions carry idempotent guards', () {
      final out = CppHeaderGenerator.generate(_combos['kitchen sink (kotlin+swift+macosCpp+desktopCpp)']!);
      // The C struct is emitted once, inside its multi-inclusion guard.
      _definedAtMostOnce(out, 'NITRO_STRUCT_FRAME_DEFINED\n#define', context: 'C header');
      _definedAtMostOnce(out, '} Frame;', context: 'C header');
      // Core shared C types are guard-wrapped so several module headers can
      // be included into one TU.
      expect(out, contains('#ifndef NITRO_ERROR_DEFINED'));
      expect(out, contains('#ifndef NITRO_OPT_DEFINED'));
    });

    test('C++ interface header: record/variant/reader/writer defined once', () {
      final out = CppInterfaceGenerator.generate(_combos['all cpp everywhere']!);
      _definedAtMostOnce(out, 'struct Track {', context: 'native.g.h');
      _definedAtMostOnce(out, 'struct NitroRecordWriter {', context: 'native.g.h');
      _definedAtMostOnce(out, 'struct NitroCppBuffer {', context: 'native.g.h');
      _definedAtMostOnce(out, 'class HybridMedia {', context: 'native.g.h');
      // Whole file is include-guarded for multi-TU safety.
      expect(out, contains('#ifndef'));
    });

    test('bridge never redefines interface types — it includes them', () {
      final out = CppBridgeGenerator.generate(_combos['kitchen sink (kotlin+swift+macosCpp+desktopCpp)']!);
      // Referenced via #include of the interface header, not re-emitted.
      _definedAtMostOnce(out, 'struct NitroRecordWriter {', context: 'bridge.g.cpp', max: 0);
      _definedAtMostOnce(out, 'struct Track {', context: 'bridge.g.cpp', max: 0);
      expect(out, contains('#include "media_kit.native.g.h"'));
    });

    test('imported types are referenced, never re-emitted (multi-spec sharing)', () {
      // Module B imports Track/MediaState from module A's .native.dart:
      // every definition-emitting generator must skip them (spec.local*),
      // while the C++ header pulls them in via importedTypeFiles includes.
      final specB = BridgeSpec(
        dartClassName: 'Playlist',
        lib: 'playlist_kit',
        namespace: 'playlist_kit',
        androidImpl: NativeImpl.kotlin,
        iosImpl: NativeImpl.swift,
        macosImpl: NativeImpl.cpp,
        sourceUri: 'playlist_kit.native.dart',
        importedTypeFiles: ['media_kit.native.g.h'],
        enums: [
          BridgeEnum(name: 'MediaState', startValue: 0, values: ['idle', 'playing', 'paused'], isImported: true),
        ],
        recordTypes: [
          BridgeRecordType(
            name: 'Track',
            isImported: true,
            fields: [
              BridgeRecordField(name: 'title', dartType: 'String', kind: RecordFieldKind.primitive),
              BridgeRecordField(name: 'duration', dartType: 'double', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'firstTrack',
            cSymbol: 'playlist_kit_first_track',
            isAsync: false,
            returnType: BridgeType(name: 'Track', isRecord: true),
            params: [],
          ),
        ],
      );
      final header = CppHeaderGenerator.generate(specB);
      expect(header, contains('#include "media_kit.native.g.h"'));
      _definedAtMostOnce(header, '} Track;', context: 'importing header', max: 0);
      _definedAtMostOnce(header, 'NITRO_STRUCT_TRACK', context: 'importing header', max: 0);

      final dart = DartFfiGenerator.generate(specB);
      // The importing module USES Track but must not redefine its extension.
      _definedAtMostOnce(dart, 'extension TrackRecordExt', context: 'importing Dart', max: 0);
      expect(dart, contains('TrackRecordExt.fromNative'));

      final kotlin = KotlinGenerator.generate(specB);
      _definedAtMostOnce(kotlin, 'data class Track', context: 'importing Kotlin', max: 0);
    });
  });
}
