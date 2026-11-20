part of '../spec_extractor.dart';

// Which implementation language each platform of a `@NitroModule` uses.

NativeImpl _getNativeImpl(
  DartObject object, {
  String? fieldName,
  String? sourcePath,
}) {
  // Reconstruct by runtime type name — robust against class reordering.
  // Each NativeImpl subclass (SwiftImpl, KotlinImpl, CppImpl, WasmImpl) has a
  // unique name that the analyzer preserves in the DartObject type element.
  //
  // Per-platform sealed class constants (e.g. AppleNativeImpl.swift) share
  // the same compile-time objects as NativeImpl.* — they are identical Dart
  // const values. The analyzer should return the concrete type (SwiftImpl,
  // CppImpl, etc.) rather than the sealed class type. The platform-type
  // entries below act as a safety-net in case a future analyzer version
  // returns the declared type of the constant instead of its value type.
  final typeName = object.type?.element?.name;

  // Fast path: unambiguous names handled by the shared helper in
  // nitro_annotations. Keeps the mapping co-located with the annotations so
  // any tool (nitrogen_cli, docs generator) can reuse it.
  final shared = NativeImpl.fromTypeName(typeName);
  if (shared != null) return shared;

  // Slow path: ambiguous sealed markers require analyzer-level supertype
  // inspection to pick between the language-specific impl and CppImpl.
  switch (typeName) {
    case 'AppleNativeImpl':
      if (fieldName == 'ios' || fieldName == 'macos') {
        return _inferAppleImpl(object);
      }
      throw InvalidGenerationSource(
        'Cannot infer AppleNativeImpl kind for field "$fieldName"'
        '${sourcePath != null ? " in $sourcePath" : ""}. '
        'Use AppleNativeImpl.swift or AppleNativeImpl.cpp explicitly.',
      );
    case 'AndroidNativeImpl':
      return _inferAndroidImpl(object);
  }
  throw InvalidGenerationSource(
    'Unknown NativeImpl subclass: "$typeName" '
    '(field: "${fieldName ?? '<unknown>'}"'
    '${sourcePath != null ? ", source: $sourcePath" : ""}). '
    'Use AppleNativeImpl.swift/.cpp, AndroidNativeImpl.kotlin/.cpp, '
    'WindowsNativeImpl.cpp, LinuxNativeImpl.cpp, WebNativeImpl.wasm, '
    'or the NativeImpl.* shorthands.',
  );
}

/// Disambiguates [AppleNativeImpl] by inspecting the constant's supertype
/// chain for [SwiftImpl] vs [CppImpl].
NativeImpl _inferAppleImpl(DartObject object) {
  final element = object.type?.element;
  final names = (element is InterfaceElement) ? element.allSupertypes.map((t) => t.element.name).whereType<String>().toSet() : <String>{};
  if (names.contains('SwiftImpl')) return NativeImpl.swift;
  if (names.contains('CppImpl')) return NativeImpl.cpp;
  throw InvalidGenerationSource(
    'Cannot determine AppleNativeImpl kind from type hierarchy. '
    'Use AppleNativeImpl.swift or AppleNativeImpl.cpp.',
  );
}

/// Disambiguates [AndroidNativeImpl] by inspecting the constant's supertype
/// chain for [KotlinImpl] vs [CppImpl].
NativeImpl _inferAndroidImpl(DartObject object) {
  final element = object.type?.element;
  final names = (element is InterfaceElement) ? element.allSupertypes.map((t) => t.element.name).whereType<String>().toSet() : <String>{};
  if (names.contains('KotlinImpl')) return NativeImpl.kotlin;
  if (names.contains('CppImpl')) return NativeImpl.cpp;
  throw InvalidGenerationSource(
    'Cannot determine AndroidNativeImpl kind from type hierarchy. '
    'Use AndroidNativeImpl.kotlin or AndroidNativeImpl.cpp.',
  );
}
