# Using a Nitrogen Plugin in Your Flutter App

This guide is for **app developers** adding a published Nitrogen FFI plugin as a dependency.

---

## Step 1 — Add the dependency

```yaml
# pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  my_sensor: ^1.0.0   # or whatever the plugin is called
```

```sh
flutter pub get
```

No extra setup is needed for the Dart side. Generated FFI bindings are included in the
package — you do not need `build_runner` or `nitrogen` in your app.

---

## Step 2 — Android setup

### 2a. Set the minimum SDK version

Nitrogen plugins require at least Android API 24. In your app's `android/app/build.gradle`:

```groovy
android {
    compileSdk 35

    defaultConfig {
        minSdk 24
        targetSdk 35
    }
}
```

### 2b. Configure the NDK and ABI filters

In `android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        ndk {
            abiFilters 'arm64-v8a', 'x86_64'
        }
    }
}
```

`arm64-v8a` covers all modern Android phones. `x86_64` covers the Android emulator.
Add `armeabi-v7a` only if you need to support very old 32-bit devices.

### 2c. Set the NDK version

In `android/local.properties` (this file is per-developer, not committed):

```properties
ndk.dir=/Users/you/Library/Android/sdk/ndk/26.1.10909125
```

Or set it in `android/build.gradle` so it is consistent across machines:

```groovy
android {
    ndkVersion "26.1.10909125"
}
```

Find your installed NDK path: Android Studio → SDK Manager → SDK Tools → NDK (Side by side).

### 2d. Enable Kotlin coroutines (if the plugin uses async or streams)

```groovy
// android/app/build.gradle
dependencies {
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0"
}
```

Most Nitrogen plugins already include this transitively. Add it explicitly if you see
`NoClassDefFoundError` for any `kotlinx.coroutines` class.

---

## Step 3 — iOS setup

### 3a. Set the minimum deployment target

In `ios/Podfile`:

```ruby
platform :ios, '13.0'
```

If your app already targets a higher version, that is fine — just make sure it is not lower
than `13.0`.

### 3b. Install pods

```sh
cd ios
pod install
```

Or:

```sh
flutter pub get
cd ios && pod install
```

That is all. The plugin's `.podspec` handles including the generated C++ bridge and setting
up header search paths automatically.

---

## Step 4 — Import and use

```dart
import 'package:my_sensor/my_sensor.dart';
```

All Nitrogen plugins expose a static `instance` that is ready to use immediately:

```dart
final sensor = MySensor.instance;
```

### Synchronous calls

Direct FFI — executes in under a microsecond:

```dart
final temp = sensor.getTemperature();   // double
final ok   = sensor.isConnected();      // bool
print('$temp °C  connected=$ok');
```

### Async calls

Runs on a background isolate, returns to the main isolate automatically:

```dart
final id = await sensor.readManufacturerId();
print(id); // "ACME-SensorChip-v2"
```

Handle errors the same way as any Dart async call:

```dart
try {
  final id = await sensor.readManufacturerId();
} catch (e) {
  print('Native error: $e');
}
```

### Streams

Native events pushed to Dart at full native speed:

```dart
final subscription = sensor.readings.listen((reading) {
  print('temp=${reading.temperature}  humid=${reading.humidity}');
  print('payload: ${reading.payload.length} bytes');  // zero-copy
  print('ts: ${reading.timestampNs} ns');
});

// Cancel when done — this stops native emission and releases resources
subscription.cancel();
```

In a Flutter widget, use `StreamBuilder`:

```dart
StreamBuilder<SensorReading>(
  stream: MySensor.instance.readings,
  builder: (context, snapshot) {
    if (!snapshot.hasData) return const CircularProgressIndicator();
    final r = snapshot.data!;
    return Text('${r.temperature.toStringAsFixed(1)} °C');
  },
)
```

Always cancel your subscription when the widget is disposed:

```dart
StreamSubscription<SensorReading>? _sub;

@override
void initState() {
  super.initState();
  _sub = MySensor.instance.readings.listen(_onReading);
}

@override
void dispose() {
  _sub?.cancel();
  super.dispose();
}
```

### Properties

Read/write native state synchronously:

```dart
// Read
print(sensor.sampleRate);      // 10.0
print(sensor.mode);            // SensorMode.idle

// Write
sensor.sampleRate = 100.0;
sensor.mode = SensorMode.sampling;
```

### Enums

Native enums are plain Dart enums with a `.nativeValue` extension:

