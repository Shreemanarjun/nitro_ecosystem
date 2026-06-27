// TC5 — Exhaustive platform-combination roundtrip tests.
//
// For every valid combination of (ios, android, macos, windows, linux, web)
// `NativeImpl` values:
//   1. `SpecValidator.validate()` produces zero errors.
//   2. All enabled generators produce non-empty, non-throwing output.
//   3. BridgeSpec platform flags (`targetsIos`, `isCppImpl`, etc.) are
//      consistent with the declared impls.
//
// This is the "no crashes" guarantee: if a spec passes validation, generation
// must never throw for any valid platform combination.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Shared BridgeSpec factory ─────────────────────────────────────────────────

/// A minimal but complete spec covering the most common types, suitable for
/// roundtrip generation on any platform combination.
BridgeSpec _spec({
  NativeImpl? ios,
  NativeImpl? android,
  NativeImpl? macos,
  NativeImpl? windows,
  NativeImpl? linux,
  NativeImpl? web,
}) =>
    BridgeSpec(
      dartClassName: 'Roundtrip',
      lib: 'roundtrip',
      namespace: 'roundtrip',
      sourceUri: 'roundtrip.native.dart',
      iosImpl: ios,
      androidImpl: android,
      macosImpl: macos,
      windowsImpl: windows,
      linuxImpl: linux,
      webImpl: web,
      enums: [
        BridgeEnum(name: 'Status', startValue: 0, values: ['idle', 'running', 'done']),
      ],
      structs: [
        BridgeStruct(
          name: 'Point',
          packed: false,
          fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
            BridgeField(name: 'y', type: BridgeType(name: 'double')),
          ],
        ),
      ],
      functions: [
        BridgeFunction(
          dartName: 'add',
          cSymbol: 'roundtrip_add',
          isAsync: false,
          returnType: BridgeType(name: 'double'),
          params: [
            BridgeParam(name: 'a', type: BridgeType(name: 'double')),
            BridgeParam(name: 'b', type: BridgeType(name: 'double')),
          ],
        ),
        BridgeFunction(
          dartName: 'getStatus',
          cSymbol: 'roundtrip_get_status',
          isAsync: false,
          returnType: BridgeType(name: 'Status'),
          params: [],
        ),
        BridgeFunction(
          dartName: 'describe',
          cSymbol: 'roundtrip_describe',
          isAsync: false,
          returnType: BridgeType(name: 'String'),
          params: [BridgeParam(name: 'p', type: BridgeType(name: 'Point'))],
        ),
      ],
      streams: [
        BridgeStream(
          dartName: 'onStatusChanged',
          registerSymbol: 'roundtrip_register_on_status_changed_stream',
          releaseSymbol: 'roundtrip_release_on_status_changed_stream',
          itemType: BridgeType(name: 'Status'),
          backpressure: Backpressure.dropLatest,
        ),
      ],
    );

/// All valid per-platform implementation values.
const List<NativeImpl> _appleImpls = [NativeImpl.swift, NativeImpl.cpp];
const List<NativeImpl> _androidImpls = [NativeImpl.kotlin, NativeImpl.cpp];

// ── Helper ────────────────────────────────────────────────────────────────────

