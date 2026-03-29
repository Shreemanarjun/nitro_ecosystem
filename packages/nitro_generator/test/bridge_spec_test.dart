import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeSpec.isCppImpl', () {
    test('returns true when both platforms are C++', () {
      final spec = BridgeSpec(
        dartClassName: 'Bar',
        lib: 'bar',
        namespace: 'bar',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'bar.native.dart',
      );
      expect(spec.isCppImpl, isTrue);
    });

    test('returns false when only iOS is C++', () {
      final spec = BridgeSpec(
        dartClassName: 'Bar',
        lib: 'bar',
        namespace: 'bar',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'bar.native.dart',
      );
      expect(spec.isCppImpl, isFalse);
    });

    test('returns false when only Android is C++', () {
      final spec = BridgeSpec(
        dartClassName: 'Bar',
        lib: 'bar',
        namespace: 'bar',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'bar.native.dart',
      );
      expect(spec.isCppImpl, isFalse);
    });

    test('returns false when neither are C++', () {
      final spec = BridgeSpec(
        dartClassName: 'Bar',
        lib: 'bar',
        namespace: 'bar',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'bar.native.dart',
      );
      expect(spec.isCppImpl, isFalse);
    });
  });
}
