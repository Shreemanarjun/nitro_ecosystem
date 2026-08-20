import 'dart:async';

/// Registry mapping integer port ids to message handlers — the web analog of
/// the VM's native-port table.
///
/// On native, generated code hands `ReceivePort.sendPort.nativePort` to C,
/// which posts via `Dart_PostCObject_DL`. On web, C posts through a
/// function-table callback carrying the same int64 port id; the module load
/// path decodes the payload and calls [deliver]. Pure Dart — unit-testable
/// without a WASM module.
final class NitroWebPorts {
  NitroWebPorts._();

  // Port 0 is reserved so a zeroed field can never address a live port.
  static int _nextId = 1;
  static final Map<int, void Function(dynamic raw)> _handlers = {};

  /// Registers [handler] and returns its port id.
  static int allocate(void Function(dynamic raw) handler) {
    final id = _nextId++;
    _handlers[id] = handler;
    return id;
  }

  /// Closes a port. Posts to a closed port are dropped, mirroring
  /// `Dart_PostCObject` on a closed native port.
  static void close(int port) => _handlers.remove(port);

  /// Delivers a decoded message to [port]'s handler. Returns false when the
  /// port is closed (message dropped).
  static bool deliver(int port, dynamic raw) {
    final handler = _handlers[port];
    if (handler == null) return false;
    handler(raw);
    return true;
  }

  /// Number of open ports (for tests and leak diagnostics).
  static int get openCount => _handlers.length;
}

/// Web stand-in for `dart:isolate`'s ReceivePort, backed by [NitroWebPorts].
///
/// Exposes the members the runtime's native-async and stream plumbing uses
/// (`sendPort.nativePort`, `first`, `listen`, `close`) so that logic ports
/// over from the native runtime nearly verbatim.
final class WebReceivePort {
  final int port;
  final StreamController<dynamic> _controller = StreamController<dynamic>();

  WebReceivePort() : port = NitroWebPorts.allocate(_noop) {
    // Rebind to the controller now that it exists.
    NitroWebPorts._handlers[port] = _controller.add;
    _sendPort = WebSendPort._(this);
  }

  static void _noop(dynamic _) {}

  late final WebSendPort _sendPort;

  /// Facade mirroring `ReceivePort.sendPort`.
  WebSendPort get sendPort => _sendPort;

  /// Completes with the first message, mirroring `ReceivePort.first`.
  Future<dynamic> get first => _controller.stream.first;

  StreamSubscription<dynamic> listen(void Function(dynamic message) onData) => _controller.stream.listen(onData);

  void close() {
    NitroWebPorts.close(port);
    _controller.close();
  }
}

/// Facade mirroring `SendPort` for [WebReceivePort].
final class WebSendPort {
  final WebReceivePort _owner;
  WebSendPort._(this._owner);

  /// The int port id handed to the WASM module — the web analog of
  /// `SendPort.nativePort`.
  int get nativePort => _owner.port;

  /// Local delivery, mirroring `SendPort.send` (used by tests to inject
  /// messages without a WASM module).
  void send(dynamic message) => NitroWebPorts.deliver(_owner.port, message);
}
