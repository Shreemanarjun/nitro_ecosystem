/// Web-only runtime surface used by generated `.web.bridge.g.dart` files:
/// the loaded-module wrapper and the port registry. On native builds the
/// barrel swaps this for an empty stub.
library;

export 'nitro_wasm_module.dart';
export 'port_registry.dart';
