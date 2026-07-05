import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';

void main() {
  final filterVariant = BridgeVariant(
    name: 'FilterResult',
    cases: [
      BridgeVariantCase(
        name: 'FilterAccepted',
        label: 'accepted',
        fields: [
          BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
        ],
      ),
      BridgeVariantCase(name: 'FilterRejected', label: 'rejected', fields: []),
    ],
  );

  final spec = BridgeSpec(
    dartClassName: 'Foo',
    lib: 'foo',
    namespace: 'foo',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'foo.native.dart',
    variants: [filterVariant],
    isTypeOnly: true,
  );

  print(KotlinGenerator.generate(spec));
}
