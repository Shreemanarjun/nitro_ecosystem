// Two @HybridEnum cases sharing a raw value cannot round-trip: the wire
// carries the number, so decode picks whichever case the generated lookup
// reaches first and the other becomes unreachable. It also produced duplicate
// Dart switch cases and a Swift enum with two identical raw values — neither
// of which was reported.
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _enumSpec(List<String> values, List<int>? rawValues) => BridgeSpec(
  dartClassName: 'M',
  lib: 'm',
  namespace: 'm',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'm.native.dart',
  enums: [BridgeEnum(name: 'E', startValue: 0, values: values, rawValues: rawValues)],
);

Iterable<ValidationIssue> _e020(BridgeSpec s) => SpecValidator.validate(s).where((i) => i.code == 'E020');

void main() {
  test('duplicate raw values are an error', () {
    final issues = _e020(_enumSpec(['low', 'mid', 'high'], [1, 5, 1])).toList();
    expect(issues, hasLength(1));
    expect(issues.single.isError, isTrue);
    expect(issues.single.message, contains('high'));
    expect(issues.single.message, contains('low'));
    expect(issues.single.message, contains('1'));
  });

  test('distinct raw values are accepted, contiguous or not', () {
    expect(_e020(_enumSpec(['a', 'b', 'c'], [0, 50, 100])), isEmpty);
    expect(_e020(_enumSpec(['a', 'b', 'c'], [0, 1, 2])), isEmpty);
    expect(_e020(_enumSpec(['a', 'b'], [-1, 1])), isEmpty, reason: 'negative values are still distinct');
  });

  test('an enum without explicit rawValues is never flagged', () {
    // Implicit values are contiguous by construction, so they cannot collide.
    expect(_e020(_enumSpec(['a', 'b', 'c'], null)), isEmpty);
  });

  test('every duplicated pair is reported, not just the first', () {
    final issues = _e020(_enumSpec(['a', 'b', 'c', 'd'], [7, 7, 9, 9])).toList();
    expect(issues, hasLength(1));
    expect(issues.single.message, contains('b'));
    expect(issues.single.message, contains('d'));
  });

  test('a three-way collision is reported', () {
    final issues = _e020(_enumSpec(['a', 'b', 'c'], [3, 3, 3])).toList();
    expect(issues, hasLength(1));
    expect(issues.single.message, contains('b'));
    expect(issues.single.message, contains('c'));
  });

  // A mismatched rawValues length is unconstructible — BridgeEnum asserts it.
  // The validator still guards for it because assertions are debug-only.
}
