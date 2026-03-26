import 'package:flutter/material.dart';

enum BridgeType { nitro, rawFfi, methodChannel }

extension BridgeTypeExt on BridgeType {
  String get label {
    switch (this) {
      case BridgeType.nitro:
        return 'Nitro';
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
      case BridgeType.rawFfi:
        return Colors.green;
      case BridgeType.methodChannel:
        return Colors.red;
    }
  }
}
