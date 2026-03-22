// Every spec abstract class extends this.
// The generator checks for this supertype to confirm the class is a valid spec.
abstract class HybridObject {
  void onMemoryTrim() {}  // Android: onTrimMemory signal
  void onDestroy() {}     // Dart object GC'd — release native resources
}
