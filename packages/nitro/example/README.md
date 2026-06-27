# nitro example

Small Flutter app that exercises a generated Nitro module from Dart.

## What it demonstrates

- A `.native.dart` spec in `lib/src/math.native.dart`
- A generated Dart binding in `lib/src/math.g.dart`
- Swift and Kotlin bridge output under `lib/src/generated/`
- Synchronous methods, `@nitroAsync`, getters/setters, `@zeroCopy`, and `@NitroStream`

## Spec shape

```dart
import 'package:nitro/nitro.dart';

part 'math.g.dart';

@HybridEnum(startValue: 1)
enum Rounding { floor, ceil, round }

@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  double add(double a, double b);

  @nitroAsync
  Future<double> multiply(double a, double b);

  void processBuffer(@zeroCopy Uint8List data);

  double get scaleFactor;

  int get precision;
  set precision(int value);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<double> get updates;
}
```

`package:nitro/nitro.dart` exports `dart:typed_data`, so generated part files and specs can use typed-data classes such as `Uint8List`, `ByteData`, and `Int64List`.

## Run locally

From this directory:

```sh
flutter pub get
nitrogen generate
nitrogen link
flutter run
```

Use `nitrogen generate --no-ui --fail-on-warn` in CI to regenerate bindings and fail when spec validation warnings are present.
