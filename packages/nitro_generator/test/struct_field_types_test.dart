// Comprehensive edge-case tests for StructGenerator field-type handling.
//
// Covers gaps not addressed by existing tests:
//
//   1. String fields   — toDart, toNative, freeFields, proxy getter/super, C/Kotlin/Swift
//   2. Enum fields     — annotation, toDart, toNative, proxy getter/super, C/Kotlin/Swift
//   3. TypedData       — all 6 length-field name variants (length/size/stride/bytelength/bytelen/len)
//                        + fallback to 0 when no length field found
//   4. freeFields      — string-only, nested-pointer-only, mixed string+pointer, no-op
//   5. ZeroCopy        — C struct field comment
//   6. Nullable types  — '?' stripped in conversion expressions
//   7. BridgeField defaults — isNamed=true, isRequired=true do not change existing output
//   8. All field types in one struct (kitchen-sink)

import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Shared spec builders ──────────────────────────────────────────────────────

BridgeSpec _stringFieldSpec() => BridgeSpec(
  dartClassName: 'Greeter',
  lib: 'greeter',
  namespace: 'greeter',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'greeter.native.dart',
  structs: [
    BridgeStruct(
      name: 'Greeting',
      packed: false,
      fields: [
        BridgeField(
          name: 'message',
          type: BridgeType(name: 'String'),
        ),
        BridgeField(
          name: 'count',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
  functions: [],
);

BridgeSpec _enumFieldSpec() => BridgeSpec(
  dartClassName: 'StatusMod',
  lib: 'status_mod',
  namespace: 'status_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'status_mod.native.dart',
  enums: [
    BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'mid', 'high']),
  ],
  structs: [
    BridgeStruct(
      name: 'StatusRecord',
      packed: false,
      fields: [
        BridgeField(
          name: 'level',
          type: BridgeType(name: 'Level'),
        ),
        BridgeField(
          name: 'score',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
  functions: [],
);

BridgeSpec _typedDataSpec({required String lenFieldName}) => BridgeSpec(
  dartClassName: 'DataMod',
  lib: 'data_mod',
  namespace: 'data_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'data_mod.native.dart',
  structs: [
    BridgeStruct(
      name: 'DataBuf',
      packed: false,
      fields: [
        BridgeField(
          name: 'data',
          type: BridgeType(name: 'Uint8List'),
        ),
        BridgeField(
          name: lenFieldName,
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
  functions: [],
);

BridgeSpec _typedDataNoLenSpec() => BridgeSpec(
  dartClassName: 'DataMod',
  lib: 'data_mod',
  namespace: 'data_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'data_mod.native.dart',
  structs: [
    BridgeStruct(
      name: 'DataBuf',
      packed: false,
      fields: [
        BridgeField(
          name: 'data',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    ),
  ],
  functions: [],
);

BridgeSpec _freeFieldsSpec({
  bool hasString = false,
  bool hasNested = false,
  bool hasDouble = true,
}) {
  final nestedStructs = hasNested
      ? [
          BridgeStruct(
            name: 'Inner',
            packed: false,
            fields: [
              BridgeField(
                name: 'v',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ]
      : <BridgeStruct>[];

  final fields = <BridgeField>[
    if (hasDouble)
      BridgeField(
        name: 'value',
        type: BridgeType(name: 'double'),
      ),
    if (hasString)
      BridgeField(
        name: 'label',
        type: BridgeType(name: 'String'),
      ),
    if (hasNested)
      BridgeField(
        name: 'inner',
        type: BridgeType(name: 'Inner'),
      ),
  ];

  return BridgeSpec(
    dartClassName: 'Outer',
    lib: 'outer',
    namespace: 'outer',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'outer.native.dart',
    structs: [
      ...nestedStructs,
      BridgeStruct(name: 'Container', packed: false, fields: fields),
    ],
    functions: [],
  );
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. String fields ─────────────────────────────────────────────────────────

  group('String fields in structs', () {
    late String dartExt;
    late String proxy;
    late String kotlin;
    late String swift;
    late String c;

    setUp(() {
      dartExt = StructGenerator.generateDartExtensions(_stringFieldSpec());
      proxy = StructGenerator.generateDartProxies(_stringFieldSpec());
      kotlin = StructGenerator.generateKotlin(_stringFieldSpec());
      swift = StructGenerator.generateSwift(_stringFieldSpec());
      c = StructGenerator.generateCStructs(_stringFieldSpec());
    });

    // FFI Struct
    test('FFI Struct declares string field as Pointer<Utf8>', () {
      expect(dartExt, contains('external Pointer<Utf8> message;'));
    });

    test('FFI Struct has no annotation for Pointer<Utf8> field', () {
      // Pointer fields need no @Int64() / @Double() annotation.
      final idx = dartExt.indexOf('external Pointer<Utf8> message');
      final lineStart = dartExt.lastIndexOf('\n', idx) + 1;
      final annotationLine = dartExt.substring(lineStart, idx).trim();
      expect(annotationLine, isNot(contains('@')));
    });

    // toDart()
    test('toDart() converts string field via .toDartString()', () {
      expect(dartExt, contains('message: message.toDartString()'));
    });

    // toNative()
    test('toNative() converts string field via .toNativeUtf8(allocator: arena)', () {
      expect(dartExt, contains('ptr.ref.message = message.toNativeUtf8(allocator: arena)'));
    });

    // freeFields()
    test('freeFields() emits null-check + malloc.free for string pointer', () {
      expect(dartExt, contains('if (message != nullptr) malloc.free(message)'));
    });

    test('freeFields() does NOT free the primitive int field', () {
      final freeIdx = dartExt.indexOf('void freeFields()');
      final freeEnd = dartExt.indexOf('}', freeIdx + 1);
      final freeBody = dartExt.substring(freeIdx, freeEnd + 1);
      expect(freeBody, isNot(contains('malloc.free(count)')));
    });

    // Proxy
    test("proxy super() uses '' as default for String field", () {
      expect(proxy, contains("message: ''"));
    });

    test('proxy lazy getter reads String via .toDartString()', () {
      expect(proxy, contains('String get message => _native.ref.message.toDartString()'));
    });

    // C typedef
    test('C typedef uses const char* for String field', () {
      expect(c, contains('const char* message;'));
    });

    // Kotlin
    test('Kotlin uses String for String field', () {
      expect(kotlin, contains('val message: String'));
    });

    // Swift
    test('Swift uses String for String field', () {
      expect(swift, contains('var message: String'));
    });
  });

  // ── 2. Enum fields in structs ─────────────────────────────────────────────────

  group('Enum fields in structs', () {
    late String dartExt;
    late String proxy;
    late String kotlin;
    late String swift;
    late String c;

    setUp(() {
      dartExt = StructGenerator.generateDartExtensions(_enumFieldSpec());
      proxy = StructGenerator.generateDartProxies(_enumFieldSpec());
      kotlin = StructGenerator.generateKotlin(_enumFieldSpec());
      swift = StructGenerator.generateSwift(_enumFieldSpec());
      c = StructGenerator.generateCStructs(_enumFieldSpec());
    });

    // FFI Struct
    test('FFI Struct declares enum field as int', () {
      expect(dartExt, contains('external int level;'));
    });

    test('FFI Struct annotates enum field with @Int32()', () {
      final idx = dartExt.indexOf('external int level;');
      // Walk back two newlines: the first is the end of the annotation line,
      // the second ends the line before it.
      final endOfAnnotationLine = dartExt.lastIndexOf('\n', idx);
      final startOfAnnotationLine = dartExt.lastIndexOf('\n', endOfAnnotationLine - 1) + 1;
      final annotationLine = dartExt.substring(startOfAnnotationLine, endOfAnnotationLine).trim();
      expect(annotationLine, contains('@Int32()'));
    });

    // toDart()
    test('toDart() converts enum field via .toLevel()', () {
      expect(dartExt, contains('level: level.toLevel()'));
    });

    // toNative()
    test('toNative() assigns enum field via .nativeValue', () {
      expect(dartExt, contains('ptr.ref.level = level.nativeValue'));
    });

    // freeFields()
    test('freeFields() does NOT free enum field (not a pointer)', () {
      final freeIdx = dartExt.indexOf('void freeFields()');
      final freeEnd = dartExt.indexOf('}', freeIdx + 1);
      final freeBody = dartExt.substring(freeIdx, freeEnd + 1);
      expect(freeBody, isNot(contains('malloc.free(level)')));
      expect(freeBody, isNot(contains('malloc.free(score)')));
    });

    // Proxy
    test('proxy super() uses EnumName.values.first for enum field', () {
      expect(proxy, contains('level: Level.values.first'));
    });

    test('proxy lazy getter reads enum via .toLevel()', () {
      expect(proxy, contains('Level get level => _native.ref.level.toLevel()'));
    });

    // C typedef
    test('C typedef uses int32_t for enum field', () {
      expect(c, contains('int32_t level;'));
    });

    // Kotlin — enums stored as Long in Kotlin data classes
    test('Kotlin uses Long for enum field', () {
      expect(kotlin, contains('val level: Long'));
    });

    // Swift — enums kept by name
    test('Swift uses enum type name for enum field', () {
      expect(swift, contains('var level: Level'));
    });
  });

  // ── 3. TypedData — length-field name variants ─────────────────────────────────

  group('TypedData — length-field name variants', () {
    // All of these names should be recognised as the byte-length companion:
    const lengthFieldNames = ['length', 'size', 'stride', 'bytelength', 'bytelen', 'len'];

    for (final lenName in lengthFieldNames) {
      group('length field named "$lenName"', () {
        late String dartExt;
        late String proxy;

        setUp(() {
          dartExt = StructGenerator.generateDartExtensions(_typedDataSpec(lenFieldName: lenName));
          proxy = StructGenerator.generateDartProxies(_typedDataSpec(lenFieldName: lenName));
        });

        test('toDart() uses $lenName as the asTypedList length', () {
          expect(dartExt, contains('data.asTypedList($lenName)'));
        });

        test('proxy lazy getter uses _native.ref.$lenName as the asTypedList length', () {
          expect(proxy, contains('_native.ref.data.asTypedList(_native.ref.$lenName)'));
        });
      });
    }

    group('no matching length field — fallback to 0', () {
      late String dartExt;
      late String proxy;

      setUp(() {
        dartExt = StructGenerator.generateDartExtensions(_typedDataNoLenSpec());
        proxy = StructGenerator.generateDartProxies(_typedDataNoLenSpec());
      });

      test('toDart() falls back to asTypedList(0) when no length field exists', () {
        expect(dartExt, contains('data.asTypedList(0)'));
      });

      test('proxy lazy getter falls back to asTypedList(0)', () {
        expect(proxy, contains('_native.ref.data.asTypedList(0)'));
      });
    });

    group('TypedData length field is case-insensitive', () {
      // 'Stride' (capital S) should NOT match — only lowercase names are in the set.
      // This documents the current intentional behaviour.
      test('capitalised variant "Stride" is NOT treated as a length field', () {
        final spec = BridgeSpec(
          dartClassName: 'Mod',
          lib: 'mod',
          namespace: 'mod',
          iosImpl: NativeImpl.swift,
          sourceUri: 'mod.native.dart',
          structs: [
            BridgeStruct(
              name: 'Buf',
              packed: false,
              fields: [
                BridgeField(
                  name: 'data',
                  type: BridgeType(name: 'Uint8List'),
                ),
                BridgeField(
                  name: 'Stride',
                  type: BridgeType(name: 'int'),
                ),
              ],
            ),
          ],
          functions: [],
        );
        final out = StructGenerator.generateDartExtensions(spec);
        // 'Stride' is not in the lowercase set → falls back to 0
        expect(out, contains('data.asTypedList(0)'));
        expect(out, isNot(contains('data.asTypedList(Stride)')));
      });
    });

    group('non-Uint8List TypedData types', () {
      for (final tdType in [
        'Float32List',
        'Float64List',
        'Int32List',
        'Uint32List',
        'Int16List',
        'Uint16List',
        'Int64List',
        'Uint64List',
      ]) {
        test('$tdType toDart() uses $tdType.fromList(...asTypedList(length))', () {
          final spec = BridgeSpec(
            dartClassName: 'Mod',
            lib: 'mod',
            namespace: 'mod',
            iosImpl: NativeImpl.swift,
            sourceUri: 'mod.native.dart',
            structs: [
              BridgeStruct(
                name: 'Buf',
                packed: false,
                fields: [
                  BridgeField(
                    name: 'data',
                    type: BridgeType(name: tdType),
                  ),
                  BridgeField(
                    name: 'length',
                    type: BridgeType(name: 'int'),
                  ),
                ],
              ),
            ],
            functions: [],
          );
          final out = StructGenerator.generateDartExtensions(spec);
          expect(out, contains('$tdType.fromList(data.asTypedList(length))'));
        });
      }
    });
  });

  // ── 4. freeFields() combinations ─────────────────────────────────────────────

  group('freeFields() — combination coverage', () {
    test('only primitive fields → freeFields body is empty (no malloc.free)', () {
      final out = StructGenerator.generateDartExtensions(
        _freeFieldsSpec(hasDouble: true, hasString: false, hasNested: false),
      );
      final freeIdx = out.indexOf('void freeFields()');
      final freeEnd = out.indexOf('}', freeIdx + 1);
      final freeBody = out.substring(freeIdx, freeEnd + 1);
      expect(freeBody, isNot(contains('malloc.free')));
    });

    test('only string field → frees the string pointer', () {
      final out = StructGenerator.generateDartExtensions(
        _freeFieldsSpec(hasDouble: false, hasString: true, hasNested: false),
      );
      expect(out, contains('if (label != nullptr) malloc.free(label)'));
      expect(out, isNot(contains('label.ref.freeFields')));
    });

    test('only nested struct field → frees nested pointer recursively', () {
      final out = StructGenerator.generateDartExtensions(
        _freeFieldsSpec(hasDouble: false, hasString: false, hasNested: true),
      );
      expect(out, contains('if (inner != nullptr) {'));
      expect(out, contains('inner.ref.freeFields();'));
      expect(out, contains('malloc.free(inner);'));
    });

    test('string + nested struct → frees both independently', () {
      final out = StructGenerator.generateDartExtensions(
        _freeFieldsSpec(hasDouble: true, hasString: true, hasNested: true),
      );
      expect(out, contains('if (label != nullptr) malloc.free(label)'));
      expect(out, contains('if (inner != nullptr) {'));
      expect(out, contains('inner.ref.freeFields();'));
      expect(out, contains('malloc.free(inner);'));
    });

    test('freeFields does NOT generate any free for double/bool/int fields', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'Mix',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
              ),
              BridgeField(
                name: 'n',
                type: BridgeType(name: 'int'),
              ),
              BridgeField(
                name: 'ok',
                type: BridgeType(name: 'bool'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final out = StructGenerator.generateDartExtensions(spec);
      final freeIdx = out.indexOf('void freeFields()');
      final freeEnd = out.indexOf('}', freeIdx + 1);
      final freeBody = out.substring(freeIdx, freeEnd + 1);
      expect(freeBody, isNot(contains('malloc.free')));
    });

    test('multiple string fields: each gets its own null-check + free', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'TwoStrings',
            packed: false,
            fields: [
              BridgeField(
                name: 'first',
                type: BridgeType(name: 'String'),
              ),
              BridgeField(
                name: 'second',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final out = StructGenerator.generateDartExtensions(spec);
      expect(out, contains('if (first != nullptr) malloc.free(first)'));
      expect(out, contains('if (second != nullptr) malloc.free(second)'));
    });

    test('multiple nested struct fields: each gets its own recursive free', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'Leaf',
            packed: false,
            fields: [
              BridgeField(
                name: 'v',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
          BridgeStruct(
            name: 'TwoNested',
            packed: false,
            fields: [
              BridgeField(
                name: 'a',
                type: BridgeType(name: 'Leaf'),
              ),
              BridgeField(
                name: 'b',
                type: BridgeType(name: 'Leaf'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final out = StructGenerator.generateDartExtensions(spec);
      expect(out, contains('if (a != nullptr) {'));
      expect(out, contains('a.ref.freeFields()'));
      expect(out, contains('malloc.free(a)'));
      expect(out, contains('if (b != nullptr) {'));
      expect(out, contains('b.ref.freeFields()'));
      expect(out, contains('malloc.free(b)'));
    });
  });

  // ── 5. ZeroCopy comment in C struct ──────────────────────────────────────────

  group('ZeroCopy — C struct field comment', () {
    BridgeSpec zeroCopySpec() => BridgeSpec(
      dartClassName: 'Cam',
      lib: 'cam',
      namespace: 'cam',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'cam.native.dart',
      structs: [
        BridgeStruct(
          name: 'Frame',
          packed: false,
          fields: [
            BridgeField(
              name: 'data',
              type: BridgeType(name: 'Uint8List'),
              zeroCopy: true,
            ),
            BridgeField(
              name: 'width',
              type: BridgeType(name: 'int'),
              zeroCopy: false,
            ),
            BridgeField(
              name: 'stride',
              type: BridgeType(name: 'int'),
              zeroCopy: false,
            ),
          ],
        ),
      ],
      functions: [],
    );

    test('zeroCopy field has /* zero-copy */ comment in C typedef', () {
      final out = StructGenerator.generateCStructs(zeroCopySpec());
      expect(out, contains('/* zero-copy */'));
    });

    test('zeroCopy comment appears on the data field line', () {
      final out = StructGenerator.generateCStructs(zeroCopySpec());
      expect(out, contains('uint8_t* data; /* zero-copy */'));
    });

    test('non-zeroCopy fields have no /* zero-copy */ comment', () {
      final out = StructGenerator.generateCStructs(zeroCopySpec());
      expect(out, isNot(contains('int64_t width; /* zero-copy */')));
      expect(out, isNot(contains('int64_t stride; /* zero-copy */')));
    });
  });

  // ── 6. Nullable field type name — '?' stripping ───────────────────────────────

  group("Nullable field type '?' stripping", () {
    BridgeSpec nullableSpec() => BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      sourceUri: 'mod.native.dart',
      enums: [
        BridgeEnum(name: 'State', startValue: 0, values: ['on', 'off']),
      ],
      structs: [
        BridgeStruct(
          name: 'Nullable',
          packed: false,
          fields: [
            // The extractor writes withNullability: true → 'State?' can appear
            BridgeField(
              name: 'mode',
              type: BridgeType(name: 'State?'),
            ),
            BridgeField(
              name: 'score',
              type: BridgeType(name: 'double?'),
            ),
          ],
        ),
      ],
      functions: [],
    );

    test('enum with ? still maps to @Int32() + int in FFI Struct', () {
      final out = StructGenerator.generateDartExtensions(nullableSpec());
      expect(out, contains('@Int32()'));
      expect(out, contains('external int mode;'));
    });

    test('nullable enum field toDart() strips ? and calls toEnumName()', () {
      final out = StructGenerator.generateDartExtensions(nullableSpec());
      expect(out, contains('mode: mode.toState()'));
    });

    test('nullable double still maps to @Double() + double in FFI Struct', () {
      final out = StructGenerator.generateDartExtensions(nullableSpec());
      expect(out, contains('@Double()'));
      expect(out, contains('external double score;'));
    });

    test('nullable double toDart() strips ? and passes field directly', () {
      final out = StructGenerator.generateDartExtensions(nullableSpec());
      expect(out, contains('score: score'));
    });
  });

  // ── 7. BridgeField defaults regression ───────────────────────────────────────

  group('BridgeField.isNamed / isRequired defaults regression', () {
    // All existing test specs create BridgeField() without specifying isNamed or
    // isRequired. The defaults are isNamed=true, isRequired=true, which should
    // produce the same named-arg output as before these fields were added.

    test('default BridgeField produces named args in toDart()', () {
      // richSpec() uses default BridgeField() constructor everywhere
      final out = StructGenerator.generateDartExtensions(richSpec());
      expect(out, contains('value: value'));
      expect(out, contains('valid: valid != 0'));
    });

    test('default BridgeField produces named defaults in proxy super()', () {
      final out = StructGenerator.generateDartProxies(richSpec());
      expect(out, contains('value: 0.0'));
      expect(out, contains('valid: false'));
    });

    test('explicit isNamed=true produces named args (same as default)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'P',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
                isNamed: true,
                isRequired: true,
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ext = StructGenerator.generateDartExtensions(spec);
      final proxy = StructGenerator.generateDartProxies(spec);
      expect(ext, contains('x: x'));
      expect(proxy, contains('x: 0.0'));
    });

    test('explicit isNamed=false produces positional arg (no label)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'P',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
                isNamed: false,
                isRequired: true,
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ext = StructGenerator.generateDartExtensions(spec);
      final proxy = StructGenerator.generateDartProxies(spec);
      expect(ext, isNot(contains('x: x')));
      expect(proxy, contains('super(0.0)'));
    });

    test('isRequired=false on named field does not change generated output', () {
      // isRequired only matters for the spec extractor, not the generator.
      // Named optional and named required produce identical call-site code.
      final requiredSpec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'P',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
                isNamed: true,
                isRequired: true,
              ),
            ],
          ),
        ],
        functions: [],
      );
      final optionalSpec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'P',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
                isNamed: true,
                isRequired: false,
              ),
            ],
          ),
        ],
        functions: [],
      );
      expect(
        StructGenerator.generateDartExtensions(requiredSpec),
        equals(StructGenerator.generateDartExtensions(optionalSpec)),
      );
      expect(
        StructGenerator.generateDartProxies(requiredSpec),
        equals(StructGenerator.generateDartProxies(optionalSpec)),
      );
    });
  });

  // ── 8. Kitchen-sink: all field types in one struct ────────────────────────────

  group('Kitchen-sink struct — all field types together', () {
    BridgeSpec kitchenSinkSpec() => BridgeSpec(
      dartClassName: 'KitchenMod',
      lib: 'kitchen_mod',
      namespace: 'kitchen_mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'kitchen_mod.native.dart',
      enums: [
        BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green', 'blue']),
      ],
      structs: [
        BridgeStruct(
          name: 'Sub',
          packed: false,
          fields: [
            BridgeField(
              name: 'v',
              type: BridgeType(name: 'double'),
            ),
          ],
        ),
        BridgeStruct(
          name: 'Everything',
          packed: false,
          fields: [
            BridgeField(
              name: 'count',
              type: BridgeType(name: 'int'),
            ),
            BridgeField(
              name: 'ratio',
              type: BridgeType(name: 'double'),
            ),
            BridgeField(
              name: 'active',
              type: BridgeType(name: 'bool'),
            ),
            BridgeField(
              name: 'label',
              type: BridgeType(name: 'String'),
            ),
            BridgeField(
              name: 'color',
              type: BridgeType(name: 'Color'),
            ),
            BridgeField(
              name: 'sub',
              type: BridgeType(name: 'Sub'),
            ),
            BridgeField(
              name: 'data',
              type: BridgeType(name: 'Uint8List'),
            ),
            BridgeField(
              name: 'length',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
      functions: [],
    );

    test('all FFI Struct field types are correct', () {
      final out = StructGenerator.generateDartExtensions(kitchenSinkSpec());
      expect(out, contains('@Int64()\n  external int count;'));
      expect(out, contains('@Double()\n  external double ratio;'));
      expect(out, contains('@Int8()\n  external int active;'));
      expect(out, contains('external Pointer<Utf8> label;'));
      expect(out, contains('@Int32()\n  external int color;'));
      expect(out, contains('external Pointer<SubFfi> sub;'));
      expect(out, contains('external Pointer<Uint8> data;'));
    });

    test('all toDart() conversions are correct', () {
      final out = StructGenerator.generateDartExtensions(kitchenSinkSpec());
      expect(out, contains('count: count'));
      expect(out, contains('ratio: ratio'));
      expect(out, contains('active: active != 0'));
      expect(out, contains('label: label.toDartString()'));
      expect(out, contains('color: color.toColor()'));
      expect(out, contains('sub: sub.ref.toDart()'));
      expect(out, contains('data: Uint8List.fromList(data.asTypedList(length))'));
    });

    test('all toNative() assignments are correct', () {
      final out = StructGenerator.generateDartExtensions(kitchenSinkSpec());
      expect(out, contains('ptr.ref.count = count'));
      expect(out, contains('ptr.ref.ratio = ratio'));
      expect(out, contains('ptr.ref.active = active ? 1 : 0'));
      expect(out, contains('ptr.ref.label = label.toNativeUtf8(allocator: arena)'));
      expect(out, contains('ptr.ref.color = color.nativeValue'));
      expect(out, contains('ptr.ref.sub = sub.toNative(arena)'));
      expect(out, contains('ptr.ref.data = data.toPointer(arena)'));
    });

    test('freeFields() frees string and nested struct only', () {
      final out = StructGenerator.generateDartExtensions(kitchenSinkSpec());
      // Find the freeFields for Everything
      final evIdx = out.indexOf('extension EverythingFfiExt');
      final evBlock = out.substring(evIdx, out.indexOf('extension Everything', evIdx + 1));
      final freeIdx = evBlock.indexOf('void freeFields()');
      final freeEnd = evBlock.indexOf('}', freeIdx + 1);
      final freeBody = evBlock.substring(freeIdx, freeEnd + 1);
      // String field freed
      expect(freeBody, contains('if (label != nullptr) malloc.free(label)'));
      // Nested struct freed
      expect(freeBody, contains('if (sub != nullptr) {'));
      expect(freeBody, contains('sub.ref.freeFields()'));
      expect(freeBody, contains('malloc.free(sub)'));
      // Primitives NOT freed
      expect(freeBody, isNot(contains('malloc.free(count)')));
      expect(freeBody, isNot(contains('malloc.free(ratio)')));
      expect(freeBody, isNot(contains('malloc.free(active)')));
      expect(freeBody, isNot(contains('malloc.free(color)')));
      expect(freeBody, isNot(contains('malloc.free(data)')));
    });

    test('proxy super() has correct zero defaults for all types', () {
      final out = StructGenerator.generateDartProxies(kitchenSinkSpec());
      expect(out, contains('count: 0'));
      expect(out, contains('ratio: 0.0'));
      expect(out, contains('active: false'));
      expect(out, contains("label: ''"));
      expect(out, contains('color: Color.values.first'));
      expect(out, contains('sub: Sub(v: 0.0)'));
      expect(out, contains('data: Uint8List(0)'));
      expect(out, contains('length: 0'));
    });

    test('Kotlin data class maps all types correctly', () {
      final out = StructGenerator.generateKotlin(kitchenSinkSpec());
      expect(out, contains('val count: Long'));
      expect(out, contains('val ratio: Double'));
      expect(out, contains('val active: Boolean'));
      expect(out, contains('val label: String'));
      expect(out, contains('val color: Long')); // enum → Long
      expect(out, contains('val sub: Sub')); // nested struct → type name
      expect(out, contains('val data: ByteArray'));
      expect(out, contains('val length: Long'));
    });

    test('Swift struct maps all types correctly', () {
      final out = StructGenerator.generateSwift(kitchenSinkSpec());
      expect(out, contains('var count: Int64'));
      expect(out, contains('var ratio: Double'));
      expect(out, contains('var active: Bool'));
      expect(out, contains('var label: String'));
      expect(out, contains('var color: Color')); // enum → type name
      expect(out, contains('var sub: Sub')); // nested struct → type name
      expect(out, contains('var data: Data')); // non-zeroCopy Uint8List → Data
      expect(out, contains('var length: Int64'));
    });

    test('C typedef maps all types correctly', () {
      final out = StructGenerator.generateCStructs(kitchenSinkSpec());
      expect(out, contains('int64_t count;'));
      expect(out, contains('double ratio;'));
      expect(out, contains('int8_t active;'));
      expect(out, contains('const char* label;'));
      expect(out, contains('int32_t color;')); // enum → int32_t
      expect(out, contains('Sub* sub;')); // nested struct → pointer
      expect(out, contains('uint8_t* data;'));
      expect(out, contains('int64_t length;'));
    });
  });

  // ── 9. Single-field struct edge cases ────────────────────────────────────────

  group('Single-field struct edge cases', () {
    test('single String field — full round-trip correct', () {
      final spec = BridgeSpec(
        dartClassName: 'Msg',
        lib: 'msg',
        namespace: 'msg',
        iosImpl: NativeImpl.swift,
        sourceUri: 'msg.native.dart',
        structs: [
          BridgeStruct(
            name: 'Message',
            packed: false,
            fields: [
              BridgeField(
                name: 'text',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ext = StructGenerator.generateDartExtensions(spec);
      final proxy = StructGenerator.generateDartProxies(spec);
      expect(ext, contains('external Pointer<Utf8> text;'));
      expect(ext, contains('text: text.toDartString()'));
      expect(ext, contains('ptr.ref.text = text.toNativeUtf8(allocator: arena)'));
      expect(ext, contains('if (text != nullptr) malloc.free(text)'));
      expect(proxy, contains("text: ''"));
      expect(proxy, contains('String get text => _native.ref.text.toDartString()'));
    });

    test('single bool field — full round-trip correct', () {
      final spec = BridgeSpec(
        dartClassName: 'Flag',
        lib: 'flag',
        namespace: 'flag',
        iosImpl: NativeImpl.swift,
        sourceUri: 'flag.native.dart',
        structs: [
          BridgeStruct(
            name: 'Flag',
            packed: false,
            fields: [
              BridgeField(
                name: 'enabled',
                type: BridgeType(name: 'bool'),
              ),
            ],
          ),
        ],
        functions: [],
      );
      final ext = StructGenerator.generateDartExtensions(spec);
      final proxy = StructGenerator.generateDartProxies(spec);
      expect(ext, contains('@Int8()'));
      expect(ext, contains('external int enabled;'));
      expect(ext, contains('enabled: enabled != 0'));
      expect(ext, contains('ptr.ref.enabled = enabled ? 1 : 0'));
      expect(proxy, contains('enabled: false'));
      expect(proxy, contains('bool get enabled => _native.ref.enabled != 0'));
    });
  });
}
