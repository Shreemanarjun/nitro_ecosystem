# How the generator is organised

This is a map of `packages/nitro_generator` for someone about to change it. It says where each
piece lives, which tables are the single source for a decision, and how to prove a change works.

## The pipeline

A `*.native.dart` spec goes through three steps:

1. **Extract** (`lib/src/spec_extractor.dart`). The analyzer's resolved types become a `BridgeSpec`
   (`lib/src/bridge_spec.dart`): functions, properties, streams, structs, records, variants, enums.
   Every later step reads only this model. The steps are in `lib/src/extraction/`:
   `platform_impls`, `declared_types`, `imported_types`, `bridge_types` (Dart type → `BridgeType`,
   where a new bridged type is recognised first) and `members`.
2. **Validate** (`lib/src/spec_validator.dart`). Rules turn an unsupported spec into an error with a
   code and a hint, so nothing unsupported reaches a native compiler.
3. **Generate** (`lib/src/generators/languages/<backend>/`). One generator per output file.

| Backend | Folder | Output |
|---|---|---|
| Dart (dart:ffi) | `languages/dart/` | `*.g.dart`, `*.ffi.g.dart` |
| Web (dart:js_interop) | `languages/web/` | `*.web.bridge.g.dart` |
| C bridge (JNI, Swift shim, C++ dispatch) | `languages/c_bridge/` | `*.bridge.g.h`, `*.bridge.g.cpp` |
| Kotlin | `languages/kotlin/` | `*.bridge.g.kt` |
| Swift | `languages/swift/` | `*.bridge.g.swift` |
| C++ interface, starter, mock | `languages/cpp_native/` | `*.native.g.h`, `*.impl.g.cpp`, `*.mock.g.h` |
| Records, structs, enums, variants (all languages) | `generators/record/`, `*_generator.dart` | embedded in the files above |

## Where a rule or an emitter lives

Large generators are one small file that picks a path, plus one file per concern.

**Validator** — `spec_validator.dart` runs the rule groups in order. Each group is a file in
`lib/src/validation/`: `platform_rules`, `function_rules`, `property_rules`, `stream_rules`,
`type_rules`, `result_rules`, `struct_rules`, `callback_rules`, `map_rules`, `entry_point_rules`.
They share `_Rules` (`rules.dart`): the spec, the name sets and the issue list. A new rule goes in the
group it belongs to; a new group is one more extension on `_Rules` and one more call in `validate`.

**C bridge** — `cpp_bridge_generator.dart` chooses between three paths. The emitters are in
`c_bridge/cpp_bridge/`:

| File | What it emits |
|---|---|
| `c_types.dart` | Dart type → C type, JNI type and JNI signature |
| `jni_function_emitter.dart`, `jni_property_emitter.dart`, `jni_stream_emitter.dart` | JNI glue for Kotlin |
| `jni_callback_invokers.dart`, `jni_initialize_emitter.dart` | Kotlin → Dart callbacks, `JNI_OnLoad` caches, `post*ToPort` |
| `swift_shim_emitter.dart` | calls into the Swift `@_cdecl` stubs |
| `cpp_dispatch_emitter.dart` | C++ dispatch inside a mixed module (Apple or desktop is C++) |
| `cpp_direct_emitter.dart` | the whole bridge of an all-C++ module |
| `cpp_callback_adapter.dart`, `cpp_result_emitter.dart`, `cpp_instance_registry.dart` | shared by both C++ paths |
| `struct_helpers.dart`, `type_emitter.dart` | `@HybridStruct` copies, guards, C ↔ JNI packing |
| `worker_dispatch.dart` | async completion: batch, `_dispatch`, `_fnf` |

The two C++ paths still emit similar code for the same job. A fix to one usually belongs in the
other; put shared logic in one of the shared files rather than copying it.

**Web** — `web_bridge_generator.dart` plus `web/web_bridge/`: `web_members` (methods, properties,
streams), `web_arguments`, `web_returns`, `web_callbacks`, `web_structs`, `web_codecs`.

**Swift functions** — `swift_function_emitter.dart` plus `swift/emitters/function/`: one file per
dispatch mode (`swift_sync`, `swift_async`, `swift_native_async`), `swift_arguments`, `swift_returns`.

**Kotlin functions** — `kotlin/emitters/kotlin_function_emitter.dart`; maps are in
`kotlin_map_emitter.dart` (Swift: `swift_map_emitter.dart`).

## One source for each decision

Five backends encode the same value independently. When they each re-derived a decision, they
drifted. These are the shared answers; switch over them instead of writing a new `if` ladder.

| Question | Answer lives in |
|---|---|
| How does a `@NitroResult` value travel? | `BridgeSpec.resultCarrier` → sealed `ResultCarrier` |
| What is a map value, and which tag does it get? | `map_wire.dart`: `MapValueKind`, `MapValueWire`, `stringMapValueType` |
| Which structs can cross as bytes? | `BridgeSpec.isFlatStruct`, `structsCarriedAsBytes`, `structsNeedingByteCodec` |
| Does a callback return a block? | `BridgeSpec.callbackReturnsBlock` |
| What does a C++ implementation's method look like? | `CppInterfaceGenerator.methodSignatureFor` (interface, starter and mock all use it) |
| Is a type name nullable / what is its bare name? | `bareTypeName` (never `replaceFirst('?', '')`: it strips the inner `?` of `Map<String, int?>`) |

Because the switches are exhaustive, adding a case to one of these enums or sealed classes fails to
compile in every backend that has not handled it. That is the intended way to find the work.

## Adding support for a type

1. Decide the wire format and write it down in `doc/wire_format.md`.
2. Extend the model (`BridgeType`, or one of the tables above) and the extractor.
3. Follow the compile errors through the backends.
4. Relax or add the validator rule, with a hint that names the fix.
5. Prove it (next section).

## Proving a change

Text-level tests cannot tell whether generated code compiles or runs. Each layer below has caught
bugs the one above it missed.

| Check | Command (from `packages/nitro_generator`) | Catches |
|---|---|---|
| Unit tests | `dart test` | wrong text, validator rules |
| C++ compiles | `dart run tool/verify_cpp_bridge_compiles.dart` | bridge, interface and starter that do not build. Add `NITRO_CXX_TARGETS_DESKTOP=1 CXX=x86_64-w64-mingw32-g++` for the desktop blocks; `em++` on `PATH` adds the web build |
| Wire agreement | `dart run tool/verify_record_wire.dart --require=cpp,swift,kotlin` | two languages disagreeing on bytes |
| Other gates | `tool/verify_cpp_indexed_list.dart`, `verify_native_assets_analyzes.dart`, `verify_record_lend.dart` | their named areas |
| Release symbols | `dart run tool/verify_release_symbols.dart` (see its header) | a symbol Dart looks up that stripping removed |
| A real device | the `nitro_type_coverage` plugin's integration test on macOS, an iOS simulator and an Android emulator | everything else: JNI type checks, Swift type errors, ownership, crashes |

When a refactor must not change output, regenerate a plugin before and after and `diff -r` the
generated files. The splits described above were checked that way.

Put a new shape in the compile gate (`_mapShapesSpec`, `_typedDataReturnSpec`,
`_callbackAndStructSpec` are examples) and in the type-coverage plugin, not only in a text test.
