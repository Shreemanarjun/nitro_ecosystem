// On Android a nullable scalar struct field is `Long?`/`Double?`/`Boolean?` on
// the Kotlin data class, so the JNI constructor takes a BOXED object. Emitting
// the primitive descriptor made GetMethodID("<init>") return null and the
// process aborted with SIGABRT during plugin registration — before any test
// could run.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _spec(List<BridgeField> fields) => BridgeSpec(
  dartClassName: 'M',
  lib: 'm',
  namespace: 'm',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'm.native.dart',
  structs: [BridgeStruct(name: 'S', packed: false, fields: fields)],
  functions: [
    BridgeFunction(
      dartName: 'echo', cSymbol: 'm_echo', isAsync: false,
      returnType: BridgeType(name: 'S'),
      params: [BridgeParam(name: 'v', type: BridgeType(name: 'S'))],
    ),
  ],
);

void main() {
  final out = CppBridgeGenerator.generate(_spec([
    BridgeField(name: 'count', type: BridgeType(name: 'int?')),
    BridgeField(name: 'ratio', type: BridgeType(name: 'double?')),
    BridgeField(name: 'flag', type: BridgeType(name: 'bool?')),
    BridgeField(name: 'keep', type: BridgeType(name: 'int')),
  ]));

  test('the ctor descriptor uses boxed types for nullable fields only', () {
    expect(out, contains('"<init>", "(Ljava/lang/Long;Ljava/lang/Double;Ljava/lang/Boolean;J)V"'));
    expect(out, isNot(contains('"<init>", "(JDZJ)V"')), reason: 'primitive descriptor aborts at registration');
  });

  test('field IDs match the boxed descriptor', () {
    expect(out, contains('"count", "Ljava/lang/Long;"'));
    expect(out, contains('"ratio", "Ljava/lang/Double;"'));
    expect(out, contains('"flag", "Ljava/lang/Boolean;"'));
    expect(out, contains('"keep", "J"'), reason: 'the non-nullable neighbour stays primitive');
  });

  test('struct → jobject boxes via valueOf, and passes null when absent', () {
    expect(out, contains('jobject j_count = nullptr;'));
    expect(out, contains('if (st->countHasValue) {'));
    expect(out, contains('"valueOf", "(J)Ljava/lang/Long;"'));
    expect(out, contains('"valueOf", "(D)Ljava/lang/Double;"'));
    expect(out, contains('"valueOf", "(Z)Ljava/lang/Boolean;"'));
  });

  test('jobject → struct unboxes and sets the presence byte', () {
    expect(out, contains('result.countHasValue = 0;'));
    expect(out, contains('result.countHasValue = 1;'));
    expect(out, contains('"longValue", "()J"'));
    expect(out, contains('"doubleValue", "()D"'));
    expect(out, contains('"booleanValue", "()Z"'));
    // The old unconditional primitive read must be gone for nullable fields.
    expect(out, isNot(contains('result.count = env->GetLongField')));
  });

  test('boxed locals are released after NewObject', () {
    expect(out, contains('if (j_count) env->DeleteLocalRef(j_count);'));
  });

  test('a struct with no nullable scalars is completely unaffected', () {
    final plain = CppBridgeGenerator.generate(_spec([
      BridgeField(name: 'a', type: BridgeType(name: 'int')),
      BridgeField(name: 'b', type: BridgeType(name: 'double')),
    ]));
    expect(plain, contains('"<init>", "(JD)V"'));
    expect(plain, isNot(contains('Ljava/lang/Long;')));
    expect(plain, isNot(contains('HasValue')));
  });
}
