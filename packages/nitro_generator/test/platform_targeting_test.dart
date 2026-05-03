import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/cpp_mock_generator.dart';
import 'package:nitro_generator/src/generators/cmake_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  // ── Spec helpers ────────────────────────────────────────────────────────────

  group('BridgeSpec.targetsIos / targetsAndroid', () {
    test('both platforms: targetsIos=true, targetsAndroid=true', () {
      final spec = simpleSpec();
      expect(spec.targetsIos, isTrue);
      expect(spec.targetsAndroid, isTrue);
    });

    test('iOS only: targetsIos=true, targetsAndroid=false', () {
      final spec = iosOnlySpec();
      expect(spec.targetsIos, isTrue);
      expect(spec.targetsAndroid, isFalse);
    });

    test('Android only: targetsIos=false, targetsAndroid=true', () {
      final spec = androidOnlySpec();
      expect(spec.targetsIos, isFalse);
      expect(spec.targetsAndroid, isTrue);
    });

    test('iOS C++ only: isCppImpl=true, targetsAndroid=false', () {
      final spec = iosOnlyCppSpec();
      expect(spec.isCppImpl, isTrue);
      expect(spec.targetsAndroid, isFalse);
      expect(spec.targetsIos, isTrue);
    });

    test('Android C++ only: isCppImpl=true, targetsIos=false', () {
      final spec = androidOnlyCppSpec();
      expect(spec.isCppImpl, isTrue);
      expect(spec.targetsIos, isFalse);
      expect(spec.targetsAndroid, isTrue);
    });
  });

  // ── Validation ──────────────────────────────────────────────────────────────

  group('SpecValidator — platform targeting', () {
    test('no platform specified produces NO_TARGET_PLATFORM error', () {
      final spec = BridgeSpec(
        dartClassName: 'Empty',
        lib: 'empty',
        namespace: 'empty',
        sourceUri: 'empty.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM' && i.isError), isTrue);
    });

    test('iOS only: no NO_TARGET_PLATFORM error', () {
      final issues = SpecValidator.validate(iosOnlySpec());
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM'), isFalse);
    });

    test('Android only: no NO_TARGET_PLATFORM error', () {
      final issues = SpecValidator.validate(androidOnlySpec());
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM'), isFalse);
    });
  });

  // ── SwiftGenerator ──────────────────────────────────────────────────────────

  group('SwiftGenerator — platform targeting', () {
    test('iOS targeted: generates Swift protocol', () {
      final out = SwiftGenerator.generate(iosOnlySpec());
      expect(out, contains('HybridIosCameraProtocol'));
      expect(out, contains('import Foundation'));
    });

    test('Android only: returns not-targeted placeholder', () {
      final out = SwiftGenerator.generate(androidOnlySpec());
      expect(out, contains('iOS not targeted'));
      expect(out, isNot(contains('import Foundation')));
    });

    test('both platforms: generates Swift protocol', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('HybridMyCameraProtocol'));
    });
  });

  // ── KotlinGenerator ─────────────────────────────────────────────────────────

  group('KotlinGenerator — platform targeting', () {
    test('Android targeted: generates Kotlin bridge', () {
      final out = KotlinGenerator.generate(androidOnlySpec());
      expect(out, contains('AndroidSensorJniBridge'));
    });

    test('iOS only: returns not-targeted placeholder', () {
      final out = KotlinGenerator.generate(iosOnlySpec());
      expect(out, contains('Android not targeted'));
      expect(out, isNot(contains('package nitro')));
    });

    test('both platforms: generates Kotlin bridge', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, contains('MyCameraJniBridge'));
    });
  });

  // ── CppBridgeGenerator ──────────────────────────────────────────────────────

  group('CppBridgeGenerator — iOS only (Swift)', () {
    test('emits common preamble', () {
      final out = CppBridgeGenerator.generate(iosOnlySpec());
      expect(out, contains('ios_camera_init_dart_api_dl'));
      expect(out, contains('ios_camera_get_error'));
    });

    test('does NOT emit #ifdef __ANDROID__', () {
      final out = CppBridgeGenerator.generate(iosOnlySpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('does NOT emit #elif __APPLE__', () {
      final out = CppBridgeGenerator.generate(iosOnlySpec());
      expect(out, isNot(contains('#elif __APPLE__')));
    });

    test('does NOT emit #endif platform guard', () {
      final out = CppBridgeGenerator.generate(iosOnlySpec());
      // Inner #ifdef __OBJC__ ... #endif blocks are still emitted.
      // But the outer platform #endif should not be present.
      // The outer #endif is only emitted when both includeAndroid and includeIos.
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('emits Swift _call_ declarations', () {
      final out = CppBridgeGenerator.generate(iosOnlySpec());
      expect(out, contains('_call_capture'));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(iosOnlySpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });
  });

  group('CppBridgeGenerator — Android only (Kotlin)', () {
    test('emits common preamble', () {
      final out = CppBridgeGenerator.generate(androidOnlySpec());
      expect(out, contains('android_sensor_init_dart_api_dl'));
      expect(out, contains('android_sensor_get_error'));
    });

    test('does NOT emit #ifdef __ANDROID__', () {
      final out = CppBridgeGenerator.generate(androidOnlySpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('does NOT emit #elif __APPLE__', () {
      final out = CppBridgeGenerator.generate(androidOnlySpec());
      expect(out, isNot(contains('#elif __APPLE__')));
    });

    test('emits JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(androidOnlySpec());
      expect(out, contains('JNI_OnLoad'));
    });

    test('does NOT emit Swift _call_ declarations', () {
      final out = CppBridgeGenerator.generate(androidOnlySpec());
      expect(out, isNot(contains('_call_read')));
    });
  });

  group('CppBridgeGenerator — iOS C++ only', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(iosOnlyCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('ios_processor_register_impl'));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(iosOnlyCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('does NOT emit Swift _call_ declarations', () {
      final out = CppBridgeGenerator.generate(iosOnlyCppSpec());
      expect(out, isNot(contains('_call_process')));
    });

    test('wraps code in #ifdef __APPLE__ guard (covers iOS + macOS)', () {
      final out = CppBridgeGenerator.generate(iosOnlyCppSpec());
      expect(out, contains('#ifdef __APPLE__'));
      expect(out, contains('#endif // __APPLE__'));
    });

    test('does NOT emit #ifdef __ANDROID__ guard', () {
      final out = CppBridgeGenerator.generate(iosOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('platform guard wraps includes and impl body', () {
      final out = CppBridgeGenerator.generate(iosOnlyCppSpec());
      final guardStart = out.indexOf('#ifdef __APPLE__');
      final includePos = out.indexOf('#include <stdint.h>');
      final implPos = out.indexOf('ios_processor_register_impl');
      final guardEnd = out.lastIndexOf('#endif // __APPLE__');
      expect(guardStart, lessThan(includePos));
      expect(includePos, lessThan(implPos));
      expect(implPos, lessThan(guardEnd));
    });
  });

  // ── macOS C++ support ───────────────────────────────────────────────────────

  group('BridgeSpec — macOS targeting', () {
    test('macosImpl: targetsMacos=true', () {
      expect(macosOnlyCppSpec().targetsMacos, isTrue);
    });

    test('macOS-only: isCppImpl=true', () {
      expect(macosOnlyCppSpec().isCppImpl, isTrue);
    });

    test('iOS + macOS cpp: isCppImpl=true, targetsAndroid=false', () {
      final spec = appleOnlyCppSpec();
      expect(spec.isCppImpl, isTrue);
      expect(spec.targetsAndroid, isFalse);
      expect(spec.targetsIos, isTrue);
      expect(spec.targetsMacos, isTrue);
    });

    test('iOS + macOS + Android cpp: isCppImpl=true, all platforms targeted', () {
      final spec = triPlatformCppSpec();
      expect(spec.isCppImpl, isTrue);
      expect(spec.targetsIos, isTrue);
      expect(spec.targetsMacos, isTrue);
      expect(spec.targetsAndroid, isTrue);
    });

    test('macosImpl: NativeImpl.kotlin raises INVALID_MACOS_IMPL error', () {
      // NativeImpl.kotlin is KotlinImpl which is a NativeImpl subtype —
      // BridgeSpec.macosImpl is NativeImpl? so this compiles; the validator
      // catches the violation at runtime as a defensive check.
      final spec = BridgeSpec(
        dartClassName: 'Bad',
        lib: 'bad',
        namespace: 'bad',
        macosImpl: NativeImpl.kotlin,
        sourceUri: 'bad.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_MACOS_IMPL' && i.isError), isTrue);
    });

    test('macOS-only: no NO_TARGET_PLATFORM error', () {
      final issues = SpecValidator.validate(macosOnlyCppSpec());
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM'), isFalse);
    });
  });

  group('CppBridgeGenerator — macOS-only C++', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(macosOnlyCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('mac_processor_register_impl'));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(macosOnlyCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('does NOT emit Swift _call_ declarations', () {
      final out = CppBridgeGenerator.generate(macosOnlyCppSpec());
      expect(out, isNot(contains('_call_process')));
    });

    test('wraps code in #ifdef __APPLE__ guard (same macro covers iOS + macOS)', () {
      final out = CppBridgeGenerator.generate(macosOnlyCppSpec());
      expect(out, contains('#ifdef __APPLE__'));
      expect(out, contains('#endif // __APPLE__'));
    });

    test('does NOT emit #ifdef __ANDROID__ guard', () {
      final out = CppBridgeGenerator.generate(macosOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });
  });

  group('CppBridgeGenerator — iOS + macOS shared C++ (Apple only)', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(appleOnlyCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('apple_processor_register_impl'));
    });

    test('wraps in #ifdef __APPLE__ (no Android)', () {
      final out = CppBridgeGenerator.generate(appleOnlyCppSpec());
      expect(out, contains('#ifdef __APPLE__'));
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(appleOnlyCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });
  });

  group('CppBridgeGenerator — iOS + macOS + Android shared C++ (tri-platform)', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(triPlatformCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('shared_processor_register_impl'));
    });

    test('emits NO platform guard — same source compiles everywhere', () {
      final out = CppBridgeGenerator.generate(triPlatformCppSpec());
      expect(out, isNot(contains('#ifdef __APPLE__')));
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(triPlatformCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('does NOT emit Swift _call_ declarations', () {
      final out = CppBridgeGenerator.generate(triPlatformCppSpec());
      expect(out, isNot(contains('_call_process')));
    });

    test('register_impl and get_impl present for all platforms', () {
      final out = CppBridgeGenerator.generate(triPlatformCppSpec());
      expect(out, contains('shared_processor_register_impl'));
      expect(out, contains('shared_processor_get_impl'));
    });
  });

  group('CppInterfaceGenerator — macOS C++', () {
    test('macOS-only generates abstract class', () {
      final out = CppInterfaceGenerator.generate(macosOnlyCppSpec());
      expect(out, contains('class HybridMacProcessor'));
      expect(out, contains('virtual double process(double value) = 0;'));
    });

    test('tri-platform generates single shared abstract class', () {
      final out = CppInterfaceGenerator.generate(triPlatformCppSpec());
      expect(out, contains('class HybridSharedProcessor'));
      expect(out, contains('shared_processor_register_impl'));
    });
  });

  group('CppBridgeGenerator — Android C++ only', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(androidOnlyCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('android_processor_register_impl'));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(androidOnlyCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('wraps code in #ifdef __ANDROID__ guard', () {
      final out = CppBridgeGenerator.generate(androidOnlyCppSpec());
      expect(out, contains('#ifdef __ANDROID__'));
      expect(out, contains('#endif // __ANDROID__'));
    });

    test('does NOT emit #ifdef __APPLE__ guard', () {
      final out = CppBridgeGenerator.generate(androidOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __APPLE__')));
    });

    test('platform guard wraps includes and impl body', () {
      final out = CppBridgeGenerator.generate(androidOnlyCppSpec());
      final guardStart = out.indexOf('#ifdef __ANDROID__');
      final includePos = out.indexOf('#include <stdint.h>');
      final implPos = out.indexOf('android_processor_register_impl');
      final guardEnd = out.lastIndexOf('#endif // __ANDROID__');
      expect(guardStart, lessThan(includePos));
      expect(includePos, lessThan(implPos));
      expect(implPos, lessThan(guardEnd));
    });
  });

  group('CppBridgeGenerator — both platforms (unchanged behavior)', () {
    test('emits #ifdef __ANDROID__ guard', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('#ifdef __ANDROID__'));
    });

    test('emits #elif __APPLE__ guard', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('#elif __APPLE__'));
    });

    test('emits #endif', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('#endif'));
    });

    test('emits JNI_OnLoad for Android', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('JNI_OnLoad'));
    });

    test('emits Swift _call_ declarations for iOS', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('_call_add'));
    });
  });

  // ── Single-platform with properties ────────────────────────────────────────

  group('SwiftGenerator — iOS-only with property', () {
    test('emits protocol var with getter and setter', () {
      final out = SwiftGenerator.generate(iosOnlyWithPropertySpec());
      expect(out, contains('var level: Double { get set }'));
    });

    test('emits registry stub for property getter', () {
      final out = SwiftGenerator.generate(iosOnlyWithPropertySpec());
      expect(out, contains('_call_get_level'));
    });

    test('emits registry stub for property setter', () {
      final out = SwiftGenerator.generate(iosOnlyWithPropertySpec());
      expect(out, contains('_call_set_level'));
    });
  });

  group('KotlinGenerator — Android-only with property', () {
    test('emits interface var with getter and setter', () {
      final out = KotlinGenerator.generate(androidOnlyWithPropertySpec());
      expect(out, contains('var level: Long'));
    });

    test('emits JniBridge _call for getter', () {
      final out = KotlinGenerator.generate(androidOnlyWithPropertySpec());
      expect(out, contains('android_volume_get_level_call'));
    });

    test('emits JniBridge _call for setter', () {
      final out = KotlinGenerator.generate(androidOnlyWithPropertySpec());
      expect(out, contains('android_volume_set_level_call'));
    });
  });

  // ── Single-platform with streams ───────────────────────────────────────────

  group('CppBridgeGenerator — iOS-only with stream', () {
    test('emits Swift _register_ and _release_ stream forwards', () {
      final out = CppBridgeGenerator.generate(iosOnlyWithStreamSpec());
      expect(out, contains('_register_bpm_stream'));
      expect(out, contains('_release_bpm_stream'));
    });

    test('emits _emit_bpm_to_dart helper', () {
      final out = CppBridgeGenerator.generate(iosOnlyWithStreamSpec());
      expect(out, contains('_emit_bpm_to_dart'));
    });

    test('does NOT emit JNI stream callback', () {
      final out = CppBridgeGenerator.generate(iosOnlyWithStreamSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
      expect(out, isNot(contains('jni_emit_bpm')));
    });
  });

  group('CppBridgeGenerator — Android-only with stream', () {
    test('emits JNI stream emit JNICALL for steps', () {
      final out = CppBridgeGenerator.generate(androidOnlyWithStreamSpec());
      // JNI mangling: underscore in 'emit_steps' → 'emit_1steps'
      expect(out, contains('emit_1steps'));
    });

    test('emits stream register/release via bridge class method IDs', () {
      final out = CppBridgeGenerator.generate(androidOnlyWithStreamSpec());
      expect(out, contains('android_step_counter_register_steps_stream_call'));
    });

    test('does NOT emit Swift extern _emit_X_to_dart helper', () {
      final out = CppBridgeGenerator.generate(androidOnlyWithStreamSpec());
      // iOS-only pattern: void _emit_X_to_dart(int64_t dartPort, ...) helper
      expect(out, isNot(contains('_emit_steps_to_dart')));
    });

    test('does NOT emit Swift extern _register forward declaration', () {
      final out = CppBridgeGenerator.generate(androidOnlyWithStreamSpec());
      // iOS pattern: 'extern void _register_X_stream(int64_t dartPort, ...)'
      expect(out, isNot(contains('extern void _register_steps_stream')));
    });
  });

  // ── CppInterfaceGenerator and CppMockGenerator with single-platform C++ ────

  group('CppInterfaceGenerator — single-platform C++', () {
    test('iOS-only C++ generates abstract class', () {
      final out = CppInterfaceGenerator.generate(iosOnlyCppSpec());
      expect(out, contains('class HybridIosProcessor'));
      expect(out, contains('virtual double process(double value) = 0;'));
    });

    test('Android-only C++ generates abstract class', () {
      final out = CppInterfaceGenerator.generate(androidOnlyCppSpec());
      expect(out, contains('class HybridAndroidProcessor'));
    });

    test('registration API is emitted for iOS-only C++', () {
      final out = CppInterfaceGenerator.generate(iosOnlyCppSpec());
      expect(out, contains('ios_processor_register_impl'));
      expect(out, contains('ios_processor_get_impl'));
    });
  });

  group('CppMockGenerator — single-platform C++', () {
    test('iOS-only C++ mock includes abstract class MOCK_METHOD', () {
      final out = CppMockGenerator.generateMockHeader(iosOnlyCppSpec());
      expect(out, contains('MOCK_METHOD(double, process, (double value), (override))'));
    });

    test('Android-only C++ mock extends correct abstract class', () {
      final out = CppMockGenerator.generateMockHeader(androidOnlyCppSpec());
      expect(out, contains('class MockAndroidProcessor : public HybridAndroidProcessor'));
    });
  });

  // ── CMakeGenerator — platform-agnostic ─────────────────────────────────────

  group('CMakeGenerator — single-platform targeting', () {
    test('iOS-only spec generates cmake with correct lib name', () {
      final out = CMakeGenerator.generate(iosOnlySpec());
      expect(out, contains('set(NITRO_MODULE_NAME ios_camera)'));
    });

    test('Android-only spec generates cmake with correct lib name', () {
      final out = CMakeGenerator.generate(androidOnlySpec());
      expect(out, contains('set(NITRO_MODULE_NAME android_sensor)'));
    });

    test('iOS-only C++ spec generates cmake with correct lib name', () {
      final out = CMakeGenerator.generate(iosOnlyCppSpec());
      expect(out, contains('set(NITRO_MODULE_NAME ios_processor)'));
    });
  });

  // ── hasCppImpl — any-platform C++ ─────────────────────────────────────────

  group('BridgeSpec.hasCppImpl', () {
    test('all-cpp: hasCppImpl=true', () {
      expect(cppSpec().hasCppImpl, isTrue);
    });

    test('mixed ios=cpp android=kotlin: hasCppImpl=true, isCppImpl=false', () {
      final spec = mixedPlatformCppSpec();
      expect(spec.hasCppImpl, isTrue);
      expect(spec.isCppImpl, isFalse);
    });

    test('ios=swift android=kotlin: hasCppImpl=false', () {
      expect(simpleSpec().hasCppImpl, isFalse);
    });

    test('windows-only cpp: hasCppImpl=true', () {
      expect(windowsOnlyCppSpec().hasCppImpl, isTrue);
    });

    test('linux-only cpp: hasCppImpl=true', () {
      expect(linuxOnlyCppSpec().hasCppImpl, isTrue);
    });

    test('web-only: hasCppImpl=false', () {
      expect(webOnlySpec().hasCppImpl, isFalse);
    });

    test('no platforms: hasCppImpl=false', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        sourceUri: 'x.native.dart',
      );
      expect(spec.hasCppImpl, isFalse);
    });
  });

  // ── CppInterfaceGenerator — mixed-platform ─────────────────────────────────

  group('CppInterfaceGenerator — mixed-platform (ios=cpp, android=kotlin)', () {
    test('generates abstract class despite android=kotlin', () {
      final out = CppInterfaceGenerator.generate(mixedPlatformCppSpec());
      expect(out, contains('class HybridMixedProcessor'));
    });

    test('generates pure-virtual methods', () {
      final out = CppInterfaceGenerator.generate(mixedPlatformCppSpec());
      expect(out, contains('virtual double process(double value) = 0;'));
    });

    test('generates registration API', () {
      final out = CppInterfaceGenerator.generate(mixedPlatformCppSpec());
      expect(out, contains('mixed_processor_register_impl'));
      expect(out, contains('mixed_processor_get_impl'));
    });
  });

  // ── CppMockGenerator — mixed-platform ──────────────────────────────────────

  group('CppMockGenerator — mixed-platform (ios=cpp, android=kotlin)', () {
    test('generates mock header despite android=kotlin', () {
      final out = CppMockGenerator.generateMockHeader(mixedPlatformCppSpec());
      expect(out, contains('class MockMixedProcessor'));
    });

    test('generates test starter despite android=kotlin', () {
      final out = CppMockGenerator.generateTestStarter(mixedPlatformCppSpec());
      expect(out, contains('MockMixedProcessor'));
    });
  });

  // ── isCppImpl edge cases ───────────────────────────────────────────────────

  group('BridgeSpec.isCppImpl edge cases', () {
    test('both platforms C++: isCppImpl=true', () {
      expect(cppSpec().isCppImpl, isTrue);
    });

    test('ios swift + android kotlin: isCppImpl=false', () {
      expect(simpleSpec().isCppImpl, isFalse);
    });

    test('ios swift + android null: isCppImpl=false', () {
      expect(iosOnlySpec().isCppImpl, isFalse);
    });

    test('ios null + android kotlin: isCppImpl=false', () {
      expect(androidOnlySpec().isCppImpl, isFalse);
    });

    test('both null: isCppImpl=false (no platform at all)', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        sourceUri: 'x.native.dart',
      );
      expect(spec.isCppImpl, isFalse);
    });

    test('windows cpp only: isCppImpl=true', () {
      expect(windowsOnlyCppSpec().isCppImpl, isTrue);
    });

    test('linux cpp only: isCppImpl=true', () {
      expect(linuxOnlyCppSpec().isCppImpl, isTrue);
    });

    test('windows + linux cpp: isCppImpl=true', () {
      expect(windowsLinuxCppSpec().isCppImpl, isTrue);
    });

    test('all five native cpp platforms: isCppImpl=true', () {
      expect(allNativeCppSpec().isCppImpl, isTrue);
    });

    test('web only: isCppImpl=false (web is never a dart:ffi target)', () {
      expect(webOnlySpec().isCppImpl, isFalse);
    });

    test('web + windows cpp: isCppImpl=true (web does not disqualify native platforms)', () {
      expect(fullCrossPlatformSpec().isCppImpl, isTrue);
    });
  });

  // ── Windows + Linux targeting ──────────────────────────────────────────────

  group('BridgeSpec — Windows targeting', () {
    test('windowsImpl set → targetsWindows=true', () {
      expect(windowsOnlyCppSpec().targetsWindows, isTrue);
    });

    test('windowsImpl null → targetsWindows=false', () {
      expect(simpleSpec().targetsWindows, isFalse);
    });

    test('windows-only: isCppImpl=true, targetsIos=false, targetsAndroid=false', () {
      final spec = windowsOnlyCppSpec();
      expect(spec.isCppImpl, isTrue);
      expect(spec.targetsIos, isFalse);
      expect(spec.targetsAndroid, isFalse);
      expect(spec.targetsMacos, isFalse);
    });

    test('windows-only: targetsDesktopCpp=true', () {
      expect(windowsOnlyCppSpec().targetsDesktopCpp, isTrue);
    });

    test('windows-only: no NO_TARGET_PLATFORM error', () {
      final issues = SpecValidator.validate(windowsOnlyCppSpec());
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM'), isFalse);
    });

    test('windowsImpl: NativeImpl.swift (forced) raises INVALID_WINDOWS_IMPL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Bad',
        lib: 'bad',
        namespace: 'bad',
        windowsImpl: NativeImpl.swift,
        sourceUri: 'bad.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_WINDOWS_IMPL' && i.isError), isTrue);
    });

    test('windowsImpl: NativeImpl.kotlin (forced) raises INVALID_WINDOWS_IMPL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Bad',
        lib: 'bad',
        namespace: 'bad',
        windowsImpl: NativeImpl.kotlin,
        sourceUri: 'bad.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_WINDOWS_IMPL' && i.isError), isTrue);
    });

    test('windowsImpl: NativeImpl.cpp → no INVALID_WINDOWS_IMPL error', () {
      final issues = SpecValidator.validate(windowsOnlyCppSpec());
      expect(issues.any((i) => i.code == 'INVALID_WINDOWS_IMPL'), isFalse);
    });
  });

  group('BridgeSpec — Linux targeting', () {
    test('linuxImpl set → targetsLinux=true', () {
      expect(linuxOnlyCppSpec().targetsLinux, isTrue);
    });

    test('linuxImpl null → targetsLinux=false', () {
      expect(simpleSpec().targetsLinux, isFalse);
    });

    test('linux-only: isCppImpl=true', () {
      expect(linuxOnlyCppSpec().isCppImpl, isTrue);
    });

    test('linux-only: targetsDesktopCpp=true', () {
      expect(linuxOnlyCppSpec().targetsDesktopCpp, isTrue);
    });

    test('linux-only: no NO_TARGET_PLATFORM error', () {
      final issues = SpecValidator.validate(linuxOnlyCppSpec());
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM'), isFalse);
    });

    test('linuxImpl: NativeImpl.swift (forced) raises INVALID_LINUX_IMPL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Bad',
        lib: 'bad',
        namespace: 'bad',
        linuxImpl: NativeImpl.swift,
        sourceUri: 'bad.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_LINUX_IMPL' && i.isError), isTrue);
    });

    test('linuxImpl: NativeImpl.cpp → no INVALID_LINUX_IMPL error', () {
      final issues = SpecValidator.validate(linuxOnlyCppSpec());
      expect(issues.any((i) => i.code == 'INVALID_LINUX_IMPL'), isFalse);
    });
  });

  group('BridgeSpec — Windows + Linux combined', () {
    test('windows + linux: both targets true', () {
      final spec = windowsLinuxCppSpec();
      expect(spec.targetsWindows, isTrue);
      expect(spec.targetsLinux, isTrue);
    });

    test('windows + linux: isCppImpl=true', () {
      expect(windowsLinuxCppSpec().isCppImpl, isTrue);
    });

    test('windows + linux: targetsDesktopCpp=true', () {
      expect(windowsLinuxCppSpec().targetsDesktopCpp, isTrue);
    });

    test('all five native platforms: all target flags true', () {
      final spec = allNativeCppSpec();
      expect(spec.targetsIos, isTrue);
      expect(spec.targetsAndroid, isTrue);
      expect(spec.targetsMacos, isTrue);
      expect(spec.targetsWindows, isTrue);
      expect(spec.targetsLinux, isTrue);
      expect(spec.isCppImpl, isTrue);
    });
  });

  // ── CppBridgeGenerator — Windows + Linux desktop ──────────────────────────

  group('CppBridgeGenerator — Windows-only C++', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('win_processor_register_impl'));
    });

    test('does NOT emit #ifdef __ANDROID__ guard', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('does NOT emit #ifdef __APPLE__ guard', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __APPLE__')));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('does NOT emit Swift _call_ declarations', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, isNot(contains('_call_process')));
    });

    test('emits Dart API DL init symbol', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('win_processor_init_dart_api_dl'));
    });

    test('emits register_impl and get_impl', () {
      final out = CppBridgeGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('win_processor_register_impl'));
      expect(out, contains('win_processor_get_impl'));
    });
  });

  group('CppBridgeGenerator — Linux-only C++', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(linuxOnlyCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('linux_processor_register_impl'));
    });

    test('does NOT emit #ifdef __ANDROID__ guard', () {
      final out = CppBridgeGenerator.generate(linuxOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('does NOT emit #ifdef __APPLE__ guard', () {
      final out = CppBridgeGenerator.generate(linuxOnlyCppSpec());
      expect(out, isNot(contains('#ifdef __APPLE__')));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(linuxOnlyCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('emits Dart API DL init symbol', () {
      final out = CppBridgeGenerator.generate(linuxOnlyCppSpec());
      expect(out, contains('linux_processor_init_dart_api_dl'));
    });
  });

  group('CppBridgeGenerator — Windows + Linux shared C++ (desktop)', () {
    test('uses _generateCppDirect path', () {
      final out = CppBridgeGenerator.generate(windowsLinuxCppSpec());
      expect(out, contains('NativeImpl: cpp'));
      expect(out, contains('desktop_processor_register_impl'));
    });

    test('does NOT emit any platform guard', () {
      final out = CppBridgeGenerator.generate(windowsLinuxCppSpec());
      expect(out, isNot(contains('#ifdef __ANDROID__')));
      expect(out, isNot(contains('#ifdef __APPLE__')));
    });

    test('does NOT emit JNI_OnLoad', () {
      final out = CppBridgeGenerator.generate(windowsLinuxCppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('emits register_impl and get_impl for shared lib', () {
      final out = CppBridgeGenerator.generate(windowsLinuxCppSpec());
      expect(out, contains('desktop_processor_register_impl'));
      expect(out, contains('desktop_processor_get_impl'));
    });
  });

  // ── CppInterfaceGenerator — desktop C++ ───────────────────────────────────

  group('CppInterfaceGenerator — Windows + Linux desktop C++', () {
    test('Windows-only generates abstract class', () {
      final out = CppInterfaceGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('class HybridWinProcessor'));
      expect(out, contains('virtual double process(double value) = 0;'));
    });

    test('Linux-only generates abstract class', () {
      final out = CppInterfaceGenerator.generate(linuxOnlyCppSpec());
      expect(out, contains('class HybridLinuxProcessor'));
    });

    test('Windows + Linux generates shared abstract class', () {
      final out = CppInterfaceGenerator.generate(windowsLinuxCppSpec());
      expect(out, contains('class HybridDesktopProcessor'));
      expect(out, contains('virtual double process(double value) = 0;'));
    });

    test('Windows-only registration API is emitted', () {
      final out = CppInterfaceGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('win_processor_register_impl'));
      expect(out, contains('win_processor_get_impl'));
    });

    test('all-five-native generates universal abstract class', () {
      final out = CppInterfaceGenerator.generate(allNativeCppSpec());
      expect(out, contains('class HybridUniversalProcessor'));
      expect(out, contains('universal_processor_register_impl'));
    });
  });

  // ── CppMockGenerator — desktop C++ ───────────────────────────────────────

  group('CppMockGenerator — Windows + Linux desktop C++', () {
    test('Windows-only mock extends correct abstract class', () {
      final out = CppMockGenerator.generateMockHeader(windowsOnlyCppSpec());
      expect(out, contains('class MockWinProcessor : public HybridWinProcessor'));
    });

    test('Linux-only mock extends correct abstract class', () {
      final out = CppMockGenerator.generateMockHeader(linuxOnlyCppSpec());
      expect(out, contains('class MockLinuxProcessor : public HybridLinuxProcessor'));
    });

    test('Windows + Linux mock extends correct abstract class', () {
      final out = CppMockGenerator.generateMockHeader(windowsLinuxCppSpec());
      expect(out, contains('class MockDesktopProcessor : public HybridDesktopProcessor'));
    });

    test('Windows-only mock MOCK_METHOD emitted for process method', () {
      final out = CppMockGenerator.generateMockHeader(windowsOnlyCppSpec());
      expect(out, contains('MOCK_METHOD(double, process, (double value), (override))'));
    });

    test('Windows test starter references mock class', () {
      final out = CppMockGenerator.generateTestStarter(windowsOnlyCppSpec());
      expect(out, contains('MockWinProcessor'));
    });
  });

  // ── BridgeSpec.hasCppImpl — macOS coverage ────────────────────────────────

  group('BridgeSpec.hasCppImpl — macOS', () {
    test('macOS-only: hasCppImpl=true', () {
      expect(macosOnlyCppSpec().hasCppImpl, isTrue);
    });

    test('iOS + macOS cpp: hasCppImpl=true', () {
      expect(appleOnlyCppSpec().hasCppImpl, isTrue);
    });

    test('macOS-only: isCppImpl=true (single platform, all are cpp)', () {
      expect(macosOnlyCppSpec().isCppImpl, isTrue);
    });

    test('full cross-platform: hasCppImpl=true', () {
      expect(fullCrossPlatformSpec().hasCppImpl, isTrue);
    });

    test('full cross-platform: isCppImpl=true (web does not disqualify)', () {
      expect(fullCrossPlatformSpec().isCppImpl, isTrue);
    });
  });

  // ── CMakeGenerator — desktop and web ─────────────────────────────────────

  group('CMakeGenerator — Windows and Linux targeting', () {
    test('Windows-only sets correct module name', () {
      final out = CMakeGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('set(NITRO_MODULE_NAME win_processor)'));
    });

    test('Linux-only sets correct module name', () {
      final out = CMakeGenerator.generate(linuxOnlyCppSpec());
      expect(out, contains('set(NITRO_MODULE_NAME linux_processor)'));
    });

    test('Windows + Linux sets correct module name', () {
      final out = CMakeGenerator.generate(windowsLinuxCppSpec());
      expect(out, contains('set(NITRO_MODULE_NAME desktop_processor)'));
    });

    test('Windows spec generates valid CMake structure', () {
      final out = CMakeGenerator.generate(windowsOnlyCppSpec());
      expect(out, contains('cmake_minimum_required'));
      expect(out, contains('add_library('));
      expect(out, contains('target_link_libraries('));
    });

    test('all-native generates valid CMake structure', () {
      final out = CMakeGenerator.generate(allNativeCppSpec());
      expect(out, contains('cmake_minimum_required'));
      expect(out, contains('set(NITRO_MODULE_NAME universal_processor)'));
    });
  });

  // ── Web targeting ──────────────────────────────────────────────────────────

  group('BridgeSpec — Web targeting', () {
    test('webImpl set → targetsWeb=true', () {
      expect(webOnlySpec().targetsWeb, isTrue);
    });

    test('webImpl null → targetsWeb=false', () {
      expect(simpleSpec().targetsWeb, isFalse);
    });

    test('web-only: isCppImpl=false', () {
      expect(webOnlySpec().isCppImpl, isFalse);
    });

    test('web-only: no NO_TARGET_PLATFORM error', () {
      final issues = SpecValidator.validate(webOnlySpec());
      expect(issues.any((i) => i.code == 'NO_TARGET_PLATFORM'), isFalse);
    });

    test('webImpl: NativeImpl.cpp (forced) raises INVALID_WEB_IMPL error', () {
      // Critical: CppImpl on web would generate dart:ffi code → web compile failure.
      final spec = BridgeSpec(
        dartClassName: 'Bad',
        lib: 'bad',
        namespace: 'bad',
        webImpl: NativeImpl.cpp,
        sourceUri: 'bad.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_WEB_IMPL' && i.isError), isTrue);
    });

    test('webImpl: NativeImpl.swift (forced) raises INVALID_WEB_IMPL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Bad',
        lib: 'bad',
        namespace: 'bad',
        webImpl: NativeImpl.swift,
        sourceUri: 'bad.native.dart',
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'INVALID_WEB_IMPL' && i.isError), isTrue);
    });

    test('webImpl: NativeImpl.wasm → no INVALID_WEB_IMPL error', () {
      final issues = SpecValidator.validate(webOnlySpec());
      expect(issues.any((i) => i.code == 'INVALID_WEB_IMPL'), isFalse);
    });

    test('full cross-platform: web + all native cpp, no errors', () {
      final issues = SpecValidator.validate(fullCrossPlatformSpec());
      final errors = issues.where((i) => i.isError).toList();
      expect(errors, isEmpty);
    });
  });
}
