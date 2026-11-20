// Compiles generated C++ bridges with a real compiler.
//
// Generator unit tests assert on emitted text, which cannot catch "this does not
// build" — issue #40 shipped exactly that: JNI code emitted into a JNI-free
// bridge, textually fine, uncompilable for Android. This closes that gap.
//
//   dart run tool/verify_cpp_bridge_compiles.dart
import 'dart:io';

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_impl_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';

/// All-cpp module with a @zeroCopy struct field — the issue #40 repro.
BridgeSpec _zeroCopyCppSpec() => BridgeSpec(
  dartClassName: 'Repro',
  lib: 'repro',
  namespace: 'repro',
  iosImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'repro.native.dart',
  structs: [
    BridgeStruct(
      name: 'Chunk',
      packed: false,
      fields: [
        BridgeField(name: 'bytes', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
        BridgeField(name: 'requestId', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'chunks',
      registerSymbol: 'repro_register_chunks_stream',
      releaseSymbol: 'repro_release_chunks_stream',
      itemType: BridgeType(name: 'Chunk'),
      backpressure: Backpressure.bufferDrop,
    ),
  ],
  functions: [],
);

/// Web-targeting all-cpp module with a stream + native-async — exercises the
/// __EMSCRIPTEN__ seam (nitro_wasm_compat.h include, post-fn setter, posts
/// routed through the compat shim). Compiled with em++ when emsdk is on PATH.
///
/// The record with a typed-data field and the @zeroCopy return make the bridge
/// emit both adopt exports (finalizable handles), which must compile natively
/// and stay out of the wasm build.
BridgeSpec _webWasmSpec() => BridgeSpec(
  dartClassName: 'WebRepro',
  lib: 'web_repro',
  namespace: 'web_repro',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  webImpl: NativeImpl.wasm,
  sourceUri: 'web_repro.native.dart',
  structs: [
    BridgeStruct(
      name: 'Chunk',
      packed: false,
      fields: [
        BridgeField(name: 'bytes', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
        BridgeField(name: 'requestId', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'chunks',
      registerSymbol: 'web_repro_register_chunks_stream',
      releaseSymbol: 'web_repro_release_chunks_stream',
      itemType: BridgeType(name: 'Chunk'),
      backpressure: Backpressure.bufferDrop,
    ),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Blob',
      fields: [BridgeRecordField(name: 'bytes', dartType: 'Uint8List', kind: RecordFieldKind.typedData)],
    ),
  ],
  functions: [
    // @NitroResult on web: a value with its own encoding, and a wrapped one
    // (BridgeSpec.resultWrapper), through the same all-C++ bridge under em++.
    BridgeFunction(
      dartName: 'tryCount',
      cSymbol: 'web_repro_try_count',
      isAsync: false,
      isResult: true,
      returnType: BridgeType(name: 'int'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'tryBytes',
      cSymbol: 'web_repro_try_bytes',
      isAsync: false,
      isResult: true,
      returnType: BridgeType(name: 'Uint8List?', isNullable: true),
      resultField: BridgeRecordField(name: 'value', dartType: 'Uint8List?', kind: RecordFieldKind.typedData, isNullable: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'echoAsync',
      cSymbol: 'web_repro_echo_async',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'int'))],
    ),
    BridgeFunction(
      dartName: 'blob',
      cSymbol: 'web_repro_blob',
      isAsync: false,
      returnType: BridgeType(name: 'Blob', isRecord: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'snapshot',
      cSymbol: 'web_repro_snapshot',
      isAsync: false,
      returnType: BridgeType(name: 'Uint8List'),
      zeroCopyReturn: true,
      params: [],
    ),
  ],
);

/// Records whose list fields are nullable. The C++ codec has to emplace into a
/// `std::optional<std::vector<T>>` and bracket it with a null tag; getting the
/// accessor wrong (`.size()` on an optional) is a compile error that emitted-text
/// assertions cannot see.
BridgeSpec _nullableListFieldsSpec() => BridgeSpec(
  dartClassName: 'ListRepro',
  lib: 'list_repro',
  namespace: 'list_repro',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'list_repro.native.dart',
  enums: [
    BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'high']),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'Inner',
      fields: [BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive)],
    ),
    BridgeRecordType(
      name: 'Outer',
      fields: [
        BridgeRecordField(
          name: 'tags',
          dartType: 'List<int>?',
          kind: RecordFieldKind.listPrimitive,
          itemTypeName: 'int',
          isNullable: true,
        ),
        BridgeRecordField(
          name: 'levels',
          dartType: 'List<Level>?',
          kind: RecordFieldKind.listEnumValue,
          itemTypeName: 'Level',
          isNullable: true,
        ),
        BridgeRecordField(
          name: 'items',
          dartType: 'List<Inner>?',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Inner',
          isNullable: true,
        ),
        // Non-nullable siblings must keep compiling unchanged.
        BridgeRecordField(
          name: 'required',
          dartType: 'List<Inner>',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Inner',
        ),
        BridgeRecordField(name: 'trailing', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'echoOuter',
      cSymbol: 'list_repro_echo_outer',
      isAsync: false,
      returnType: BridgeType(name: 'Outer', isRecord: true),
      params: [BridgeParam(name: 'v', type: BridgeType(name: 'Outer', isRecord: true))],
    ),
  ],
);

/// Kotlin/Swift on mobile, C++ on desktop, with a @NitroResult method and a
/// record return. The Windows/Linux dispatch block is the one place generated
/// code builds a result blob from a NitroRecordWriter, and it is only compiled
/// when the host is one of those (the Linux CI job): it once read a writer
/// member that had been removed, and every text-level test still passed.
BridgeSpec _desktopResultSpec() => BridgeSpec(
  dartClassName: 'Desk',
  lib: 'desk',
  namespace: 'desk',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  macosImpl: NativeImpl.swift,
  windowsImpl: NativeImpl.cpp,
  linuxImpl: NativeImpl.cpp,
  sourceUri: 'desk.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Reply',
      fields: [
        BridgeRecordField(name: 'status', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'body', dartType: 'Uint8List', kind: RecordFieldKind.typedData),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetch',
      cSymbol: 'desk_fetch',
      isAsync: false,
      returnType: BridgeType(name: 'Reply', isRecord: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'tryCount',
      cSymbol: 'desk_try_count',
      isAsync: false,
      isResult: true,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'code', type: BridgeType(name: 'int'))],
    ),
    // A wrapped value (BridgeSpec.resultWrapper) through the same dispatch block.
    BridgeFunction(
      dartName: 'tryList',
      cSymbol: 'desk_try_list',
      isAsync: false,
      isResult: true,
      returnType: BridgeType(name: 'List<int>?', isRecord: true, isNullable: true),
      resultField: BridgeRecordField(name: 'value', dartType: 'List<int>?', kind: RecordFieldKind.listPrimitive, itemTypeName: 'int', isNullable: true),
      params: [BridgeParam(name: 'code', type: BridgeType(name: 'int'))],
    ),
  ],
);

/// C++ on every platform, with a @NitroResult method of every kind of value,
/// sync and @nitroAsync: the ones with a result encoding of their own, and the
/// ones that travel as a one-field record (BridgeSpec.resultWrapper) — a
/// nullable value, a list, typed data, a struct. The all-C++ bridge once
/// defined result methods with the plain return type against a header that
/// declares the result blob (`conflicting types`), and no spec in the suite
/// was compiled in that shape.
BridgeSpec _allCppResultSpec() {
  BridgeFunction result(String name, String type, RecordFieldKind kind, {String? item, bool isRecord = false, bool isAsync = false}) => BridgeFunction(
    dartName: name,
    cSymbol: 'res_$name',
    isAsync: isAsync,
    isResult: true,
    returnType: BridgeType(name: type, isRecord: isRecord, isNullable: type.endsWith('?'), isFuture: isAsync),
    resultField: BridgeRecordField(name: 'value', dartType: type, kind: kind, itemTypeName: item, isNullable: type.endsWith('?')),
    params: [BridgeParam(name: 'code', type: BridgeType(name: 'int'))],
  );
  BridgeFunction block(String name, String type, {bool isMap = false, bool isAnyMap = false, bool isVariantList = false}) => BridgeFunction(
    dartName: name,
    cSymbol: 'res_$name',
    isAsync: false,
    isResult: true,
    returnType: BridgeType(
      name: type,
      // As the extractor types it: an any-map is not a record.
      isRecord: !isAnyMap,
      isNullable: type.endsWith('?'),
      isMap: isMap,
      isAnyMap: isAnyMap,
      isVariantList: isVariantList,
      recordListItemType: isVariantList ? 'Event' : null,
    ),
    resultField: BridgeRecordField(name: 'value', dartType: type, kind: RecordFieldKind.primitive, isNullable: type.endsWith('?')),
    params: [BridgeParam(name: 'code', type: BridgeType(name: 'int'))],
  );
  return BridgeSpec(
    dartClassName: 'Res',
    lib: 'res',
    namespace: 'res',
    androidImpl: NativeImpl.cpp,
    iosImpl: NativeImpl.cpp,
    macosImpl: NativeImpl.cpp,
    windowsImpl: NativeImpl.cpp,
    linuxImpl: NativeImpl.cpp,
    sourceUri: 'res.native.dart',
    variants: [
      BridgeVariant(
        name: 'Event',
        cases: [
          BridgeVariantCase(
            name: 'EventTap',
            label: 'tap',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
              BridgeRecordField(name: 'label', dartType: 'String', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
      ),
    ],
    enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b'])],
    structs: [
      BridgeStruct(
        name: 'Pt',
        packed: false,
        fields: [
          BridgeField(name: 'x', type: BridgeType(name: 'double')),
          BridgeField(name: 'n', type: BridgeType(name: 'int')),
        ],
      ),
    ],
    recordTypes: [
      BridgeRecordType(
        name: 'Reply',
        fields: [
          BridgeRecordField(name: 'status', dartType: 'int', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'text', dartType: 'String', kind: RecordFieldKind.primitive),
        ],
      ),
    ],
    functions: [
      // Own encoding.
      result('count', 'int', RecordFieldKind.primitive),
      result('ratio', 'double', RecordFieldKind.primitive),
      result('flag', 'bool', RecordFieldKind.primitive),
      result('name', 'String', RecordFieldKind.primitive),
      result('mode', 'Mode', RecordFieldKind.enumValue),
      result('reply', 'Reply', RecordFieldKind.recordObject, isRecord: true),
      result('later', 'int', RecordFieldKind.primitive, isAsync: true),
      // Wrapped.
      result('optInt', 'int?', RecordFieldKind.primitive),
      result('optText', 'String?', RecordFieldKind.primitive),
      result('optMode', 'Mode?', RecordFieldKind.enumValue),
      result('optReply', 'Reply?', RecordFieldKind.recordObject, isRecord: true),
      result('ints', 'List<int>', RecordFieldKind.listPrimitive, item: 'int', isRecord: true),
      result('texts', 'List<String>', RecordFieldKind.listPrimitive, item: 'String', isRecord: true),
      result('flags', 'List<bool>', RecordFieldKind.listPrimitive, item: 'bool', isRecord: true),
      result('modes', 'List<Mode>', RecordFieldKind.listEnumValue, item: 'Mode', isRecord: true),
      result('replies', 'List<Reply>', RecordFieldKind.listRecordObject, item: 'Reply', isRecord: true),
      result('bytes', 'Uint8List', RecordFieldKind.typedData),
      result('floats', 'Float32List', RecordFieldKind.typedData),
      result('point', 'Pt', RecordFieldKind.struct),
      result('optPoint', 'Pt?', RecordFieldKind.struct),
      result('optInts', 'List<int>?', RecordFieldKind.listPrimitive, item: 'int', isRecord: true),
      result('laterInts', 'List<int>', RecordFieldKind.listPrimitive, item: 'int', isRecord: true, isAsync: true),
      // Wrapped as an int64.
      result('at', 'DateTime', RecordFieldKind.primitive),
      result('optAt', 'DateTime?', RecordFieldKind.primitive),
      result('big', 'uint64', RecordFieldKind.primitive),
      result('optBig', 'uint64?', RecordFieldKind.primitive),
      // Self-describing blocks, passed through behind the tag.
      block('event', 'Event'),
      block('optEvent', 'Event?'),
      block('events', 'List<Event>', isVariantList: true),
      block('table', 'Map<String, int>', isMap: true),
      block('optTable', 'Map<String, int>?', isMap: true),
      block('any', 'NitroAnyMap', isAnyMap: true),
    ],
  );
}

/// Maps in every position: a map return with no map parameter, two maps on one
/// method, nullable maps both ways, and any-maps. A plain `NitroAnyMap` return
/// did not compile on C++ (the interface's `void*` against the C `uint8_t*`),
/// and JNI read the length of a null map through the null pointer.
BridgeSpec _mapShapesSpec({required bool allCpp}) {
  BridgeType map(String value, {bool nullable = false}) => BridgeType(name: 'Map<String, $value>${nullable ? '?' : ''}', isRecord: true, isMap: true, isNullable: nullable);
  BridgeType anyMap({bool nullable = false}) => BridgeType(name: 'NitroAnyMap${nullable ? '?' : ''}', isAnyMap: true, isNullable: nullable);
  final int64 = BridgeType(name: 'int');
  BridgeFunction fn(String name, BridgeType ret, Map<String, BridgeType> params, {bool isAsync = false, bool isNativeAsync = false}) => BridgeFunction(
    dartName: name,
    cSymbol: 'shapes_$name',
    isAsync: isAsync,
    isNativeAsync: isNativeAsync,
    returnType: ret,
    params: [for (final MapEntry(:key, :value) in params.entries) BridgeParam(name: key, type: value)],
  );
  final mobile = allCpp ? NativeImpl.cpp : null;
  return BridgeSpec(
    dartClassName: 'Shapes',
    lib: 'shapes',
    namespace: 'shapes',
    androidImpl: mobile ?? NativeImpl.kotlin,
    iosImpl: mobile ?? NativeImpl.swift,
    macosImpl: mobile ?? NativeImpl.swift,
    windowsImpl: NativeImpl.cpp,
    linuxImpl: NativeImpl.cpp,
    sourceUri: 'shapes.native.dart',
    functions: [
      fn('make', map('int'), {'n': int64}),
      fn('sum', int64, {'values': map('int'), 'bias': int64}),
      fn('merge', map('String'), {'a': map('String'), 'sep': BridgeType(name: 'String'), 'b': map('String')}),
      fn('orNull', map('int', nullable: true), {'n': int64}),
      fn('size', int64, {'values': map('int', nullable: true)}),
      fn('anyOf', anyMap(), {'n': int64}),
      fn('anySize', int64, {'bias': int64, 'm': anyMap()}),
      fn('anyOrNull', anyMap(nullable: true), {'m': anyMap(nullable: true)}),
      fn('makeLater', BridgeType(name: 'Map<String, int>', isRecord: true, isMap: true, isFuture: true), {'n': int64}, isAsync: true),
      fn('sumNative', BridgeType(name: 'int', isFuture: true), {'bias': int64, 'values': map('int?')}, isNativeAsync: true),
    ],
  );
}

/// Typed data returned without `@zeroCopy`: the impl returns a vector (an
/// optional one when nullable) and the bridge copies it.
BridgeSpec _typedDataReturnSpec({required bool allCpp}) {
  final int64 = BridgeType(name: 'int');
  BridgeFunction fn(String name, String type, {bool isAsync = false, bool isNativeAsync = false, List<BridgeParam> params = const []}) => BridgeFunction(
    dartName: name,
    cSymbol: 'td_$name',
    isAsync: isAsync,
    isNativeAsync: isNativeAsync,
    returnType: BridgeType(name: type, isNullable: type.endsWith('?'), isFuture: isAsync || isNativeAsync),
    params: params.isEmpty ? [BridgeParam(name: 'n', type: int64)] : params,
  );
  final mobile = allCpp ? NativeImpl.cpp : null;
  return BridgeSpec(
    dartClassName: 'Td',
    lib: 'td',
    namespace: 'td',
    androidImpl: mobile ?? NativeImpl.kotlin,
    iosImpl: mobile ?? NativeImpl.swift,
    macosImpl: mobile ?? NativeImpl.swift,
    windowsImpl: NativeImpl.cpp,
    linuxImpl: NativeImpl.cpp,
    sourceUri: 'td.native.dart',
    functions: [
      for (final t in ['Uint8List', 'Int8List', 'Int16List', 'Uint16List', 'Int32List', 'Uint32List', 'Float32List', 'Float64List', 'Int64List', 'Uint64List']) fn('of$t', t),
      fn('bytesOrNull', 'Uint8List?'),
      fn('doublesOrNull', 'Float64List?'),
      fn('reverse', 'Uint8List', params: [BridgeParam(name: 'value', type: BridgeType(name: 'Uint8List'))]),
      fn('later', 'Float32List?', isAsync: true),
      fn('posted', 'Int32List?', isNativeAsync: true),
    ],
  );
}

/// Callbacks whose real ABI is not their declared C type: a double crosses as
/// int64 bits, a record or struct return as a malloc'd block. The all-C++
/// path once handed the raw pointer straight to `std::function`, which either
/// converted by value or did not compile; it now uses the mixed-module adapter.
/// Also: `Map<String, @HybridStruct>`.
BridgeSpec _callbackAndStructSpec({required bool allCpp}) {
  BridgeType fnType(String ret, List<String> params) =>
      BridgeType(name: '$ret Function(${params.join(', ')})', isFunction: true, functionReturnType: ret, functionParams: [for (final p in params) BridgeType(name: p)]);
  BridgeFunction taking(String name, BridgeType callback) => BridgeFunction(
    dartName: name,
    cSymbol: 'cb_$name',
    isAsync: false,
    returnType: BridgeType(name: 'double'),
    params: [BridgeParam(name: 'callback', type: callback), BridgeParam(name: 'n', type: BridgeType(name: 'int'))],
  );
  final pointMap = BridgeType(name: 'Map<String, Point>', isRecord: true, isMap: true);
  final mobile = allCpp ? NativeImpl.cpp : null;
  return BridgeSpec(
    dartClassName: 'Cb',
    lib: 'cb',
    namespace: 'cb',
    androidImpl: mobile ?? NativeImpl.kotlin,
    iosImpl: mobile ?? NativeImpl.swift,
    macosImpl: mobile ?? NativeImpl.swift,
    windowsImpl: NativeImpl.cpp,
    linuxImpl: NativeImpl.cpp,
    // The web adapter has its own ABI (natural types, pointer returns).
    webImpl: allCpp ? NativeImpl.wasm : null,
    sourceUri: 'cb.native.dart',
    enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b'])],
    structs: [
      BridgeStruct(
        name: 'Point',
        packed: false,
        fields: [
          BridgeField(name: 'x', type: BridgeType(name: 'double'), isNamed: true),
          BridgeField(name: 'id', type: BridgeType(name: 'int'), isNamed: true),
          BridgeField(name: 'on', type: BridgeType(name: 'bool'), isNamed: true),
          BridgeField(name: 'label', type: BridgeType(name: 'String'), isNamed: true),
        ],
      ),
    ],
    recordTypes: [
      BridgeRecordType(name: 'Config', fields: [BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive)]),
    ],
    functions: [
      taking('structFrom', fnType('Point', ['int'])),
      taking('recordFrom', fnType('Config', ['int'])),
      taking('doubleFrom', fnType('double', ['double', 'bool'])),
      taking('stringFrom', fnType('String', ['String'])),
      taking('enumFrom', fnType('Mode', ['Mode'])),
      taking('notify', fnType('void', ['int', 'double'])),
      BridgeFunction(dartName: 'echoPoints', cSymbol: 'cb_echoPoints', isAsync: false, returnType: pointMap, params: [BridgeParam(name: 'points', type: pointMap)]),
    ],
  );
}

// Dart ignores what main returns: the result has to go through [exitCode], or
// a failed compile leaves the CI step green.
Future<void> main() async {
  final cc = Platform.environment['CXX'] ?? 'clang++';
  final dartApiDl = Directory('benchmark/src/native').existsSync()
      ? 'benchmark/src/native'
      : '../../benchmark/src/native';

  final cases = <String, BridgeSpec>{
    'zero_copy_all_cpp (#40)': _zeroCopyCppSpec(),
    'web_wasm_all_cpp': _webWasmSpec(),
    'nullable_list_record_fields': _nullableListFieldsSpec(),
    'desktop_cpp_nitro_result': _desktopResultSpec(),
    'all_cpp_nitro_result': _allCppResultSpec(),
    'desktop_cpp_map_shapes': _mapShapesSpec(allCpp: false),
    'all_cpp_map_shapes': _mapShapesSpec(allCpp: true),
    'desktop_cpp_typed_data_returns': _typedDataReturnSpec(allCpp: false),
    'all_cpp_typed_data_returns': _typedDataReturnSpec(allCpp: true),
    'desktop_cpp_callbacks_and_struct_maps': _callbackAndStructSpec(allCpp: false),
    'all_cpp_callbacks_and_struct_maps': _callbackAndStructSpec(allCpp: true),
  };

  // em++ is optional locally, required in the web CI job (NITRO_REQUIRE_EMCC=1).
  final emcc = Process.runSync('sh', ['-c', 'command -v em++']).exitCode == 0;
  final requireEmcc = Platform.environment['NITRO_REQUIRE_EMCC'] == '1';
  if (!emcc && requireEmcc) {
    stderr.writeln('NITRO_REQUIRE_EMCC=1 but em++ is not on PATH');
    exitCode = 1;
    return;
  }
  final nitroNative = Directory('../nitro/src/native').existsSync()
      ? '../nitro/src/native'
      : 'packages/nitro/src/native';

  var failures = 0;
  for (final entry in cases.entries) {
    final dir = Directory.systemTemp.createTempSync('nitro_cc_');
    try {
      final spec = entry.value;
      File('${dir.path}/${spec.lib}.bridge.g.h').writeAsStringSync(CppHeaderGenerator.generate(spec));
      File('${dir.path}/${spec.lib}.native.g.h').writeAsStringSync(CppInterfaceGenerator.generate(spec));
      final src = File('${dir.path}/${spec.lib}.bridge.g.cpp')
        ..writeAsStringSync(CppBridgeGenerator.generate(spec));

      // No -I for jni.h: an all-cpp bridge must not need it. Android defines
      // __ANDROID__, so compile with it set to reach any guarded block.
      // A Kotlin/Swift module's mobile blocks need jni.h or Foundation; only
      // its desktop block compiles here, and only a Linux host selects it.
      // NITRO_CXX_TARGETS_DESKTOP=1 says $CXX is a cross compiler for Linux
      // or Windows (MinGW), which selects the block from any host.
      final desktopBlockOnly = spec.androidImpl != NativeImpl.cpp;
      final desktopCompiler = Platform.isLinux || Platform.environment['NITRO_CXX_TARGETS_DESKTOP'] == '1';
      if (desktopBlockOnly && !desktopCompiler) {
        stdout.writeln('SKIP  ${entry.key} (desktop block needs a Linux host)');
        continue;
      }
      final r = Process.runSync(cc, [
        '-fsyntax-only', '-std=c++17', if (!desktopBlockOnly) '-D__ANDROID__',
        '-I', dir.path, '-I', dartApiDl, src.path,
      ]);
      if (r.exitCode == 0) {
        stdout.writeln('PASS  ${entry.key}');
      } else {
        failures++;
        stdout.writeln('FAIL  ${entry.key}\n${r.stderr}');
      }

      // The starter implementation overrides the interface: a signature that
      // drifted from it (a wrapped result, an optional, a native-async method)
      // is a compile error in the file a new plugin starts from.
      final starter = File('${dir.path}/${spec.lib}.impl.g.cpp')..writeAsStringSync(CppImplGenerator.generate(spec));
      final st = Process.runSync(cc, ['-fsyntax-only', '-std=c++17', '-I', dir.path, '-I', dartApiDl, starter.path]);
      if (st.exitCode == 0) {
        stdout.writeln('PASS  ${entry.key} (starter impl)');
      } else {
        failures++;
        stdout.writeln('FAIL  ${entry.key} (starter impl)\n${st.stderr}');
      }

      // Web seam: compile the same bridge with em++ (defines __EMSCRIPTEN__).
      if (spec.webIsWasm && emcc) {
        final w = Process.runSync('em++', [
          '-fsyntax-only', '-std=c++17',
          '-I', dir.path, '-I', nitroNative, src.path,
        ]);
        if (w.exitCode == 0) {
          stdout.writeln('PASS  ${entry.key} (em++)');
        } else {
          failures++;
          stdout.writeln('FAIL  ${entry.key} (em++)\n${w.stderr}');
        }
      } else if (spec.webIsWasm) {
        stdout.writeln('SKIP  ${entry.key} (em++ not on PATH)');
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
  stdout.writeln(failures == 0 ? '\nall bridges compile' : '\n$failures bridge(s) failed to compile');
  exitCode = failures == 0 ? 0 : 1;
}