```dart
if (sensor.mode == SensorMode.error) {
  print('Sensor in error state — native value: ${SensorMode.error.nativeValue}');
}
```

---

## Step 5 — Backpressure

If you subscribe to a stream and your `listen` callback is slow, the plugin's backpressure
policy determines what happens:

| Policy | Behaviour | When to use |
|---|---|---|
| `dropLatest` | Newest item dropped if Dart is busy | Sensors, camera, high-frequency data — losing a frame is fine |
| `block` | Native thread blocks until Dart consumes | Must-not-lose events, but low frequency |
| `bufferDrop` | Ring buffer — oldest item dropped when full | Bursty data |

The policy is set by the plugin author in the spec. As a consumer you do not configure it,
but knowing the policy helps you understand whether your app can safely do heavy work inside
the `listen` callback.

For high-frequency streams (`dropLatest`), keep the callback lightweight:

```dart
// Good — fast, no allocation
sensor.readings.listen((r) {
  _latestTemp = r.temperature;
  setState(() {});
});

// Risky — heavy work may cause drops
sensor.readings.listen((r) async {
  await Future.delayed(const Duration(milliseconds: 100)); // do not do this
});
```

---

## Step 6 — Zero-copy buffers

Some plugins deliver `Uint8List` fields that are zero-copy views into native memory:

```dart
sensor.readings.listen((reading) {
  final bytes = reading.payload; // Uint8List backed by native hardware buffer — no copy

  // Safe to read within this callback
  final firstByte = bytes[0];

  // Do NOT hold a reference past the callback — the native buffer may be reused
  // BAD:
  // _savedBytes = reading.payload;  // do not do this
});
```

If you need to keep data, copy it explicitly:

```dart
sensor.readings.listen((reading) {
  final copy = Uint8List.fromList(reading.payload); // explicit copy — safe to keep
  _history.add(copy);
});
```

The plugin documentation will note which fields are zero-copy.

---

## Troubleshooting

### `UnsatisfiedLinkError` on Android

The native `.so` was not loaded. Make sure:

1. `minSdk 24` is set in your app's `build.gradle`
2. `ndk.dir` or `ndkVersion` is configured
3. `abiFilters` includes `arm64-v8a`
4. Run `flutter clean && flutter pub get` and rebuild

### `dlopen failed` / missing symbol on iOS

1. Run `pod install` in `ios/`
2. Clean derived data: Xcode → Product → Clean Build Folder
3. Verify `platform :ios, '13.0'` in `Podfile`

### Stream never emits events

1. Check that you are holding a reference to the `StreamSubscription`
2. Confirm you are not calling `cancel()` immediately after `listen()`
3. Check the plugin's README for any platform-specific setup (e.g., camera permissions)

### Async calls return immediately with an error

The native implementation threw an exception. The error message comes from the Kotlin
`suspend fun` or Swift `async throws` function. Log it with stack trace:

```dart
try {
  await sensor.readManufacturerId();
} catch (e, st) {
  debugPrint('$e\n$st');
}
```

### `MissingPluginException`

This usually means the plugin's `FlutterPlugin` class was not registered. This should not
happen for Nitrogen plugins if `ffiPlugin: true` is set in the plugin's `pubspec.yaml`.
Run `flutter clean && flutter pub get` and rebuild.

---

## Complete example

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:my_sensor/my_sensor.dart';

class SensorPage extends StatefulWidget {
  const SensorPage({super.key});
  @override
  State<SensorPage> createState() => _SensorPageState();
}

class _SensorPageState extends State<SensorPage> {
  StreamSubscription<SensorReading>? _sub;
  SensorReading? _latest;
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Async native call — runs on background isolate
    final id = await MySensor.instance.readManufacturerId();

    // Start streaming
    _sub = MySensor.instance.readings.listen((r) {
      setState(() => _latest = r);
    });

    // Set properties
    MySensor.instance.sampleRate = 50.0;
    MySensor.instance.mode = SensorMode.sampling;

    setState(() => _deviceId = id);
  }

  @override
  void dispose() {
    _sub?.cancel();          // stop native emission
    MySensor.instance.mode = SensorMode.idle;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _latest;
    return Scaffold(
      appBar: AppBar(title: Text(_deviceId ?? 'Connecting…')),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${r.temperature.toStringAsFixed(1)} °C',
                    style: Theme.of(context).textTheme.displayLarge),
                Text('Humidity: ${r.humidity.toStringAsFixed(0)}%'),
                Text('${r.payload.length} bytes  (zero-copy)'),
              ],
            ),
    );
  }
}
```
