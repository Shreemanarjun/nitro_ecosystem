// readCString scans the heap in 64-byte chunks. Two edge cases used to be
// wrong:
//   * a chunk read that returns FEWER bytes than asked (near the end of linear
//     memory) advanced `base` by the full chunk, skipping the bytes it never
//     looked at;
//   * a read that returns NOTHING (at/after the end) was treated as "no NUL
//     yet", so an unterminated string spun forever instead of throwing.
// The chunk boundary itself is the reachable case, so pin it from both sides.
@TestOn('browser')
library;

import 'package:nitro_web_e2e/nitro_web_e2e.dart';
import 'package:test/test.dart';

void main() {
  late WebEcho echo;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    final port = ((await channel.stream.first)! as num).toInt();
    await ensureWebEchoReady(jsUrl: 'http://localhost:$port/web_echo.js');
    echo = WebEcho.instance;
  });

  test('strings that straddle the 64-byte scan chunk round-trip exactly', () {
    // 63/64/65 bracket the boundary; 128/129 bracket the second one.
    for (final n in [0, 1, 63, 64, 65, 127, 128, 129, 200]) {
      final s = 'x' * n;
      expect(echo.concat(s, ''), s, reason: 'length $n');
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('multi-byte UTF-8 across a chunk boundary is not split', () {
    // 'é' is 2 bytes, so 32 of them land the boundary mid-sequence.
    for (final n in [31, 32, 33]) {
      final s = 'é' * n;
      expect(echo.concat(s, ''), s, reason: '$n × é');
    }
    // A 4-byte code point straddling the boundary.
    expect(echo.concat('${'a' * 62}😀', ''), '${'a' * 62}😀');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('an empty string is not confused with a null pointer', () {
    expect(echo.concat('', ''), '');
  });
}
