part of '../spec_validator.dart';

// Which platforms the module targets, and what each target needs (missing
// implementations, advisory warnings).

extension _PlatformRules on _Rules {
  void platforms() {
    // ── Platform targeting ─────────────────────────────────────────────────
    if (spec.iosImpl == null && spec.androidImpl == null && spec.macosImpl == null && spec.windowsImpl == null && spec.linuxImpl == null && spec.webImpl == null) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'NO_TARGET_PLATFORM',
          message: '${spec.dartClassName}: at least one platform must be specified in @NitroModule.',
          hint:
              'Add one or more platform fields: `ios: NativeImpl.swift`, '
              '`android: NativeImpl.kotlin`, `macos: NativeImpl.cpp`, '
              '`windows: NativeImpl.cpp`, `linux: NativeImpl.cpp`, '
              'or `web: NativeImpl.wasm`.',
        ),
      );
    }

    // Defensive platform impl checks. At the @NitroModule annotation level these
    // are compile-time errors (marker interfaces prevent invalid assignments).
    // The checks below guard against BridgeSpec being constructed directly.

    // macOS: only Swift or C++ — not Kotlin.
    if (spec.macosImpl is KotlinImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_MACOS_IMPL',
          message: '${spec.dartClassName}: macOS does not support NativeImpl.kotlin.',
          hint: 'Use `macos: NativeImpl.cpp` or `macos: NativeImpl.swift` instead.',
        ),
      );
    }

    // Windows: only C++.
    if (spec.windowsImpl != null && spec.windowsImpl is! CppImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_WINDOWS_IMPL',
          message: '${spec.dartClassName}: Windows only supports NativeImpl.cpp.',
          hint: 'Use `windows: NativeImpl.cpp` — Windows requires direct C++ via CMake/MSVC.',
        ),
      );
    }

    // Linux: only C++.
    if (spec.linuxImpl != null && spec.linuxImpl is! CppImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_LINUX_IMPL',
          message: '${spec.dartClassName}: Linux only supports NativeImpl.cpp.',
          hint: 'Use `linux: NativeImpl.cpp` — Linux requires direct C++ via CMake/GCC/Clang.',
        ),
      );
    }

    // Web: only WASM. This is the most critical check — CppImpl on web would
    // generate dart:ffi code that fails to compile for web targets.
    if (spec.webImpl != null && spec.webImpl is! WasmImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_WEB_IMPL',
          message: '${spec.dartClassName}: Web only supports NativeImpl.wasm.',
          hint:
              'Use `web: NativeImpl.wasm` — dart:ffi is unavailable on web. '
              'Web requires WASM/JS interop. Compile your C++ to WASM using Emscripten.',
        ),
      );
    }

    // ── D4: @HybridStruct String field advisory ───────────────────────────────
    // String fields are heap-copied (strdup/free) on every bridge call.
    // For structs with string-heavy fields, @HybridRecord is more efficient.
    for (final st in spec.structs) {
      final stringFields = st.fields.where((f) => f.type.name == 'String' || f.type.name == 'String?').toList();
      if (stringFields.isNotEmpty) {
        final names = stringFields.map((f) => f.name).join(', ');
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'STRUCT_STRING_FIELD',
            message: '${spec.dartClassName}: @HybridStruct "${st.name}" has String field(s): $names.',
            hint:
                'String fields are heap-copied (strdup/free) on every bridge call. '
                'If this struct is on a hot path or carries large strings, '
                'consider @HybridRecord instead — it encodes once and decodes lazily.',
          ),
        );
      }
    }

    // ── PX5 / D7: Missing-platform warnings ──────────────────────────────────
    // Advisory: warn when a module targets only one side of the mobile duopoly.
    // Pure-desktop (windows/linux) and pure-web plugins are not warned about
    // because they are valid single-platform configurations.
    final hasAppleTarget = spec.iosImpl != null || spec.macosImpl != null;
    final hasAndroidTarget = spec.androidImpl != null;
    final hasMobileTarget = hasAppleTarget || hasAndroidTarget;
    if (hasMobileTarget && hasAppleTarget && !hasAndroidTarget) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          code: 'MISSING_ANDROID_TARGET',
          message: '${spec.dartClassName}: iOS/macOS is targeted but Android is not.',
          hint:
              'Add `android: NativeImpl.kotlin` (or `.cpp`) to target Android. '
              'If Android is intentionally excluded, ignore this warning: it is advisory only.',
        ),
      );
    }
    if (hasMobileTarget && hasAndroidTarget && !hasAppleTarget) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          code: 'MISSING_IOS_TARGET',
          message: '${spec.dartClassName}: Android is targeted but iOS/macOS is not.',
          hint:
              'Add `ios: NativeImpl.swift` (or `.cpp`) to target Apple platforms. '
              'If iOS is intentionally excluded, ignore this warning: it is advisory only.',
        ),
      );
    }

    // W007 (retired in 0.7.0): streams and @NitroNativeAsync are fully
    // supported on web — completions arrive through the module post callback.
    //
    // Web-specific capability checks that remain:
    if (spec.webImpl != null) {
      // W008: @nitroAsync runs on the main thread on web (no isolates) — a
      // long-running native call will jank the UI.
      if (spec.functions.any((f) => f.isAsync)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W008',
            message:
                '${spec.dartClassName}: @nitroAsync method(s) run INLINE on the main thread '
                'on web (browsers have no isolates). Long-running native work will jank the UI.',
            hint: 'Prefer @nitroNativeAsync for genuinely asynchronous native work — its completion is posted through the module callback.',
          ),
        );
      }
      // W009: @zeroCopy on web is a single bulk copy (snapshot semantics) —
      // heap views detach on memory growth, so a live view cannot be lent.
      if (spec.functions.any((f) => f.zeroCopyReturn)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W009',
            message: '${spec.dartClassName}: @zeroCopy return(s) are ONE bulk copy on web (snapshot) — WASM heap views detach when the module memory grows.',
            hint: 'Semantics are identical; only the zero-copy performance property differs on web.',
          ),
        );
      }
      // E017: catch-all for struct field kinds the web layout cannot place
      // (records, variants, maps). Prims, enums, DateTime, String, TypedData
      // and nested structs are supported.
      for (final st in spec.structs) {
        final unsupported = st.fields.where((f) {
          final base = bareTypeName(f.type.name);
          // Mirrors _fieldSlot in web_bridge_generator.dart — keep in sync.
          if (spec.isEnumName(base) || spec.isStructName(base) || f.type.isTypedData) return false;
          if (base == 'String') return false;
          return base != 'int' && base != 'uint64' && base != 'double' && base != 'bool' && base != 'DateTime';
        }).toList();
        if (unsupported.isNotEmpty) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E017',
              message:
                  '${spec.dartClassName}: @HybridStruct ${st.name} has field(s) '
                  '${unsupported.map((f) => f.name).join(', ')} of a type that has no wasm32 struct layout on web.',
              hint: 'Use an @HybridRecord instead (framed binary — full type support on web), or keep the struct off web-targeting specs.',
            ),
          );
        }
      }
    }
  }
}
