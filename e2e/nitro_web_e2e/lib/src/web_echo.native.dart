import 'package:nitro/nitro.dart';

import 'web_echo.platform.g.dart';

part 'web_echo.g.dart';

/// Priority levels for [WebEcho.echoEnum].
@HybridEnum()
enum EchoLevel { low, medium, high }

/// A record crossing the framed binary wire.
@HybridRecord()
class EchoStat {
  final int count;
  final double mean;
  final String label;
  final bool ok;

  const EchoStat({
    required this.count,
    required this.mean,
    required this.label,
    required this.ok,
  });
}

/// Web-only nitro module exercising the full 0.7.0 WASM bridge: sync calls
/// across the wire families, error propagation, `@nitroAsync`,
/// `@nitroNativeAsync`, and a native-driven stream.
@NitroModule(
  lib: 'web_echo',
  web: WebNativeImpl.wasm,
)
abstract class WebEcho extends HybridObject {
  static final WebEcho instance = createWebEchoInstance();

  double addDouble(double a, double b);
  int addInt(int a, int b);
  bool negate(bool v);
  String concat(String a, String b);
  int? echoNullableInt(int? v);
  EchoLevel echoEnum(EchoLevel v);
  @zeroCopy
  Uint8List echoBytes(Uint8List data);
  EchoStat echoStat(EchoStat v);
  Map<String, int> incrementValues(Map<String, int> m);

  /// Always throws a native error with code `E_ECHO`.
  void alwaysThrows();

  /// Runs inline on web (no isolates) — sums 0..n-1.
  @nitroAsync
  Future<int> sumTo(int n);

  /// Completion posted through the module post callback.
  @nitroNativeAsync
  Future<int> nativeAsyncEcho(int value);

  /// Emits `count` ints (0..count-1) via `emitTicks`, posted from C++.
  Stream<int> get ticks;
  void emitTicks(int count);

  int get counter;
  set counter(int v);
}