/// Validates and generates for a spec, failing if any error or throw occurs.
void _assertRoundtrips(BridgeSpec spec, String label) {
  // 1. Validator must produce no errors.
  final issues = SpecValidator.validate(spec);
  final errors = issues.where((i) => i.isError).toList();
  expect(errors, isEmpty,
      reason: '$label: validator emitted ${errors.length} error(s): ${errors.map((e) => e.message).join('; ')}');

  // 2. Dart FFI generator must not throw and must produce non-empty output.
  final dartOut = DartFfiGenerator.generate(spec);
  expect(dartOut, isNotEmpty, reason: '$label: Dart FFI output was empty');

  // 3. C++ bridge + header must not throw.
  final cppBridge = CppBridgeGenerator.generate(spec);
  expect(cppBridge, isNotEmpty, reason: '$label: C++ bridge output was empty');

  final cppHeader = CppHeaderGenerator.generate(spec);
  expect(cppHeader, isNotEmpty, reason: '$label: C++ header output was empty');

  // 4. Kotlin generator only when Android is targeted.
  if (spec.targetsAndroid) {
    final ktOut = KotlinGenerator.generate(spec);
    expect(ktOut, isNotEmpty, reason: '$label: Kotlin output was empty');
  }

  // 5. Swift generator only when Apple targets are present.
  if (spec.targetsIos || spec.targetsMacos) {
    final swiftOut = SwiftGenerator.generate(spec);
    expect(swiftOut, isNotEmpty, reason: '$label: Swift output was empty');
  }

  // 6. C++ interface when any CppImpl is present.
  if (spec.hasCppImpl) {
    final ifaceOut = CppInterfaceGenerator.generate(spec);
    expect(ifaceOut, isNotEmpty, reason: '$label: C++ interface output was empty');
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── Single-platform combos ──────────────────────────────────────────────────
  group('Single-platform specs — validator accepts + all generators produce output', () {
    test('iOS: swift', () => _assertRoundtrips(_spec(ios: NativeImpl.swift), 'ios:swift'));
    test('iOS: cpp', () => _assertRoundtrips(_spec(ios: NativeImpl.cpp), 'ios:cpp'));
    test('Android: kotlin', () => _assertRoundtrips(_spec(android: NativeImpl.kotlin), 'android:kotlin'));
    test('Android: cpp', () => _assertRoundtrips(_spec(android: NativeImpl.cpp), 'android:cpp'));
    test('macOS: swift', () => _assertRoundtrips(_spec(macos: NativeImpl.swift), 'macos:swift'));
    test('macOS: cpp', () => _assertRoundtrips(_spec(macos: NativeImpl.cpp), 'macos:cpp'));
    test('Windows: cpp', () => _assertRoundtrips(_spec(windows: NativeImpl.cpp), 'windows:cpp'));
    test('Linux: cpp', () => _assertRoundtrips(_spec(linux: NativeImpl.cpp), 'linux:cpp'));
    test('Web: wasm', () => _assertRoundtrips(_spec(web: NativeImpl.wasm), 'web:wasm'));
  });

  // ── Canonical iOS + Android combos ─────────────────────────────────────────
  group('iOS × Android — all four canonical combinations', () {
    for (final ios in _appleImpls) {
      for (final android in _androidImpls) {
        final label = 'ios:${ios.runtimeType} android:${android.runtimeType}';
        test(label, () => _assertRoundtrips(_spec(ios: ios, android: android), label));
      }
    }
  });

  // ── Apple platforms (iOS + macOS) ──────────────────────────────────────────
  group('iOS + macOS — all combinations', () {
    for (final ios in _appleImpls) {
      for (final macos in _appleImpls) {
        final label = 'ios:${ios.runtimeType} macos:${macos.runtimeType}';
        test(label, () => _assertRoundtrips(_spec(ios: ios, macos: macos), label));
      }
    }
  });

  // ── Desktop (Windows + Linux) ───────────────────────────────────────────────
  group('Windows + Linux — cpp only', () {
    test('windows:cpp', () => _assertRoundtrips(_spec(windows: NativeImpl.cpp), 'windows:cpp'));
    test('linux:cpp', () => _assertRoundtrips(_spec(linux: NativeImpl.cpp), 'linux:cpp'));
    test('windows:cpp + linux:cpp', () => _assertRoundtrips(_spec(windows: NativeImpl.cpp, linux: NativeImpl.cpp), 'win+lin:cpp'));
  });

  // ── Multi-platform canonical combos ────────────────────────────────────────
  group('Multi-platform — iOS + Android + macOS', () {
    test('swift + kotlin + swift', () => _assertRoundtrips(
        _spec(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift),
        'ios:swift android:kotlin macos:swift'));

    test('cpp + cpp + cpp (full native)', () => _assertRoundtrips(
        _spec(ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp),
        'ios:cpp android:cpp macos:cpp'));

    test('swift + kotlin + cpp (mixed macOS)', () => _assertRoundtrips(
        _spec(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp),
        'ios:swift android:kotlin macos:cpp'));
  });

  group('Full cross-platform specs', () {
    test('swift + kotlin + swift + cpp + cpp (5 native platforms)', () => _assertRoundtrips(
        _spec(
          ios: NativeImpl.swift,
          android: NativeImpl.kotlin,
          macos: NativeImpl.swift,
          windows: NativeImpl.cpp,
          linux: NativeImpl.cpp,
        ),
        'all-native:swift+kotlin+swift+cpp+cpp'));

    test('cpp on all 5 native platforms (isCppImpl=true)', () {
      final spec = _spec(
        ios: NativeImpl.cpp,
        android: NativeImpl.cpp,
        macos: NativeImpl.cpp,
        windows: NativeImpl.cpp,
        linux: NativeImpl.cpp,
      );
      expect(spec.isCppImpl, isTrue,
          reason: 'All-cpp spec should report isCppImpl=true');
      _assertRoundtrips(spec, 'all-native:cpp');
    });

    test('all 6 platforms: swift + kotlin + swift + cpp + cpp + wasm', () => _assertRoundtrips(
        _spec(
          ios: NativeImpl.swift,
          android: NativeImpl.kotlin,
          macos: NativeImpl.swift,
          windows: NativeImpl.cpp,
          linux: NativeImpl.cpp,
          web: NativeImpl.wasm,
        ),
        'all-6-platforms'));

    test('web + iOS swift (no android)', () => _assertRoundtrips(
        _spec(ios: NativeImpl.swift, web: NativeImpl.wasm),
        'ios:swift+web:wasm'));
  });

  // ── BridgeSpec flag consistency ─────────────────────────────────────────────
  group('BridgeSpec platform flag consistency', () {
    test('targetsIos/targetsAndroid/targetsMacos agree with the declared impls', () {
      final spec = _spec(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift);
      expect(spec.targetsIos, isTrue);
      expect(spec.targetsAndroid, isTrue);
      expect(spec.targetsMacos, isTrue);
      expect(spec.targetsWindows, isFalse);
      expect(spec.targetsLinux, isFalse);
      expect(spec.targetsWeb, isFalse);
    });

    test('iosIsCpp true only when ios = NativeImpl.cpp', () {
      expect(_spec(ios: NativeImpl.cpp).iosIsCpp, isTrue);
      expect(_spec(ios: NativeImpl.swift).iosIsCpp, isFalse);
    });

    test('macosIsCpp true only when macos = NativeImpl.cpp', () {
      expect(_spec(macos: NativeImpl.cpp).macosIsCpp, isTrue);
      expect(_spec(macos: NativeImpl.swift).macosIsCpp, isFalse);
    });

    test('hasCppImpl true when any platform uses NativeImpl.cpp', () {
      expect(_spec(ios: NativeImpl.cpp).hasCppImpl, isTrue);
      expect(_spec(android: NativeImpl.cpp).hasCppImpl, isTrue);
      expect(_spec(windows: NativeImpl.cpp).hasCppImpl, isTrue);
      expect(_spec(ios: NativeImpl.swift, android: NativeImpl.kotlin).hasCppImpl, isFalse);
    });

    test('isCppImpl true when ALL targeted platforms use NativeImpl.cpp', () {
      expect(_spec(ios: NativeImpl.cpp, android: NativeImpl.cpp).isCppImpl, isTrue);
      expect(_spec(ios: NativeImpl.swift, android: NativeImpl.cpp).isCppImpl, isFalse);
    });

    test('targetsAppleCpp true when any Apple platform uses cpp', () {
      expect(_spec(ios: NativeImpl.cpp).targetsAppleCpp, isTrue);
      expect(_spec(macos: NativeImpl.cpp).targetsAppleCpp, isTrue);
      expect(_spec(ios: NativeImpl.swift, macos: NativeImpl.swift).targetsAppleCpp, isFalse);
    });
  });

  // ── Exhaustive matrix — every valid single-field combo passes validation ────
  group('Exhaustive single-platform validation — no spec crashes the validator', () {
    final cases = <String, BridgeSpec Function()>{
      'ios:swift': () => _spec(ios: NativeImpl.swift),
      'ios:cpp': () => _spec(ios: NativeImpl.cpp),
      'android:kotlin': () => _spec(android: NativeImpl.kotlin),
      'android:cpp': () => _spec(android: NativeImpl.cpp),
      'macos:swift': () => _spec(macos: NativeImpl.swift),
      'macos:cpp': () => _spec(macos: NativeImpl.cpp),
      'windows:cpp': () => _spec(windows: NativeImpl.cpp),
      'linux:cpp': () => _spec(linux: NativeImpl.cpp),
      'web:wasm': () => _spec(web: NativeImpl.wasm),
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        final spec = entry.value();
        // Must not throw.
        expect(() => SpecValidator.validate(spec), returnsNormally);
        expect(() => DartFfiGenerator.generate(spec), returnsNormally);
        expect(() => CppBridgeGenerator.generate(spec), returnsNormally);
        expect(() => CppHeaderGenerator.generate(spec), returnsNormally);
      });
    }
  });
}
