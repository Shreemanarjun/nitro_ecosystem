/// Stub for dart:ffi types on web.
///
/// On web platforms dart:ffi is unavailable. This file provides MARKER TYPES
/// ONLY — enough for platform-neutral spec code like `NativeHandle<Void>` to
/// compile. It deliberately does NOT stub `Pointer`, `DynamicLibrary`,
/// `Struct`, allocators, or any other functional dart:ffi API: code that
/// dereferences native memory must not exist in a web build (the generator
/// splits such code into a native-only library), and a missing name at
/// compile time beats an UnsupportedError at runtime.
library;

/// Marker supertype mirroring dart:ffi's [NativeType].
abstract final class NativeType {}

/// Marker mirroring dart:ffi's [Void] (e.g. `NativeHandle<Void>`).
abstract final class Void extends NativeType {}

/// Marker mirroring dart:ffi's [Opaque] (base for opaque handle types).
abstract base class Opaque extends NativeType {}

/// Minimal opaque `Pointer<T>` so spec signatures with raw-pointer escape
/// hatches still compile on web. It is an int address and nothing more —
/// no dereference, no typed views. On web the address is a wasm linear-memory
/// offset (or whatever the impl chose to hand out).
final class Pointer<T extends NativeType> {
  final int address;
  const Pointer.fromAddress(this.address);

  @override
  String toString() => 'Pointer<$T>(0x${address.toRadixString(16)})';
}

/// Markers for the fixed-width dart:ffi types, so type-parameter positions
/// in shared code keep compiling on web.
abstract final class Int8 extends NativeType {}

abstract final class Int16 extends NativeType {}

abstract final class Int32 extends NativeType {}

abstract final class Int64 extends NativeType {}

abstract final class Uint8 extends NativeType {}

abstract final class Uint16 extends NativeType {}

abstract final class Uint32 extends NativeType {}

abstract final class Uint64 extends NativeType {}

abstract final class Float extends NativeType {}

abstract final class Double extends NativeType {}

abstract final class Bool extends NativeType {}

abstract final class IntPtr extends NativeType {}
