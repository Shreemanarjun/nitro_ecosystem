// Pure-Dart stand-in for dart:ui's PluginUtilities so native_to_dart_capability_test
// COMPILES under `dart test` (dart:ui is Flutter-only). The one dart:ui-dependent
// test skips when [hasDartUi] is false; `flutter test` pulls the real dart:ui via
// the conditional import's other arm (plugin_utilities_ui.dart).
const bool hasDartUi = false;

class CallbackHandle {}

abstract final class PluginUtilities {
  static CallbackHandle? getCallbackHandle(Function callback) => null;
  static Function? getCallbackFromHandle(CallbackHandle handle) => null;
}
