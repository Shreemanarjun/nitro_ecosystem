import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'math.g.dart';

// ── Hybrid enum – maps 1:1 to C int ───────────────────────────────────────────
@HybridEnum(startValue: 1)
enum Rounding {
  floor,
  ceil,
  round,
}

// ── Hybrid struct – packed across the C boundary ──────────────────────────────
@HybridStruct(zeroCopy: ['payload'], packed: true)
class Point {
  final double x;
  final double y;
  final Uint8List payload; // zero-copy buffer
  const Point({required this.x, required this.y, required this.payload});
}

// ── Module spec ───────────────────────────────────────────────────────────────
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl(NitroRuntime.loadLib('math'));

  double add(double a, double b);

  @nitroAsync
  Future<double> multiply(double a, double b);

  void processBuffer(@zeroCopy Uint8List data);
}
