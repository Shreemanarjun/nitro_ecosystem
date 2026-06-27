/// Discriminated success/error result for native methods annotated with
/// `@NitroResult()`.
///
/// Wire format returned by the native side: `[1B tag: 0=ok, 1=err][payload]`
///
/// - Tag 0 (ok): payload = record-codec bytes for T
/// - Tag 1 (err): payload = record-codec string (4B length + UTF-8 message)
///
/// Dart receives either [NitroOk<T>] or [NitroErr<T>] without an exception
/// being thrown. Call sites pattern-match on the sealed type:
///
/// ```dart
/// final result = await module.login(user, pass);
/// switch (result) {
///   case NitroOk(:final value): print('Logged in: $value');
///   case NitroErr(:final message): print('Login failed: $message');
/// }
/// ```
sealed class NitroResultValue<T extends Object?> {
  const NitroResultValue();
}

/// Success case — carries the native return value.
final class NitroOk<T extends Object?> extends NitroResultValue<T> {
  final T value;
  const NitroOk(this.value);

  @override
  String toString() => 'NitroOk($value)';

  @override
  bool operator ==(Object other) =>
      other is NitroOk<T> && other.value == value;

  @override
  int get hashCode => Object.hash('NitroOk', value);
}

/// Failure case — carries the native-side error message.
final class NitroErr<T extends Object?> extends NitroResultValue<T> {
  final String message;
  const NitroErr(this.message);

  @override
  String toString() => 'NitroErr($message)';

  @override
  bool operator ==(Object other) =>
      other is NitroErr<T> && other.message == message;

  @override
  int get hashCode => Object.hash('NitroErr', message);
}
