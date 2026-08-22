// int64 <-> JS BigInt fidelity at the js_interop boundary.
//
// Lives HERE rather than in packages/nitro/test/ because `flutter test`
// compiles every file under test/ on the VM — even one marked
// @TestOn('browser') that it will then skip — and `dart:js_interop` is not
// available there. This project is only ever run with `-p chrome`.
@TestOn('browser')
library;

import 'package:nitro/src/web/nitro_wasm_module.dart' show dartI64, jsI64;
import 'package:test/test.dart';

void main() {
  group('dartI64 / jsI64', () {
    // Computed, never written as literals: dart2js cannot COMPILE
    // 9223372036854775807, so a literal would break the dart2js run outright.
    final maxI64 = (1 << 62) - 1 + (1 << 62);
    final minI64 = -(1 << 62) - (1 << 62);
    final has64BitInts = maxI64.toString() == '9223372036854775807';

    test('round-trips values inside the exact-double range', () {
      for (final v in <int>[0, 1, -1, 42, -9999, 9007199254740991, -9007199254740991]) {
        expect(dartI64(jsI64(v)), v, reason: '$v');
      }
    });

    test('round-trips the int64 boundary exactly', () {
      // Both directions used to launder the value through a JS double:
      // jsI64 did BigInt(v.toJS) — v.toJS is a NUMBER, so 2^63-1 rounded UP to
      // 2^63 and wrapped to Int64.min BEFORE the BigInt existed — and dartI64
      // did Number(bigint) coming back. Int64.max arrived as Int64.min, which
      // failed three integration tests at once.
      expect(dartI64(jsI64(maxI64)), maxI64);
      expect(dartI64(jsI64(minI64)), minI64);
    }, skip: has64BitInts ? false : 'dart2js ints are 53-bit; Int64.max is not representable');

    test('round-trips values just past 2^53 exactly', () {
      final justPast = (1 << 53) + 1;
      expect(dartI64(jsI64(justPast)), justPast);
    }, skip: has64BitInts ? false : 'needs 64-bit ints');
  });
}
