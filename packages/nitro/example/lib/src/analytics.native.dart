import 'package:nitro/nitro.dart';

part 'analytics.g.dart';

// ── Analytics module spec — NitroAnyMap for heterogeneous event properties ────
@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Analytics extends HybridObject {
  static final Analytics instance = _AnalyticsImpl();

  // ── Event tracking with NitroAnyMap properties ────────────────────────────
  Future<void> track(String event, NitroAnyMap properties);
  Future<void> identify(String userId, NitroAnyMap traits);

  // ── Heterogeneous config ───────────────────────────────────────────────────
  NitroAnyMap getConfig();
  Future<void> setConfig(NitroAnyMap config);

  // ── Session lifecycle ──────────────────────────────────────────────────────
  Future<void> startSession();
  Future<void> endSession();

  // ── Properties ────────────────────────────────────────────────────────────
  bool get isEnabled;
  set isEnabled(bool value);

  String get sessionId;

  // ── Stream: real-time event acknowledgements ───────────────────────────────
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<String> get events;
}
