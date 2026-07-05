import 'any_native_object.dart';

/// Dart-side registry mapping native instance IDs to live impl objects.
///
/// Every generated `_XxxImpl` registers itself on construction and
/// auto-unregisters when GC'd (via [Finalizer]) or when [dispose()] is called.
///
/// This enables zero-native-call downcasting:
/// ```dart
/// AnyNativeObject ref = plugin.getRef();
/// final foo = NitroInstanceRegistry.resolve<Foo>(ref); // typed, no C round-trip
/// ```
///
/// Only resolves instances created in the same Dart isolate — Dart isolates
/// have separate heaps and independent registries.
class NitroInstanceRegistry {
  NitroInstanceRegistry._();

  static final _registry = <int, WeakReference<Object>>{};

  // Automatically removes the entry when the impl is GC'd without dispose().
  static final _finalizer = Finalizer<int>((id) => _registry.remove(id));

  /// Registers [instance] under [id]. Called by every generated `_XxxImpl` constructor.
  static void register(int id, Object instance) {
    _registry[id] = WeakReference(instance);
    _finalizer.attach(instance, id, detach: instance);
  }

  /// Removes [instance] from the registry. Called from [dispose()].
  static void unregister(int id, Object instance) {
    _finalizer.detach(instance);
    _registry.remove(id);
  }

  /// Returns the registered instance for [ref] cast to [T], or null if not
  /// found, already disposed, or GC'd before this call.
  static T? resolve<T extends Object>(AnyNativeObject ref) => _registry[ref.instanceId]?.target as T?;
}
