// Tests for stream implementations with @HybridEnum and @HybridStruct item types.
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _torchStreamSpec() => BridgeSpec(
  dartClassName: 'NitroTorch',
  lib: 'nitro_torch',
  namespace: 'nitro_torch',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  macosImpl: NativeImpl.swift,
  windowsImpl: NativeImpl.cpp,
  linuxImpl: NativeImpl.cpp,
  sourceUri: 'nitro_torch.native.dart',
  structs: [
    BridgeStruct(
      name: 'TorchLevel',
      packed: false,
      fields: [
        BridgeField(name: 'level', type: BridgeType(name: 'int')),
        BridgeField(name: 'maxLevel', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  enums: [
    BridgeEnum(name: 'TorchState', startValue: 0, values: ['on', 'off']),
  ],
  streams: [
    BridgeStream(
      dartName: 'onTorchStateChanged',
      registerSymbol: 'nitro_torch_register_on_torch_state_changed_stream',
      releaseSymbol: 'nitro_torch_release_on_torch_state_changed_stream',
      itemType: BridgeType(name: 'TorchState'),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'onLevelChanged',
      registerSymbol: 'nitro_torch_register_on_level_changed_stream',
      releaseSymbol: 'nitro_torch_release_on_level_changed_stream',
      itemType: BridgeType(name: 'TorchLevel'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
  functions: [],
);

BridgeSpec _specWithStreamItemType(String typeName) => BridgeSpec(
  dartClassName: 'TestModule',
  lib: 'test_module',
  namespace: 'test_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'test_module.native.dart',
  structs: [
    BridgeStruct(
      name: 'TorchLevel',
      packed: false,
      fields: [
        BridgeField(name: 'level', type: BridgeType(name: 'int')),
        BridgeField(name: 'maxLevel', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  enums: [
    BridgeEnum(name: 'TorchState', startValue: 0, values: ['on', 'off']),
  ],
  streams: [
    BridgeStream(
      dartName: 'onChanged',
      registerSymbol: 'test_module_register_on_changed_stream',
      releaseSymbol: 'test_module_release_on_changed_stream',
      itemType: BridgeType(name: typeName),
      backpressure: Backpressure.dropLatest,
    ),
  ],
  functions: [],
);

void main() {
  group('Stream implementations with @HybridEnum and @HybridStruct', () {
    test('generates enum stream with correct unpack expression', () {
      final out = DartFfiGenerator.generate(_torchStreamSpec());
      expect(out, contains("Stream<TorchState> get onTorchStateChanged"));
      expect(out, contains("(message as int).toTorchState()"));
    });

    test('generates struct stream with Proxy unpack expression', () {
      final out = DartFfiGenerator.generate(_torchStreamSpec());
      expect(out, contains("Stream<TorchLevel> get onLevelChanged"));
      expect(out, contains("TorchLevelProxy(Pointer<TorchLevelFfi>.fromAddress"));
    });

    test('generates register and release pointers for streams', () {
      final out = DartFfiGenerator.generate(_torchStreamSpec());
      expect(out, contains("_registerOnTorchStateChangedPtr"));
      expect(out, contains("_releaseOnTorchStateChangedPtr"));
      expect(out, contains("_registerOnLevelChangedPtr"));
      expect(out, contains("_releaseOnLevelChangedPtr"));
    });
  });

  group('Stream item type validation', () {
    test('TorchState enum stream passes validation', () {
      final spec = _specWithStreamItemType('TorchState');
      final issues = SpecValidator.validate(spec);
      final streamIssues = issues.where((i) => i.code == 'UNKNOWN_STREAM_ITEM_TYPE').toList();
      expect(streamIssues, isEmpty, reason: 'Stream with @HybridEnum item type should not fail validation');
    });

    test('TorchLevel struct stream passes validation', () {
      final spec = _specWithStreamItemType('TorchLevel');
      final issues = SpecValidator.validate(spec);
      final streamIssues = issues.where((i) => i.code == 'UNKNOWN_STREAM_ITEM_TYPE').toList();
      expect(streamIssues, isEmpty, reason: 'Stream with @HybridStruct item type should not fail validation');
    });

    test('nullable enum stream passes validation', () {
      final spec = BridgeSpec(
        dartClassName: 'TestModule',
        lib: 'test_module',
        namespace: 'test_module',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test_module.native.dart',
        enums: [
          BridgeEnum(name: 'TorchState', startValue: 0, values: ['on', 'off']),
        ],
        streams: [
          BridgeStream(
            dartName: 'onChanged',
            registerSymbol: 'test_module_register_on_changed_stream',
            releaseSymbol: 'test_module_release_on_changed_stream',
            itemType: BridgeType(name: 'TorchState?', isNullable: true),
            backpressure: Backpressure.dropLatest,
          ),
        ],
        functions: [],
      );
      final issues = SpecValidator.validate(spec);
      final streamIssues = issues.where((i) => i.code == 'UNKNOWN_STREAM_ITEM_TYPE').toList();
      expect(streamIssues, isEmpty, reason: 'Stream with nullable @HybridEnum item type should not fail validation');
    });
  });
}
