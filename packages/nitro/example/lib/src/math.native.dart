import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'math.g.dart';

// ── Hybrid enum ───────────────────────────────────────────────────────────────
@HybridEnum(startValue: 1)
enum Rounding { floor, ceil, round }

// ── Module spec ───────────────────────────────────────────────────────────────
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  // ── Methods ──────────────────────────────────────────────────────────────────
  double add(double a, double b);

  @nitroAsync
  Future<double> multiply(double a, double b);

  void processBuffer(@zeroCopy Uint8List data);

  // ── Properties ───────────────────────────────────────────────────────────────
  /// Read-only: scale factor applied to every result on the native side.
  double get scaleFactor;

  /// Read-write: precision mode (number of decimal places).
  int get precision;
  set precision(int value);

  // ── Streams ──────────────────────────────────────────────────────────────────
  /// Emits a new value every time native-side state changes.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<double> get updates;
}
