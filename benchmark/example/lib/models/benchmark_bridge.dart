import 'package:flutter/material.dart';

/// All bridge types available for benchmarking.
/// The ordering here controls the iteration order in the benchmark loops.
enum BridgeType {
  /// Nitro Swift/Kotlin path — full JNI or @_cdecl overhead.
  nitro,

  /// Nitro C++ direct path — virtual dispatch, no JNI or Swift.
  nitroCpp,

  /// Nitro C++ path with zero-copy struct param + return.
  nitroCppStruct,

  /// Nitro C++ path, async Future returning a @HybridRecord.
  nitroCppAsync,

  /// Nitro C++ path with Leaf call + skipped safety checks.
  nitroLeaf,

  /// Raw Dart FFI — dlsym lookup, no Nitro layer.
  rawFfi,

  /// Flutter MethodChannel — Dart ↔ platform encoding + channel overhead.
  methodChannel,
}

extension BridgeTypeExt on BridgeType {
  String get label {
    switch (this) {
      case BridgeType.nitro:
        return 'Nitro (Swift/Kotlin)';
      case BridgeType.nitroCpp:
        return 'Nitro (Direct C++)';
      case BridgeType.nitroCppStruct:
        return 'Nitro (C++ Struct)';
      case BridgeType.nitroCppAsync:
        return 'Nitro (C++ Async)';
      case BridgeType.nitroLeaf:
        return 'Nitro (Leaf Call)';
      case BridgeType.rawFfi:
        return 'Raw FFI';
      case BridgeType.methodChannel:
        return 'MethodChannel';
    }
  }

  Color get color {
    switch (this) {
      case BridgeType.nitro:
        return Colors.deepPurple;
      case BridgeType.nitroCpp:
        return Colors.cyan;
      case BridgeType.nitroCppStruct:
        return Colors.teal;
      case BridgeType.nitroCppAsync:
        return Colors.lightBlue;
      case BridgeType.nitroLeaf:
        return Colors.orange;
      case BridgeType.rawFfi:
        return Colors.green;
      case BridgeType.methodChannel:
        return Colors.red;
    }
  }

  /// Whether this bridge type is a C++ direct path variant.
  bool get isCppPath =>
      this == BridgeType.nitroCpp ||
      this == BridgeType.nitroCppStruct ||
      this == BridgeType.nitroCppAsync ||
      this == BridgeType.nitroLeaf;
}
