# Nitro wire format

The binary layout the Dart runtime and the native (C++ / Swift / Kotlin) and web
(WASM) edges use to pass compound values across the bridge. One format, several
implementations — this page is the canonical reference and lists the guards that
keep those implementations in sync.

## Invariants

- **Endianness is little-endian**, always, on every platform.
- **Scalars:** `int` → 8 bytes (int64), `double` → 8 bytes (float64), `bool` →
  1 byte (`0`/`1`), `int8`/`int32` → their natural width.
- **Nullable value:** a 1-byte `hasValue` flag (`0` = null, `1` = present)
  *precedes* the payload. The three built-in nullable-scalar codecs are packed:
  `int?` = `[1B flag][8B int64]` (9B), `double?` = `[1B flag][8B float64]` (9B),
  `bool?` = `[1B flag][1B value]` (2B).
- **String:** a 4-byte UTF-8 byte count, then the UTF-8 bytes (no NUL).
- **Blob / TypedData:** a 4-byte byte count, then the raw bytes.
- **List:** a 4-byte element count, then the elements back-to-back.
- **Framed form:** a payload prefixed with a 4-byte int32 total length, so a
  receiver knows how many bytes to consume. The native edge hands over a
  `Pointer<Uint8>`; the web edge copies the identical framed bytes into the
  module heap.

## Where it's defined (authoritative sources)

- Scalar + nullable + record primitives, Dart side (single source for the Dart
  and web edges): [`packages/nitro/lib/src/shared/record_codec_base.dart`](../packages/nitro/lib/src/shared/record_codec_base.dart)
  and [`packages/nitro/lib/src/shared/nitro_wire_codec.dart`](../packages/nitro/lib/src/shared/nitro_wire_codec.dart).
- Native emit (C++ / Swift / Kotlin) is produced by the generator under
  `packages/nitro_generator/lib/src/generators/languages/`.

## The four guards against drift

A wire change must land in the Dart shared codec **and** all native emitters at
once. These catch a miss:

1. **Edge parity** — `packages/nitro/test/shared_codec_parity_test.dart` asserts
   the web framed bytes are byte-identical to the native pointer bytes, and the
   `NitroWireCodec` layouts equal the `@Packed(1)` `NitroOpt*` structs.
2. **Absolute golden vectors** — the `absolute wire-format golden vectors` group
   in that same file freezes the *exact* bytes for known inputs. Edge parity only
   proves the two Dart edges agree with each other; a lockstep change to the
   shared codec passes parity while silently breaking native. The golden vectors
   fail the instant the format moves, so the change is deliberate.
3. **Generator byte-identity goldens** — `packages/nitro_generator/test`
   pins what the native emitters output.
4. **Runtime ABI + checksum gate** — `NitroRuntime.checkAbiVersion` /
   `checkLinkChecksum` throw at load if the Dart runtime and the compiled bridge
   came from different generations.

## Changing the format

1. Update the Dart shared codec (`record_codec_base.dart` / `nitro_wire_codec.dart`).
2. Update every native emitter in the generator.
3. Update the absolute golden vectors (run the codec, freeze the new bytes).
4. Bump the ABI version so old bridges fail fast against new Dart (and vice versa).
