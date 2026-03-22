import 'package:nitro/nitro.dart';

class BridgeSpec {
  final String dartClassName;
  final String lib;
  final String namespace;
  final NativeImpl iosImpl;
  final NativeImpl androidImpl;
  final String sourceUri;

  final List<BridgeStruct> structs;
  final List<BridgeEnum> enums;
  final List<BridgeFunction> functions;
  final List<BridgeStream> streams;
  final List<BridgeProperty> properties;

  BridgeSpec({
    required this.dartClassName,
    required this.lib,
    required this.namespace,
    required this.iosImpl,
    required this.androidImpl,
    required this.sourceUri,
    this.structs = const [],
    this.enums = const [],
    this.functions = const [],
    this.streams = const [],
    this.properties = const [],
  });
}

class BridgeType {
  final String name;
  final bool isNullable;
  final bool isFuture;
  final bool isStream;

  BridgeType({
    required this.name,
    this.isNullable = false,
    this.isFuture = false,
    this.isStream = false,
  });
}

class BridgeStruct {
  final String name;
  final bool packed;
  final List<BridgeField> fields;

  BridgeStruct({
    required this.name,
    required this.packed,
    required this.fields,
  });
}

class BridgeField {
  final String name;
  final BridgeType type;
  final bool zeroCopy;

  BridgeField({
    required this.name,
    required this.type,
    this.zeroCopy = false,
  });
}

class BridgeEnum {
  final String name;
  final int startValue;
  final List<String> values;

  BridgeEnum({
    required this.name,
    required this.startValue,
    required this.values,
  });
}

class BridgeFunction {
  final String dartName;
  final String cSymbol;
  final bool isAsync;
  final BridgeType returnType;
  final List<BridgeParam> params;

  BridgeFunction({
    required this.dartName,
    required this.cSymbol,
    required this.isAsync,
    required this.returnType,
    required this.params,
  });
}

class BridgeParam {
  final String name;
  final BridgeType type;
  final bool zeroCopy;

  BridgeParam({
    required this.name,
    required this.type,
    this.zeroCopy = false,
  });
}

class BridgeStream {
  final String dartName;
  final String registerSymbol;
  final String releaseSymbol;
  final BridgeType itemType;
  final Backpressure backpressure;

  BridgeStream({
    required this.dartName,
    required this.registerSymbol,
    required this.releaseSymbol,
    required this.itemType,
    required this.backpressure,
  });
}

class BridgeProperty {
  final String dartName;
  final BridgeType type;
  final String? getSymbol;
  final String? setSymbol;
  final bool hasGetter;
  final bool hasSetter;

  BridgeProperty({
    required this.dartName,
    required this.type,
    this.getSymbol,
    this.setSymbol,
    this.hasGetter = true,
    this.hasSetter = false,
  });
}
