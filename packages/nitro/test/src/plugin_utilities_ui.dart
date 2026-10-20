// Flutter arm of the conditional import: the real dart:ui PluginUtilities, used
// under `flutter test` (where dart.library.ui is available).
export 'dart:ui' show PluginUtilities, CallbackHandle;

const bool hasDartUi = true;
