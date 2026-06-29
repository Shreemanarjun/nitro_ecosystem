import 'package:nitro/nitro.dart';

part 'config.g.dart';

// ── Typed config record ────────────────────────────────────────────────────────
@HybridRecord
class AppSettings {
  String theme;
  bool darkMode;
  int maxRetries;
  double timeout;
  String locale;
}

// ── Config module spec ─────────────────────────────────────────────────────────
@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Config extends HybridObject {
  static final Config instance = _ConfigImpl();

  // ── Typed settings (binary-encoded @HybridRecord) ─────────────────────────
  AppSettings getSettings();
  Future<void> applySettings(AppSettings settings);
  Future<AppSettings> mergeSettings(AppSettings base, AppSettings overlay);

  // ── Heterogeneous raw config (NitroAnyMap for dynamic keys) ───────────────
  NitroAnyMap getAll();
  Future<void> putAll(NitroAnyMap map);
  Future<NitroAnyMap> query(NitroAnyMap filter);

  // ── Mixed: build typed config from heterogeneous map ──────────────────────
  Future<AppSettings> fromMap(NitroAnyMap raw);
  NitroAnyMap toMap(AppSettings settings);

  // ── Properties ────────────────────────────────────────────────────────────
  String get currentLocale;
  bool get isDarkMode;
  int get version;

  // ── Stream: config change notifications ───────────────────────────────────
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<String> get changes;
}
