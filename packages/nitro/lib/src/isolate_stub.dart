/// Stub for dart:isolate types on web.
///
/// On web platforms dart:isolate is unavailable. This file stubs out
/// ReceivePort and SendPort so that shared Dart code (and generated part
/// files) that import `package:nitro/nitro.dart` can still parse and analyse
/// on the web target. Any runtime use will throw via [NitroRuntime]'s web
/// stub.
library;

// ignore_for_file: unused_element

class ReceivePort {
  Stream<dynamic> get first => throw UnsupportedError('ReceivePort not available on web');
  SendPort get sendPort => throw UnsupportedError('ReceivePort not available on web');
  void close() => throw UnsupportedError('ReceivePort not available on web');
  void listen(void Function(dynamic) onData) => throw UnsupportedError('ReceivePort not available on web');
}

class SendPort {
  int get nativePort => throw UnsupportedError('SendPort not available on web');
}
