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

/// Carries a NULLABLE list field — the field is bracketed by a 1-byte null
/// tag (0 = null) so an absent list stays distinct from an empty one. [after]
/// exists to catch a tag the reader forgot to consume: a missing tag shifts
/// every later field by a byte rather than failing outright.
@HybridRecord()
class EchoBag {
  final List<int>? tags;
  final int after;

  const EchoBag({required this.tags, required this.after});
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

  /// A typed-data element WIDER than a byte. `Uint8List` alone cannot catch a
  /// length-unit regression: the C side takes `(const T*, size_t length)` in
  /// ELEMENTS and multiplies by `sizeof(T)`, so passing a byte length there is
  /// invisible when `length == lengthInBytes` and returns 4x the elements
  /// (plus heap garbage) as soon as it isn't.
  @zeroCopy
  Int32List echoInt32s(Int32List data);
  EchoStat echoStat(EchoStat v);
  Map<String, int> incrementValues(Map<String, int> m);

  /// `List<@HybridRecord>` — indexed `[4B count][8B×n offsets][items]` in BOTH
  /// directions. C++ parses the offset table with readIndexedList and rebuilds
  /// one with writeIndexedList.
  List<EchoStat> echoStats(List<EchoStat> v);

  /// Primitive lists are deliberately asymmetric: the ARGUMENT is indexed
  /// (matching Kotlin/Swift), the RETURN is plain. Exercising both halves in
  /// one call is the only way to catch a regression to a symmetric encoding.
  List<int> echoInts(List<int> v);

  /// A nullable list crosses as nullptr when absent, in both directions.
  List<EchoStat>? echoMaybeStats(List<EchoStat>? v);

  /// Round-trips a record whose list field is nullable — proves the Dart and
  /// C++ codecs place the null tag in the same position.
  EchoBag echoBag(EchoBag v);

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
