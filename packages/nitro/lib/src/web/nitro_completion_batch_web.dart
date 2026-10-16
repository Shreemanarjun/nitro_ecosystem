/// Web twin of `NitroCompletionBatch`: the web bridge has no ports and never
/// batches; generated web code does not construct it.
class NitroCompletionBatch {
  NitroCompletionBatch({required this.bind, required this.ack, this.arm, this.poll});
  final int Function(int batchPort) bind;
  final void Function(int batchPort) ack;
  // No dart:ffi on web (Pointer is unavailable): the spin slot is native-only,
  // so these are untyped placeholders the web build never invokes.
  final Object? arm;
  final Object? poll;
  int get nativePort => 0;
  Never get sendPort => throw UnsupportedError('NitroCompletionBatch is native-only');
  int register(void Function(dynamic raw) onComplete) => throw UnsupportedError('NitroCompletionBatch is native-only');
  void forget(int id) {}
  int get pendingCount => 0;
  void armSpin(int id) {}
  List<dynamic>? spinPoll(int id, int spinUs) => null;
}
