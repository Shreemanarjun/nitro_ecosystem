# Promoting the `@Native` / native-assets path toward default

Status: **plan / design** (no code change yet). Owner: TBD. Target: 0.9.x.

## Why

The default `_dylib` path resolves FFI entry points at runtime by name —
`DynamicLibrary.process()` → `dlsym(RTLD_DEFAULT, "<lib>_<fn>")` on iOS/macOS,
`DynamicLibrary.open()` elsewhere (`nitro/lib/src/nitro_runtime.dart`
`loadLib`). Resolving by name is fragile at exactly the platform seams:

- **iOS/macOS archive strip** (`STRIP_STYLE=all`) drops the exports → `dlsym`
  fails in release/TestFlight builds (nitro_http#3; fixed defensively in 0.8.1
  with `REFERENCED_DYNAMICALLY`, but it is still a name lookup).
- **Android `RTLD_LOCAL`** hides the `.so`'s symbols from `lookupFunction` —
  the reason `@Native` exists at all.

The `@Native` / native-assets path binds each symbol at **link** time against a
code asset built by `hook/build.dart`, so there is no runtime name lookup and
no reliance on the host executable's export table. It is immune to both failure
modes.

### Cross-check: this is how RN Nitro avoids the whole class

`margelo/nitro` (0.37.x) never uses `dlsym` (grep: zero hits) and has **zero**
strip/`STRIP_STYLE`/exported-symbol handling anywhere — because JSI resolves
HybridObjects through a C++ **registry** (`HybridObjectRegistry::registerHybridObjectConstructor`,
invoked from a generated `<Module>Autolinking` at load). The impl constructors
are *referenced* by that registration, so the linker keeps them and nothing is
looked up by name. Our `@Native` path is the Dart-FFI analog: link-time binding,
no runtime name lookup. Promoting it toward default is how we retire the class
structurally rather than patching each symptom.

## Current state (0.8.1)

- **Opt-in only.** `nitrogen generate --native-assets` → `--define nitro_generator:nitro_generator=native_assets=true`
  (`nitrogen_cli/.../generate_command.dart`) → `NitroGeneratorBuilder(nativeAssets: …)`
  (`nitro_generator/lib/builder.dart`). Default `nativeAssets = false`
  (`bridge_spec.dart`). No `--no-native-assets` opt-out.
- **Gated** to `useNativeAssets = nativeAssets && allNativeCpp && !targetsWeb`
  (`bridge_spec.dart`), then a per-spec shape check
  (`_nativeAssetsIneligibility`, `dart_impl_class_emitter.dart`). Ineligible
  modules auto-fall back to `_dylib` — `nativeAssetsEmit` is the single source
  of truth, read by both the impl-class and struct-proxy emitters.
- **Stable toolchain.** The hook uses `package:hooks ^2.2.0` + `code_assets ^2.1.0`
  (stable; no `--enable-experiment`), SDK `^3.11.3`. The "Experimental" label in
  the CLI help is nitro's own maturity tag, not a Dart gate.
- **Double-bundle is only warned.** `_warnDoubleBundle` (`link/native_assets.dart`)
  tells the user to drop `ffiPlugin: true` / `pluginClass:` manually; `nitrogen
  doctor` fails on the same condition. Nothing auto-resolves it.
- `nitrogen init` scaffolds the `_dylib` + `ffiPlugin` path (`flutter create
  --template=plugin_ffi`).

## Blockers to a blanket default

1. **Double-bundle (the hard one).** A module delivered as a code asset must not
   *also* compile/bundle the same bridge+engine through its platform native
   build (`ffiPlugin` → podspec/SPM/gradle/CMake). Two engine copies → two C++
   runtimes → split-brain / double-free. Making `@Native` default requires this
   to be **auto-resolved**, not warned.
2. **Eligibility is per-module.** CBuilder compiles C/C++ only — Swift/Kotlin
   modules and web can never be `@Native`. A mixed project (some C++, some
   Swift/Kotlin modules) must deliver the C++ ones via the hook **and** keep the
   platform build for the others, without the platform build double-bundling the
   C++ ones. Neutralization is therefore **per-module**, not per-project.
3. **Migration for existing modules.** Flipping the `generate` default switches
   every eligible all-C++ module on next regen; each then needs the hook and its
   platform build neutralized. Must be a no-surprise, guided transition.

## Double-bundle auto-resolution — design (the crux)

Goal: when module M is delivered as a code asset, **no platform build compiles
M's bridge/engine**, while platform builds for non-`@Native` modules are
untouched. `nitrogen link` owns this — it already rewrites platform files and
knows each module's `nativeAssetsEmit`.

