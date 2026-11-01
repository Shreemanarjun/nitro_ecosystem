// Binary-size controls emitted into the generated src/CMakeLists.txt:
// opt-in NITRO_SIZE_OPT (dead-code strip + section GC) and NITRO_LTO, with a
// guarded per-target `nitro_apply_size_opts(...)` call on every nitro library.
import 'package:nitrogen_cli/templates/cmake_templates.dart' as ct;
import 'package:test/test.dart';

void main() {
  final cmake = ct.generateCMakeContent(
    'demo',
    ['demo', 'extra'],
    'native',
    moduleInfos: [
      (lib: 'demo', module: 'demo', isNativeCpp: true, isAndroidCpp: true),
      (lib: 'extra', module: 'extra', isNativeCpp: false, isAndroidCpp: false),
    ],
  );

  group('binary-size controls', () {
    test('declares both opt-in knobs, defaulting OFF', () {
      expect(cmake, contains('option(NITRO_SIZE_OPT'));
      expect(cmake, contains('option(NITRO_LTO'));
      expect(cmake, contains('" OFF)'));
    });

    test('defines nitro_apply_size_opts once', () {
      expect('function(nitro_apply_size_opts'.allMatches(cmake).length, 1);
    });

    test('covers every toolchain: ELF gc-sections, Apple dead_strip, MSVC OPT:REF', () {
      expect(cmake, contains('-ffunction-sections -fdata-sections'));
      expect(cmake, contains('-Wl,--gc-sections'));
      expect(cmake, contains('-Wl,-dead_strip'));
      expect(cmake, contains('/OPT:REF /OPT:ICF'));
      expect(cmake, contains('MinSizeRel')); // auto-on for a size build
    });

    test('LTO is gated and non-MSVC', () {
      expect(cmake, contains('if(NITRO_LTO AND NOT MSVC)'));
      expect(cmake, contains('-flto'));
    });

    test('applies to the main library and every module library, guarded', () {
      expect(cmake, contains('nitro_apply_size_opts(demo)'));
      expect(cmake, contains('nitro_apply_size_opts(extra)'));
      // Guard so a standalone/retrofit append without the function is a no-op.
      expect(cmake, contains('if(COMMAND nitro_apply_size_opts)'));
    });

    test('does not change symbol visibility (that would need an export audit)', () {
      expect(cmake, isNot(contains('-fvisibility=hidden')));
    });
  });
}
