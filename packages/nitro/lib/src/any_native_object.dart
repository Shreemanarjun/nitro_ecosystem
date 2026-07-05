/// An opaque reference to any registered native implementation.
///
/// Equivalent to RN Nitro's `AnyHybridObject`. Wire format: `int64_t` instance
/// ID — the same integer the bridge uses internally for every native impl.
///
/// Obtain one from a generated `_XxxImpl` via the [asAnyNativeObject] getter
/// that the code generator adds to every bridge implementation class:
///
/// ```dart
/// // Plugin A exposes a Camera hybrid object.
/// final camera = CameraImpl();
/// final ref = camera.asAnyNativeObject;  // AnyNativeObject(instanceId: 3)
///
/// // Plugin B accepts an opaque ref — doesn't need to know about Camera.
/// await pluginB.processObject(ref);
/// ```
///
/// On the native side (Kotlin/Swift/C++) the bridge passes the raw `int64_t`.
/// The receiving plugin can look the instance up in its own registry to recover
/// the concrete type — identical to how RN Nitro's `AnyHybridObject` works.
class AnyNativeObject {
  final int instanceId;
  const AnyNativeObject(this.instanceId) : assert(instanceId >= 0, 'AnyNativeObject: instanceId must be ≥ 0; use null for absent objects');

  @override
  bool operator ==(Object other) => other is AnyNativeObject && other.instanceId == instanceId;

  @override
  int get hashCode => instanceId.hashCode;

  @override
  String toString() => 'AnyNativeObject(instanceId: $instanceId)';
}
