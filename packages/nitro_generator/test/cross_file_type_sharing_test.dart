import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/enum_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:nitro_generator/src/generators/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

BridgeSpec _typeOnlySpec({
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
  List<BridgeRecordType> records = const [],
}) =>
    BridgeSpec(
      dartClassName: '',
      lib: 'my_types',
      namespace: '',
      sourceUri: 'my_types.native.dart',
      enums: enums,
      structs: structs,
      recordTypes: records,
      isTypeOnly: true,
    );

BridgeSpec _moduleSpecWithImported({
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
  List<BridgeRecordType> records = const [],
  List<String> importedTypeFiles = const [],
}) =>
    BridgeSpec(
      dartClassName: 'Cam',
      lib: 'cam',
      namespace: 'cam',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'cam.native.dart',
      enums: enums,
      structs: structs,
      recordTypes: records,
      importedTypeFiles: importedTypeFiles,
      functions: [
        BridgeFunction(
          dartName: 'getStatus',
          cSymbol: 'cam_get_status',
          isAsync: false,
          returnType: BridgeType(name: 'int'),
          params: [],
        ),
      ],
    );

// ── Type-only spec: isTypeOnly flag ──────────────────────────────────────────

void main() {
  group('BridgeSpec — type-only support', () {
    test('isTypeOnly is false by default', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        sourceUri: 'mod.native.dart',
      );
      expect(spec.isTypeOnly, isFalse);
    });

    test('isTypeOnly is true when set', () {
      final spec = _typeOnlySpec(
        enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
      );
      expect(spec.isTypeOnly, isTrue);
    });
  });

  // ── localEnums / localStructs / localRecordTypes filtering ───────────────

  group('BridgeSpec — localXxx filtering', () {
    final localEnum = BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high']);
    final importedEnum = BridgeEnum(name: 'Priority', startValue: 0, values: ['normal', 'high'], isImported: true);

    final localStruct = BridgeStruct(name: 'Frame', packed: false, fields: []);
    final importedStruct = BridgeStruct(name: 'Config', packed: false, fields: [], isImported: true);

    final localRecord = BridgeRecordType(name: 'Result', fields: []);
    final importedRecord = BridgeRecordType(name: 'Settings', fields: [], isImported: true);

    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      sourceUri: 'mod.native.dart',
      enums: [localEnum, importedEnum],
      structs: [localStruct, importedStruct],
      recordTypes: [localRecord, importedRecord],
    );

    test('localEnums excludes imported enums', () {
      expect(spec.localEnums, hasLength(1));
      expect(spec.localEnums.first.name, 'Quality');
    });

    test('enums (full list) includes both local and imported', () {
      expect(spec.enums, hasLength(2));
    });

    test('localStructs excludes imported structs', () {
      expect(spec.localStructs, hasLength(1));
      expect(spec.localStructs.first.name, 'Frame');
    });

    test('localRecordTypes excludes imported records', () {
      expect(spec.localRecordTypes, hasLength(1));
      expect(spec.localRecordTypes.first.name, 'Result');
    });
  });

  // ── importedTypeFiles ─────────────────────────────────────────────────────

  group('BridgeSpec — importedTypeFiles', () {
    test('importedTypeFiles defaults to empty list', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        sourceUri: 'mod.native.dart',
      );
      expect(spec.importedTypeFiles, isEmpty);
    });

    test('importedTypeFiles is stored correctly', () {
      final spec = _moduleSpecWithImported(importedTypeFiles: ['my_types.bridge.g.h', '../other/generated/cpp/other.bridge.g.h']);
      expect(spec.importedTypeFiles, hasLength(2));
      expect(spec.importedTypeFiles.first, 'my_types.bridge.g.h');
    });
  });

  // ── DartFfiGenerator — type-only files ───────────────────────────────────

  group('DartFfiGenerator — type-only spec', () {
    final spec = _typeOnlySpec(
      enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
    );
    final code = DartFfiGenerator.generate(spec);

    test('type-only file emits enum extensions', () {
      expect(code, contains('QualityNativeExt'));
    });

    test('type-only file does NOT emit _Impl class', () {
      expect(code, isNot(contains('_Impl extends')));
    });

    test('type-only file does NOT emit lookupFunction', () {
      expect(code, isNot(contains('lookupFunction')));
    });

    test('type-only file does NOT emit NitroRuntime.loadLib', () {
      expect(code, isNot(contains('NitroRuntime.loadLib')));
    });
  });

  group('DartFfiGenerator — imported enums not re-declared', () {
    final spec = _moduleSpecWithImported(
      enums: [
        BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high']),
        BridgeEnum(name: 'Priority', startValue: 0, values: ['normal', 'high'], isImported: true),
      ],
    );
    final code = DartFfiGenerator.generate(spec);

    test('local enum extension is generated', () {
      expect(code, contains('QualityNativeExt'));
    });

    test('imported enum extension is NOT generated', () {
      expect(code, isNot(contains('PriorityNativeExt')));
    });
  });

  // ── EnumGenerator — skip imported enums ──────────────────────────────────

  group('EnumGenerator — localEnums only', () {
    final spec = _moduleSpecWithImported(
      enums: [
        BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high']),
        BridgeEnum(name: 'Priority', startValue: 0, values: ['normal', 'high'], isImported: true),
      ],
    );

    test('generateDartExtensions emits only local enum', () {
      final code = EnumGenerator.generateDartExtensions(spec);
      expect(code, contains('QualityNativeExt'));
      expect(code, isNot(contains('PriorityNativeExt')));
    });

    test('generateCEnums emits only local enum', () {
      final code = EnumGenerator.generateCEnums(spec);
      expect(code, contains('QUALITY'));
      expect(code, isNot(contains('PRIORITY')));
    });

    test('generateKotlin emits only local enum', () {
      final code = EnumGenerator.generateKotlin(spec);
      expect(code, contains('enum class Quality'));
      expect(code, isNot(contains('enum class Priority')));
    });

    test('generateSwift emits only local enum', () {
      final code = EnumGenerator.generateSwift(spec);
      expect(code, contains('public enum Quality'));
      expect(code, isNot(contains('public enum Priority')));
    });
  });

  // ── StructGenerator — skip imported structs ───────────────────────────────

  group('StructGenerator — localStructs only', () {
    final localStruct = BridgeStruct(
      name: 'Frame',
      packed: false,
      fields: [BridgeField(name: 'width', type: BridgeType(name: 'int'))],
    );
    final importedStruct = BridgeStruct(
      name: 'Config',
      packed: false,
      fields: [BridgeField(name: 'fps', type: BridgeType(name: 'int'))],
      isImported: true,
    );
    final spec = _moduleSpecWithImported(structs: [localStruct, importedStruct]);

    test('generateDartExtensions emits only local struct', () {
      final code = StructGenerator.generateDartExtensions(spec);
      expect(code, contains('FrameExt'));
      expect(code, isNot(contains('ConfigExt')));
    });

    test('generateCStructs emits only local struct', () {
      final code = StructGenerator.generateCStructs(spec);
      expect(code, contains('typedef struct'));
      expect(code, contains('Frame'));
      expect(code, isNot(contains('Config')));
    });

    test('generateKotlin emits only local struct', () {
      final code = StructGenerator.generateKotlin(spec);
      expect(code, contains('data class Frame'));
      expect(code, isNot(contains('data class Config')));
    });

    test('generateSwift emits only local struct', () {
      final code = StructGenerator.generateSwift(spec);
      expect(code, contains('public struct Frame'));
      expect(code, isNot(contains('public struct Config')));
    });
  });

  // ── RecordGenerator — skip imported records ───────────────────────────────

  group('RecordGenerator — localRecordTypes only', () {
    final localRecord = BridgeRecordType(
      name: 'Result',
      fields: [BridgeRecordField(name: 'value', dartType: 'int', kind: RecordFieldKind.primitive)],
    );
    final importedRecord = BridgeRecordType(
      name: 'Settings',
      fields: [BridgeRecordField(name: 'timeout', dartType: 'int', kind: RecordFieldKind.primitive)],
      isImported: true,
    );
    final spec = _moduleSpecWithImported(records: [localRecord, importedRecord]);

    test('generateDartExtensions emits only local record extension', () {
      final code = RecordGenerator.generateDartExtensions(spec);
      expect(code, contains('ResultRecordExt'));
      expect(code, isNot(contains('SettingsRecordExt')));
    });

    test('generateCpp emits only local record struct', () {
      final code = RecordGenerator.generateCpp(spec);
      expect(code, contains('struct Result'));
      expect(code, isNot(contains('struct Settings')));
    });

    test('generateKotlin emits only local record data class', () {
      final code = RecordGenerator.generateKotlin(spec);
      expect(code, contains('data class Result'));
      expect(code, isNot(contains('data class Settings')));
    });

    test('generateSwift emits only local record struct', () {
      final code = RecordGenerator.generateSwift(spec);
      expect(code, contains('public struct Result'));
      expect(code, isNot(contains('public struct Settings')));
    });
  });

  // ── CppHeaderGenerator — importedTypeFiles #include ───────────────────────

  group('CppHeaderGenerator — importedTypeFiles #include', () {
    test('emits #include for each imported type file', () {
      final spec = _moduleSpecWithImported(
        importedTypeFiles: ['my_types.bridge.g.h'],
      );
      final code = CppHeaderGenerator.generate(spec);
      expect(code, contains('#include "my_types.bridge.g.h"'));
    });

    test('emits multiple #includes when multiple imports', () {
      final spec = _moduleSpecWithImported(
        importedTypeFiles: ['types_a.bridge.g.h', '../other/generated/cpp/types_b.bridge.g.h'],
      );
      final code = CppHeaderGenerator.generate(spec);
      expect(code, contains('#include "types_a.bridge.g.h"'));
      expect(code, contains('#include "../other/generated/cpp/types_b.bridge.g.h"'));
    });

    test('no extra #include when importedTypeFiles is empty', () {
      final spec = _moduleSpecWithImported();
      final code = CppHeaderGenerator.generate(spec);
      expect(code.split('\n').where((l) => l.startsWith('#include "')).length, lessThan(5));
    });
  });

  // ── CppHeaderGenerator — type-only files ─────────────────────────────────

  group('CppHeaderGenerator — type-only spec', () {
    final spec = _typeOnlySpec(
      enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
    );
    final code = CppHeaderGenerator.generate(spec);

    test('type-only header contains enum typedef', () {
      expect(code, contains('QUALITY'));
    });

    test('type-only header does NOT emit extern "C" block', () {
      expect(code, isNot(contains('extern "C"')));
    });

    test('type-only header does NOT emit NITRO_EXPORT functions', () {
      expect(code, isNot(contains('NITRO_EXPORT intptr_t')));
    });
  });

  // ── SwiftGenerator — type-only files ─────────────────────────────────────

  group('SwiftGenerator — type-only spec', () {
    final spec = _typeOnlySpec(
      enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
    );
    final code = SwiftGenerator.generate(spec);

    test('type-only Swift emits enum declaration', () {
      expect(code, contains('public enum Quality'));
    });

    test('type-only Swift does NOT emit protocol', () {
      expect(code, isNot(contains('protocol Hybrid')));
    });

    test('type-only Swift does NOT emit registry', () {
      expect(code, isNot(contains('Registry')));
    });

    test('type-only Swift does NOT emit @_cdecl', () {
      expect(code, isNot(contains('@_cdecl')));
    });
  });

  // ── KotlinGenerator — type-only files ────────────────────────────────────

  group('KotlinGenerator — type-only spec', () {
    final spec = _typeOnlySpec(
      enums: [BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'high'])],
    );
    final code = KotlinGenerator.generate(spec);

    test('type-only Kotlin emits package declaration', () {
      expect(code, contains('package nitro.my_types_module'));
    });

    test('type-only Kotlin emits enum class', () {
      expect(code, contains('enum class Quality'));
    });

    test('type-only Kotlin does NOT emit interface', () {
      expect(code, isNot(contains('interface Hybrid')));
    });

    test('type-only Kotlin does NOT emit JniBridge object', () {
      expect(code, isNot(contains('JniBridge')));
    });
  });

  // ── Imported enum used in module functions ─────────────────────────────────

  group('Module uses imported enum — type classification', () {
    // Imported enum used as function param; should be classified as enum
    // in the module's bridge even though not declared there.
    final spec = BridgeSpec(
      dartClassName: 'Cam',
      lib: 'cam',
      namespace: 'cam',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'cam.native.dart',
      enums: [
        BridgeEnum(name: 'Priority', startValue: 0, values: ['low', 'high'], isImported: true),
      ],
      functions: [
        BridgeFunction(
          dartName: 'setPriority',
          cSymbol: 'cam_set_priority',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [BridgeParam(name: 'priority', type: BridgeType(name: 'Priority'))],
        ),
      ],
    );

    test('C header emits function declaration for method using imported enum param', () {
      final code = CppHeaderGenerator.generate(spec);
      expect(code, contains('cam_set_priority'));
    });

    test('Dart FFI uses nativeValue for enum param (classification works)', () {
      final code = DartFfiGenerator.generate(spec);
      expect(code, contains('priority.nativeValue'));
    });

    test('C header does NOT declare imported enum typedef', () {
      final code = CppHeaderGenerator.generate(spec);
      // PRIORITY_LOW etc. should not be declared (it's in the imported header)
      expect(code, isNot(contains('PRIORITY_LOW')));
    });
  });
}
