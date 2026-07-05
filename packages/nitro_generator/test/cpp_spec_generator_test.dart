import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_spec_generator.dart';
import 'package:test/test.dart';

void main() {
  group('CppSpecGenerator', () {
    BridgeSpec makeCounterSpec({
      List<BridgeFunction> functions = const [],
      List<BridgeProperty> properties = const [],
      List<BridgeEnum> enums = const [],
      List<BridgeVariant> variants = const [],
    }) => BridgeSpec(
      dartClassName: 'Counter',
      lib: 'counter',
      namespace: 'counter',
      iosImpl: NativeImpl.cpp,
      androidImpl: NativeImpl.cpp,
      sourceUri: 'counter.native.dart',
      functions: functions,
      properties: properties,
      enums: enums,
      variants: variants,
    );

    test('generates a non-empty string', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, isNotEmpty);
    });

    test('contains #pragma once', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, contains('#pragma once'));
    });

    test('contains standard C++ includes', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, contains('#include <cstdint>'));
      expect(out, contains('#include <functional>'));
      expect(out, contains('#include <memory>'));
      expect(out, contains('#include <optional>'));
      expect(out, contains('#include <string>'));
      expect(out, contains('#include <vector>'));
    });

    test('class name is {ClassName}Spec', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, contains('class CounterSpec'));
    });

    test('has virtual destructor and lifecycle hooks', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, contains('virtual ~CounterSpec() = default;'));
      expect(out, contains('virtual void onCreate() {}'));
      expect(out, contains('virtual void onDestroy() {}'));
    });

    test('emits registry helpers', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, contains('void register_counter(std::shared_ptr<CounterSpec> impl);'));
      expect(out, contains('std::shared_ptr<CounterSpec> get_counter(int64_t instanceId);'));
    });

    test('emits namespace nitro', () {
      final out = CppSpecGenerator.generate(makeCounterSpec());
      expect(out, contains('namespace nitro {'));
      expect(out, contains('} // namespace nitro'));
    });

    // ── Type mapping tests ──────────────────────────────────────────────

    test('int32 param maps to int32_t', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'add',
            cSymbol: 'counter_add',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'n',
                type: BridgeType(name: 'int32'),
              ),
            ],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('int32_t n'));
    });

    test('float return maps to float', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'ratio',
            cSymbol: 'counter_ratio',
            isAsync: false,
            returnType: BridgeType(name: 'float'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual float ratio()'));
    });

    test('String return maps to std::string', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'label',
            cSymbol: 'counter_label',
            isAsync: false,
            returnType: BridgeType(name: 'String'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual std::string label()'));
    });

    test('int? return maps to std::optional<int64_t>', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'maybeCount',
            cSymbol: 'counter_maybe_count',
            isAsync: false,
            returnType: BridgeType(name: 'int?', isNullable: true),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('std::optional<int64_t>'));
    });

    test('bool maps to bool', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'isReady',
            cSymbol: 'counter_is_ready',
            isAsync: false,
            returnType: BridgeType(name: 'bool'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual bool isReady()'));
    });

    test('double maps to double', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'value',
            cSymbol: 'counter_value',
            isAsync: false,
            returnType: BridgeType(name: 'double'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual double value()'));
    });

    test('Uint8List maps to std::vector<uint8_t>', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'getData',
            cSymbol: 'counter_get_data',
            isAsync: false,
            returnType: BridgeType(name: 'Uint8List'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('std::vector<uint8_t>'));
    });

    test('@HybridEnum forward-declares enum class E : int64_t', () {
      final spec = makeCounterSpec(
        enums: [
          BridgeEnum(name: 'Status', startValue: 0, values: ['ok', 'error']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getStatus',
            cSymbol: 'counter_get_status',
            isAsync: false,
            returnType: BridgeType(name: 'Status'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('enum class Status : int64_t;'));
    });

    test('enum type in method signature uses enum name directly', () {
      final spec = makeCounterSpec(
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['fast', 'slow']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'setMode',
            cSymbol: 'counter_set_mode',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'mode',
                type: BridgeType(name: 'Mode'),
              ),
            ],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual void setMode(Mode mode)'));
    });

    test('void-returning function is pure virtual = 0', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'reset',
            cSymbol: 'counter_reset',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual void reset() = 0;'));
    });

    test('property with getter emits get{Name}() = 0', () {
      final spec = makeCounterSpec(
        properties: [
          BridgeProperty(
            dartName: 'count',
            type: BridgeType(name: 'int'),
            getSymbol: 'counter_get_count',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual int64_t getCount() = 0;'));
    });

    test('property with setter emits setName(type value) = 0', () {
      final spec = makeCounterSpec(
        properties: [
          BridgeProperty(
            dartName: 'count',
            type: BridgeType(name: 'int'),
            getSymbol: 'counter_get_count',
            setSymbol: 'counter_set_count',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual void setCount(int64_t value) = 0;'));
    });

    test('@NitroVariant emits using alias with std::variant', () {
      final spec = makeCounterSpec(
        variants: [
          BridgeVariant(
            name: 'CounterEvent',
            cases: [
              BridgeVariantCase(
                name: 'CounterIncremented',
                label: 'incremented',
                fields: [
                  BridgeRecordField(
                    name: 'delta',
                    dartType: 'int',
                    kind: RecordFieldKind.primitive,
                  ),
                ],
              ),
              BridgeVariantCase(
                name: 'CounterReset',
                label: 'reset',
                fields: [],
              ),
            ],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('using CounterEvent = std::variant<'));
    });

    test('null variant case generates std::monostate in alias', () {
      final spec = makeCounterSpec(
        variants: [
          BridgeVariant(
            name: 'NullableEvent',
            cases: [
              BridgeVariantCase(
                name: 'EventHappened',
                label: 'happened',
                fields: [],
              ),
              BridgeVariantCase(
                name: 'null',
                label: 'null',
                fields: [],
              ),
            ],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('std::monostate'));
    });

    test('lib stem replaces hyphens with underscores in registry helpers', () {
      final spec = BridgeSpec(
        dartClassName: 'MyMod',
        lib: 'my-mod',
        namespace: 'my_mod',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'my_mod.native.dart',
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('register_my_mod('));
      expect(out, contains('get_my_mod('));
    });

    test('DateTime maps to int64_t', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'timestamp',
            cSymbol: 'counter_timestamp',
            isAsync: false,
            returnType: BridgeType(name: 'DateTime'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual int64_t timestamp()'));
    });

    test('uint64 maps to uint64_t', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'bigNumber',
            cSymbol: 'counter_big_number',
            isAsync: false,
            returnType: BridgeType(name: 'uint64'),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual uint64_t bigNumber()'));
    });

    test('List<String> param maps to std::vector<std::string>', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'process',
            cSymbol: 'counter_process',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'items',
                type: BridgeType(name: 'List<String>', isRecord: true, recordListItemType: 'String', recordListItemIsPrimitive: true),
              ),
            ],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('std::vector<std::string>'));
    });

    test('AnyNativeObject maps to int64_t', () {
      final spec = makeCounterSpec(
        functions: [
          BridgeFunction(
            dartName: 'getHandle',
            cSymbol: 'counter_get_handle',
            isAsync: false,
            returnType: BridgeType(name: 'AnyNativeObject', isAnyNativeObject: true),
            params: [],
          ),
        ],
      );
      final out = CppSpecGenerator.generate(spec);
      expect(out, contains('virtual int64_t getHandle()'));
    });
  });
}