Per surface, when M is `@Native`:

| Surface | Today (`_dylib`) | `@Native` resolution |
|---|---|---|
| pubspec `flutter.plugin.platforms.<p>.ffiPlugin` | present → Flutter builds+bundles | leave the plugin shell, but its build must compile nothing for M (see below). Dropping `ffiPlugin` entirely is simpler but loses platform glue needed by sibling non-`@Native` modules — so neutralize, don't delete. |
| iOS/macOS podspec / SPM target | compiles `M.bridge.g.*` + vendors nitro headers | **omit M's bridge sources**; the hook's CBuilder compiles + vendors them. Keep the target only if a sibling `_dylib`/Swift module needs it. |
| Android `CMakeLists.txt` / gradle | `add_library` builds M's `.so` | **drop M's `add_library`/sources**; the hook builds M's code asset. |
| Windows/Linux `CMakeLists.txt` | compiles `M.bridge.g.cpp` + `dart_api_dl.c` | **drop M's sources** from the shared `src/CMakeLists.txt`. |

Mechanics:

- **Detection:** `nitrogen link` reads each module's emit mode (the generated
  `*.ffi.g.dart` carries `@Native` externals; equivalently a per-module marker
  the generator can stamp). Build only the modules whose emit mode is `_dylib`
  into the platform files; exclude the `@Native` ones.
- **Header vendoring:** the `_dylib` path vendors nitro's `src/native` headers
  into the platform build; the `@Native` path vendors them into the hook's
  `src/nitro_native/` (CBuilder). Link must route vendoring to whichever each
  module uses.
- **Empty-shell case:** if *every* module in the project is `@Native`, the
  platform native builds compile nothing. Then it is safe to drop `ffiPlugin`
  and the platform dirs entirely (pure-Dart-plus-hook, the nitro_server shape).
  Detect "all modules @Native" and offer/emit that clean end-state.
- **Doctor:** upgrade `_warnDoubleBundle` from a warning to a verified
  invariant — fail only if a module is *both* `@Native` and still compiled by a
  platform build (i.e., neutralization didn't run / is stale), with the exact
  file + line.

## Staged rollout

- **Stage A — new modules default to `@Native` (greenfield).** `nitrogen init`
  of an all-C++ module writes `hook/build.dart` + build.yaml `native_assets: true`
  and scaffolds **without** the engine-bundling platform build. No existing
  module changes; no migration. *Prereq:* the init scaffold produces a clean
  `@Native`-only module (the empty-shell case above).
- **Stage B — `generate` defaults on-when-eligible + `--no-native-assets`.**
  Eligible all-C++ non-web modules emit `@Native` by default; ineligible
  auto-fall back (already the behavior). *Prereq:* double-bundle
  auto-resolution (above) landed and validated, so an existing module's next
  regen + link neutralizes its platform build instead of double-bundling.
- **Stage C — full default, opt-out only.** Remove the opt-in flag; `--no-native-assets`
  (or build.yaml) is the only escape hatch. *Prereq:* Stage B validated in the
  field across all platforms + mixed projects.

Each stage gates on the previous passing real device/CI validation.

## Validation (every stage)

- iOS **archive** export check (the nitro_http#3 methodology): `dyld_info
  -exports …Runner | grep <lib>_` — with `@Native` the app resolves via the
  code asset, so this is moot, but the *build must succeed and run*.
- All-platform build + run of a real consumer (benchmark/example): macOS, iOS,
  Android, web, Windows/Linux (CI). Both the all-`@Native` and the mixed
  (`@Native` + Swift/Kotlin sibling) shapes.
- Single-instance + multi-isolate runtime smoke (the completion-spin paths).
- Generator + CLI suites green; a golden for the neutralized platform files.

## Risks

- **Mixed-project neutralization** is the subtle part — per-module exclusion in
  shared `src/CMakeLists.txt` / podspec must not drop sources a sibling needs.
- **native-assets field maturity** on every CI/release toolchain (xcrun / NDK /
  cl); the hook cross-compile is validated on host but wants broad CI coverage
  before Stage C.
- **`flutter build ipa` + code assets**: confirm Flutter bundles the code asset
  into the archive on the `@Native` path (no `ffiPlugin`) exactly as it does for
  a plain Dart app — this is the one path least exercised today.

## Not changing now

Per decision on 2026-10-27: this is the plan only. Implement Stage A first,
behind review, once the init scaffold's `@Native`-only shape is designed.
