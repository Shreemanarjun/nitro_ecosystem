// Web compile gate: proves `package:nitro/nitro.dart` compiles for the web
// under BOTH compilers. CI runs:
//   dart compile js   -o /tmp/nitro_gate.js   tool/web_compile_gate.dart
//   dart compile wasm -o /tmp/nitro_gate.wasm tool/web_compile_gate.dart
// The import alone pulls every conditionally-exported branch through the
// front-end check; the references below just keep the entrypoint honest.
// Only platform-neutral symbols here — the analyzer resolves the native
// branch, the web compilers resolve the web branch.
// ignore_for_file: avoid_print
import 'package:nitro/nitro.dart';

void main() {
  final w = RecordWriter()
    ..writeInt(42)
    ..writeString('hello')
    ..writeBool(true);
  final framed = w.takeFramedBytes();
  final r = RecordReaderBase.fromFramedBytes(framed);
  print('${r.readInt()} ${r.readString()} ${r.readBool()}');
  print(NitroNullableInt.fromNullable(7).nullable);
  print(const NitroIntWireCodec().encodeBytes(5));
  print(NitroAnyValue.from({'k': 1}).toDart());
  print(NativeHandle<Void>.fromAddress(0xabc));
  print(NitroRuntime.expectedAbiVersion);
}
