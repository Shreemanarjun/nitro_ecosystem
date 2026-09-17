/// Web twin of `NitroCompletionBatch`: the web bridge has no ports and never
/// batches; generated web code does not construct it.
class NitroCompletionBatch {
  NitroCompletionBatch({required this.bind, required this.ack});
  final int Function(int batchPort) bind;
  final void Function(int batchPort) ack;
  int get nativePort => 0;
  Never get sendPort => throw UnsupportedError('NitroCompletionBatch is native-only');
  int register(void Function(dynamic raw) onComplete) => throw UnsupportedError('NitroCompletionBatch is native-only');
  void forget(int id) {}
  int get pendingCount => 0;
}
