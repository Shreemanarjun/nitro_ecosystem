# Nitro Ecosystem — Improvement Plan V2

> **Scope:** `nitrogen_cli` (CLI), `nitro_generator` (generators), `nitro` (runtime), 
> Integration Tests (Real Flutter Builds)
>
> **Goals:** Crash-free operation, Better DX, Real integration tests
>
> **Test Environment:** Both simulators + real devices
> **Plugin Complexity:** Use existing plugins (nitro_vani, nitro_battery)
> **Flutter Version:** Latest stable only
> **CI/CD:** Local development only

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [nitrogen_cli Improvements](#part-1-nitrogen_cli-improvements)
3. [nitro_generator Improvements](#part-2-nitro_generator-improvements)
4. [Runtime Improvements](#part-3-runtime-improvements)
5. [Integration Tests (Real Flutter Builds)](#part-4-integration-tests-real-flutter-builds)
6. [Implementation Roadmap](#part-5-implementation-roadmap)
7. [File Changes Reference](#part-6-file-changes-reference)

---

## Executive Summary

### Current State

| Component | Files | Tests | Key Capabilities |
|-----------|-------|-------|-----------------|
| **nitrogen_cli** | 25 Dart | 10 test files | init, generate, link, doctor, migrate, watch |
| **nitro_generator** | 12 generators | 30+ test files | Dart FFI, C++/Swift/Kotlin, CMake, mocks |
| **nitro (runtime)** | 8 Dart | 3 test files | Library loading, error handling, isolate pool |
| **Integration Tests** | 1 file | Limited | Basic CLI flow only |

### Identified Crash-Prone Areas

| Area | Issue | Priority |
|------|-------|----------|
| Race conditions | dispatch_sync deadlock (nitro_vani), rapid play/pause | P0 |
| Thread safety | JNI thread guard gaps, wrong-thread callbacks | P0 |
| Memory management | NativeFinalizer timing, use-after-free | P1 |
| Stream backpressure | Unhandled overflow scenarios | P1 |

### Identified DX Gaps

| Area | Current | Missing |
|------|---------|---------|
| CLI | `doctor` detects only | Auto-fix (`doctor --fix`) |
| Dependencies | Manual CMake/Podspec | `nitrogen add` command |
| Init | Basic templates | Interactive wizard |
| Errors | Generic exceptions | Source location, context |

---

## Part 1: nitrogen_cli Improvements

### Current Commands

```
nitrogen init          - Scaffold new plugin
nitrogen generate     - Run build_runner code gen
nitrogen link         - Wire CMake/Podspec/Gradle
nitrogen doctor       - Health check (detects only)
nitrogen migrate      - Migrate from method channels
nitrogen watch        - Watch mode for changes
nitrogen update       - Version check
```

### 1.1 Auto-Fix Capability (`doctor --fix`)

**Files to Modify:**
- `packages/nitrogen_cli/lib/commands/doctor_command.dart`
- `packages/nitrogen_cli/lib/commands/link_command.dart`

**Changes:**
```dart
// doctor_command.dart - Add --fix flag
class DoctorCommand extends Command {
  @override
  final String name = 'doctor';
  
  bool fix = false;
  
  DoctorCommand() {
    argParser.addFlag('fix', 
      abbr: 'f',
      help: 'Automatically fix detected issues',
      defaultsTo: false);
  }
  
  @override
  Future<int> run() async {
    if (fix) {
      return await _runWithAutoFix();
    }
    return await _runDiagnosticOnly();
  }
  
  Future<int> _runWithAutoFix() async {
    // Run all checks, apply fixes for:
    // - Missing generated files → run generate
    // - Stale CMake targets → re-run link
    // - Missing pubspec deps → auto-add
    // - Invalid podspec → regenerate
  }
}
```

**Auto-Fix Rules:**
| Issue | Fix Action |
|-------|------------|
| Missing `.g.dart` files | Run `nitrogen generate` |
| Stale bridge files | Regenerate and relink |
| Missing nitro deps | Add to pubspec.yaml |
| Invalid podspec | Regenerate via `nitrogen init` |
| Missing Plugin.kt | Run `nitrogen link` |

### 1.2 Native Dependency Management (`nitrogen add`)

**Files to Create:**
- `packages/nitrogen_cli/lib/commands/add_command.dart`
- `packages/nitrogen_cli/lib/templates/dependency_templates.dart`

**New Commands:**
```bash
# Add CMake dependency (fetches via FetchContent)
nitrogen add cmake <package> <git-url>

# Add CocoaPods dependency
nitrogen add pod <pod-name>

# Add Swift Package Manager dependency  
nitrogen add spm <package> <git-url>
```

**Implementation:**
```dart
// add_command.dart
class AddCommand extends Command {
  @override
  final String name = 'add';
  
  Future<int> run() async {
    final type = argResults?.rest[0]; // cmake, pod, spm
    final package = argResults?.rest[1];
    final url = argResults?.rest[2];
    
    switch (type) {
      case 'cmake':
        return await _addCmakeDependency(package!, url!);
      case 'pod':
        return await _addCocoaPodsDependency(package!);
      case 'spm':
        return await _addSpmDependency(package!, url!);
    }
  }
  
  Future<int> _addCmakeDependency(String name, String url) async {
    // 1. Read CMakeLists.txt
    // 2. Add FetchContent_Declare + FetchContent_MakeAvailable
    // 3. Add target_link_libraries
  }
}
```

### 1.3 Interactive Init Mode

**Files to Modify:**
- `packages/nitrogen_cli/lib/commands/init_command.dart`

**Enhancement:**
```dart
// Add interactive mode
bool interactive = false;

Future<void> runInteractiveInit() async {
  // 1. Welcome screen with options
  print("Nitrogen Plugin Creator");
  print("========================");
  
  // 2. Select template
  print("Select implementation:");
  print("1. C++ only (all platforms)");
  print("2. Swift (iOS/macOS) + Kotlin (Android)");
  print("3. Mixed (C++ on desktop, Swift/Kotlin on mobile)");
  
  final template = await promptSelection(['1', '2', '3']);
  
  // 3. Enter package details
  final name = await prompt("Package name:", validator: validatePackageName);
  final org = await prompt("Organization:", defaultValue: "com.example");
  
  // 4. Select platforms
  final platforms = await multiSelect(
    ['iOS', 'Android', 'macOS', 'Windows', 'Linux'],
    defaultSelected: ['iOS', 'Android']
  );
  
  // 5. Generate project
  await scaffoldProject(template, name, org, platforms);
}
```

### 1.4 CLI Enhancement Summary

| Feature | Timeline | Files Changed |
|---------|----------|----------------|
| `doctor --fix` | Week 1-2 | `doctor_command.dart`, `link_command.dart` |
| `nitrogen add` | Week 3-4 | `add_command.dart` (new), templates |
| Interactive init | Week 5-6 | `init_command.dart` |
| Progress indicators | Week 1-2 | All commands |

---

## Part 2: nitro_generator Improvements

### Current Generators

| Generator | Output | Platforms |
|-----------|--------|-----------|
| `dart_ffi_generator.dart` | `.g.dart` | All |
| `cpp_bridge_generator.dart` | `.bridge.g.cpp/.h` | All |
| `swift_generator.dart` | `.bridge.g.swift` | iOS/macOS |
| `kotlin_generator.dart` | `.bridge.g.kt` | Android |
| `cpp_interface_generator.dart` | `.native.g.h` | C++ only |
| `cpp_mock_generator.dart` | `.mock.g.h` | C++ only |
| `cmake_generator.dart` | `CMakeLists.g.txt` | All |

### 2.1 Race Condition Guards

**Files to Modify:**
- `packages/nitro_generator/lib/src/generators/dart_ffi_generator.dart`
- `packages/nitro_generator/lib/src/generators/cpp_bridge_generator.dart`
- `packages/nitro_generator/lib/src/generators/swift_generator.dart`
- `packages/nitro_generator/lib/src/generators/kotlin_generator.dart`

**Pattern to Generate (Applied to all async methods):**

```dart
// In generated Dart FFI (.g.dart)
class _ModuleImpl extends Module {
  String? _currentOperationId;
  
  @override
  Future<ReturnType> asyncMethod(Args args) async {
    final opId = UUID().toString();
    _currentOperationId = opId;
    
    try {
      final result = await _asyncMethodInternal(args, opId);
      return result;
    } finally {
      // Clear only if this is still the current operation
      if (_currentOperationId == opId) {
        _currentOperationId = null;
      }
    }
  }
}
```

```cpp
// In generated C++ bridge (.bridge.g.cpp)
class NitroBridge {
  std::string currentOperationId;
  std::mutex opMutex;
  
  void AsyncMethod(Args args, Callback callback) {
    auto opId = GenerateUUID();
    {
      std::lock_guard<std::mutex> lock(opMutex);
      currentOperationId = opId;
    }
    
    // Execute async and validate on completion
    ExecuteAsync(args, [this, opId, callback](Result result) {
      std::string currentId;
      {
        std::lock_guard<std::mutex> lock(opMutex);
        currentId = currentOperationId;
      }
      
      // Only process if operation still valid
      if (currentId == opId) {
        {
          std::lock_guard<std::mutex> lock(opMutex);
          currentOperationId = "";
        }
        callback(result);
      }
      // Else: stale callback, ignore
    });
  }
};
```

### 2.2 Thread Safety Validation

**Files to Modify:**
- `packages/nitro_generator/lib/src/generators/cpp_bridge_generator.dart`
- `packages/nitro_generator/lib/src/generators/kotlin_generator.dart`

**JNI Thread Guard Enhancement:**
```cpp
// In generated Kotlin bridge (.bridge.g.kt)
class JniThreadGuard {
    companion object {
        private val threadGuard = ThreadLocal<Boolean>()
        
        fun ensureAttached(): Boolean {
            if (threadGuard.get() == true) return true
            
            return try {
                val env = System.getProperty("java.class.path")
                // Auto-attach if not attached
                threadGuard.set(true)
                true
            } catch (e: Exception) {
                false
            }
        }
    }
}

fun callMethod(...) {
    if (!JniThreadGuard.ensureAttached()) {
        throw NitroException("Thread not attached - call from JNI thread")
    }
    // ... method implementation
}
```

### 2.3 Error Context Enhancement

**Files to Modify:**
- `packages/nitro_generator/lib/src/generators/dart_ffi_generator.dart`
- `packages/nitro_generator/lib/src/generators/cpp_bridge_generator.dart`

**Enhanced Error Messages:**
```dart
// Generated Dart code
void checkError() {
  if (errorPtr.ref.hasError) {
    final message = errorPtr.ref.message.toDartString();
    final file = errorPtr.ref.sourceFile?.toDartString() ?? "unknown";
    final line = errorPtr.ref.sourceLine;
    
    throw HybridException(
      message: message,
      code: errorPtr.ref.code.toDartString(),
      stackTrace: "Native error at $file:$line\n${errorPtr.ref.stackTrace}"
    );
  }
}
```

### 2.4 Generator Enhancement Summary

| Feature | Timeline | Files Changed |
|---------|----------|----------------|
| Race condition guards | Week 1-2 | All generators |
| Thread safety validation | Week 3-4 | cpp_bridge, kotlin |
| Error context | Week 5-6 | dart_ffi, cpp_bridge |
| Dart mock generation | Week 7-8 | dart_ffi_generator |
| Incremental generation | Week 9-10 | builder.dart |

---

## Part 3: Runtime Improvements

### Current Runtime Features

| Feature | File | Description |
|---------|------|-------------|
| Library loading | `nitro_runtime.dart` | DynamicLibrary cache |
| Error handling | `hybrid_exception.dart` | HybridException |
| Isolate pool | `isolate_pool.dart` | Background async |
| NativeFinalizer | `hybrid_object_base.dart` | Memory cleanup |
| Config | `nitro_config.dart` | Logging config |

### 3.1 Callback Lifecycle Management

**Files to Modify:**
- `packages/nitro/lib/src/nitro_runtime.dart`
- `packages/nitro/lib/src/hybrid_object_base.dart`

**Implementation:**
```dart
// nitro_runtime.dart
class NitroRuntime {
  static final Map<int, CallbackTracker> _callbackTrackers = {};
  static int _nextCallbackId = 0;
  
  /// Register a callback for tracking
  static int trackCallback(void Function() callback) {
    final id = _nextCallbackId++;
    _callbackTrackers[id] = CallbackTracker(
      callback: callback,
      createdAt: DateTime.now(),
      valid: true,
    );
    return id;
  }
  
  /// Validate callback before invocation
  static bool isCallbackValid(int id) {
    final tracker = _callbackTrackers[id];
    return tracker != null && tracker.valid;
  }
  
  /// Release callback tracking
  static void releaseCallback(int id) {
    _callbackTrackers[id]?.valid = false;
    _callbackTrackers.remove(id);
  }
  
  /// Invoke callback only if valid
  static void invokeCallback(int id, void Function() callback) {
    if (!isCallbackValid(id)) {
      print("[Nitro] Ignoring stale callback id=$id");
      return;
    }
    callback();
  }
}

// Helper class
class CallbackTracker {
  final void Function() callback;
  final DateTime createdAt;
  bool valid;
  
  CallbackTracker({
    required this.callback,
    required this.createdAt,
    required this.valid,
  });
}
```

### 3.2 Thread-Local Error Storage

**Files to Modify:**
- `packages/nitro/lib/src/nitro_runtime.dart`

**Implementation:**
```dart
// Thread-local error context
class ErrorContext {
  String? lastError;
  String? lastErrorMessage;
  String? lastErrorStack;
  int errorCount = 0;
  
  void recordError(String name, String message, [String? stack]) {
    lastError = name;
    lastErrorMessage = message;
    lastErrorStack = stack;
    errorCount++;
  }
  
  void clear() {
    lastError = null;
    lastErrorMessage = null;
    lastErrorStack = null;
  }
}

// Per-isolate error storage
final _isolateErrors = <int, ErrorContext>{};

static ErrorContext _getErrorContext() {
  final isolateId = Isolate.current.hashCode;
  return _isolateErrors.putIfAbsent(isolateId, () => ErrorContext());
}

static void setError(String name, String message, [String? stack]) {
  _getErrorContext().recordError(name, message, stack);
}

static void clearError() {
  _getErrorContext().clear();
}

static String? getLastErrorName() => _getErrorContext().lastError;
```

### 3.3 Structured Logging

**Files to Modify:**
- `packages/nitro/lib/src/nitro_config.dart`

**Enhancement:**
```dart
// nitro_config.dart
enum NitroLogCategory {
  lifecycle,   // Init/dispose
  methodCall,  // FFI method calls
  stream,      // Stream events
  memory,      // Allocation/deallocation
  thread,      // Thread operations
  error,       // Errors and exceptions
}

class NitroConfig {
  /// Structured logging with categories
  void log(NitroLogLevel level, NitroLogCategory category, String message, 
           [Map<String, Object>? data]) {
    if (level.rank > effectiveLogLevel.rank) return;
    
    final timestamp = DateTime.now().toIso8601String();
    final formatted = "[$timestamp] [$category] $message";
    
    if (data != null) {
      final dataStr = data.entries.map((e) => "${e.key}=${e.value}").join(", ");
      "$formatted | $dataStr";
    }
    
    logHandler(level, "Nitro.$category", formatted);
  }
  
  // Usage:
  // NitroConfig.instance.log(
  //   NitroLogLevel.debug,
  //   NitroLogCategory.methodCall,
  //   "Calling native method",
  //   {"method": "add", "args": [1, 2]}
  // );
}
```

### 3.4 Runtime Enhancement Summary

| Feature | Timeline | Files Changed |
|---------|----------|----------------|
| Callback tracking | Week 1-2 | `nitro_runtime.dart` |
| Thread-local errors | Week 3-4 | `nitro_runtime.dart` |
| Structured logging | Week 5-6 | `nitro_config.dart` |
| Operation timeouts | Week 7-8 | `isolate_pool.dart` |

---

## Part 4: Integration Tests (Real Flutter Builds)

### Test Strategy

Tests execute against **real Flutter plugin builds** on:
- iOS simulators + devices
- Android emulators + devices  
- macOS app builds

**Plugin Sources:**
- `nitro_vani` - Audio playback (race condition tests)
- `nitro_battery` - Battery status (thread safety tests)

### 4.1 Test Infrastructure

**Files to Create:**
```
packages/nitro/test/
├── real_builds/
│   ├── test_helpers/
│   │   ├── real_plugin_builder.dart
│   │   ├── device_test_helpers.dart
│   │   ├── crash_detector.dart
│   │   └── native_memory_tracker.dart
│   ├── ios/
│   │   ├── race_condition_test.dart
│   │   ├── thread_safety_test.dart
│   │   ├── memory_safety_test.dart
│   │   └── exception_handling_test.dart
│   ├── android/
│   │   ├── jni_thread_guard_test.dart
│   │   ├── native_callback_test.dart
│   │   └── memory_leak_test.dart
│   └── macos/
│       ├── dispatch_sync_test.dart
│       └── native_callback_test.dart
```

### 4.2 Test Helpers

**`real_plugin_builder.dart`:**
```dart
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

class RealPluginBuilder {
  final String pluginName;
  final Directory tempDir;
  
  RealPluginBuilder(this.pluginName) : tempDir = Directory.systemTemp();
  
  /// Build iOS for simulator
  Future<BuildResult> buildIOS({bool simulator = true}) async {
    final args = [
      'build', 'ios',
      if (simulator) '--simulator',
      '--no-codesign',
    ];
    
    final result = await Process.run('flutter', args, 
      workingDirectory: tempDir.path);
    
    return BuildResult(
      success: result.exitCode == 0,
      output: result.stdout.toString(),
      errors: result.stderr.toString(),
    );
  }
  
  /// Build Android APK
  Future<BuildResult> buildAndroid() async {
    final result = await Process.run('flutter', ['build', 'apk', '--debug'],
      workingDirectory: tempDir.path);
    
    return BuildResult(
      success: result.exitCode == 0,
      output: result.stdout.toString(),
      errors: result.stderr.toString(),
    );
  }
  
  /// Build macOS app
  Future<BuildResult> buildMacOS() async {
    final result = await Process.run('flutter', ['build', 'macos'],
      workingDirectory: tempDir.path);
    
    return BuildResult(
      success: result.exitCode == 0,
      output: result.stdout.toString(),
      errors: result.stderr.toString(),
    );
  }
  
  void dispose() {
    tempDir.deleteSync(recursive: true);
  }
}

class BuildResult {
  final bool success;
  final String output;
  final String errors;
  
  BuildResult({required this.success, required this.output, required this.errors});
}
```

**`crash_detector.dart`:**
```dart
import 'dart:io';

class CrashDetector {
  /// Monitors process for crash signals
  static Future<bool> checkForCrash(Process process) async {
    // Listen to process stderr for crash indicators
    await for (final data in process.stderr.transform(SystemEncoding().decoder)) {
      if (_isCrashSignal(data)) {
        return true;
      }
    }
    return false;
  }
  
  static bool _isCrashSignal(String output) {
    final crashPatterns = [
      'SIGABRT',
      'SIGSEGV',
      'EXC_CRASH',
      'Fatal error',
      'dispatch_sync called on queue already owned',
      'BUG IN CLIENT OF LIBDISPATCH',
    ];
    
    return crashPatterns.any((pattern) => output.contains(pattern));
  }
  
  /// Check device log for crash reports (iOS)
  static Future<String?> checkDeviceLogs(String deviceId) async {
    final result = await Process.run('idevyslog', [
      '--device', deviceId,
      '--last', '1m', // Last 1 minute
    ]);
    
    if (result.exitCode == 0) {
      return result.stdout.toString();
    }
    return null;
  }
  
  /// Check logcat for crash reports (Android)
  static Future<String?> checkLogcat() async {
    final result = await Process.run('adb', ['logcat', '-d', '-t', '100']);
    
    if (result.exitCode == 0) {
      return result.stdout.toString();
    }
    return null;
  }
}
```

### 4.3 Race Condition Tests (Week 1-2)

**`ios/race_condition_test.dart`:**
```dart
import 'package:test/test.dart';
import 'real_plugin_builder.dart';
import 'crash_detector.dart';

void main() {
  group('Race Condition Tests (Real Builds)', () {
    test('rapid start/stop should not crash (nitro_vani)', () async {
      // Use existing nitro_vani plugin
      final builder = RealPluginBuilder('nitro_vani');
      
      try {
        // Build for iOS simulator
        final buildResult = await builder.buildIOS(simulator: true);
        expect(buildResult.success, true, 
          reason: "Build failed: ${buildResult.errors}");
        
        // Install and launch on simulator
        final device = await SimulatorManager().allocateDevice();
        await device.installApp(builder.tempDir.path);
        final process = await device.launchApp();
        
        // Run 100 rapid start/stop cycles in 1 second
        for (int i = 0; i < 100; i++) {
          await process.invoke('startReplay', {'file': 'test.wav'});
          await Future.delayed(Duration(milliseconds: 10));
          await process.invoke('stopReplay');
        }
        
        // Wait a bit for any delayed crashes
        await Future.delayed(Duration(seconds: 2));
        
        // Check if app is still running
        final isAlive = await process.isRunning();
        expect(isAlive, true, 
          reason: "App crashed during rapid start/stop");
        
        // Check device logs for crash
        final logs = await CrashDetector.checkDeviceLogs(device.id);
        if (logs != null) {
          expect(logs.contains('dispatch_sync'), false,
            reason: "dispatch_sync crash detected in logs");
        }
        
      } finally {
        builder.dispose();
      }
    }, timeout: Timeout(Duration(minutes: 10)));
    
    test('concurrent async operations should not crash', () async {
      // Test with nitro_battery - multiple concurrent async calls
      final builder = RealPluginBuilder('nitro_battery');
      
      final buildResult = await builder.buildIOS(simulator: true);
      expect(buildResult.success, true);
      
      final device = await SimulatorManager().allocateDevice();
      final process = await device.launchApp();
      
      // Fire 10 concurrent async operations
      final futures = List.generate(10, (_) => 
        process.invoke('getBatteryInfo'));
      await Future.wait(futures);
      
      // Verify no crashes
      expect(await process.isRunning(), true);
    });
  });
}
```

### 4.4 Thread Safety Tests (Week 3-4)

**`android/jni_thread_guard_test.dart`:**
```dart
import 'package:test/test.dart';
import 'real_plugin_builder.dart';

void main() {
  group('Thread Safety Tests (Real Builds)', () {
    test('native callback on wrong thread should auto-attach', () async {
      final builder = RealPluginBuilder('nitro_vani');
      
      // Build Android APK
      final buildResult = await builder.buildAndroid();
      expect(buildResult.success, true);
      
      // Install on emulator
      final emulator = await EmulatorManager().allocateEmulator();
      await emulator.installApk(buildResult.output);
      final process = await emulator.launchApp();
      
      // Trigger native operation that calls back from background thread
      // This should either:
      // 1. Auto-attach the thread and succeed
      // 2. Return proper error instead of crashing
      
      final result = await process.invoke('triggerBackgroundCallback');
      
      // Verify app didn't crash
      expect(await process.isRunning(), true);
      
      // Verify either success or proper error (not crash)
      expect(result['crashed'] == true, false,
        reason: "App crashed on wrong-thread callback");
    });
    
    test('JNI thread guard should prevent crashes', () async {
      // Test with native code that calls back from non-JNI thread
      final builder = RealPluginBuilder('nitro_battery');
      
      final buildResult = await builder.buildAndroid();
      expect(buildResult.success, true);
      
      final emulator = await EmulatorManager().allocateEmulator();
      final process = await emulator.launchApp();
      
      // Make call from background thread
      await process.invoke('callFromBackgroundThread');
      
      // Verify proper error handling, not crash
      final logcat = await CrashDetector.checkLogcat();
      expect(logcat?.contains('Fatal'), false);
    });
  });
}
```

### 4.5 Memory & Exception Tests (Week 5-8)

**`ios/memory_safety_test.dart`:**
```dart
import 'package:test/test.dart';
import 'real_plugin_builder.dart';

void main() {
  group('Memory Safety Tests (Real Builds)', () {
    test('dispose during native callback should not crash', () async {
      final builder = RealPluginBuilder('nitro_vani');
      
      final buildResult = await builder.buildIOS(simulator: true);
      expect(buildResult.success, true);
      
      final device = await SimulatorManager().allocateDevice();
      final process = await device.launchApp();
      
      // Start long-running operation with callback
      var operation = await process.invoke('startLongOperation');
      
      // Immediately dispose while callback pending
      await process.invoke('dispose');
      
      // Force garbage collection
      await process.invoke('forceGC');
      
      // Wait for potential delayed crashes
      await Future.delayed(Duration(seconds: 2));
      
      // Verify app didn't crash
      expect(await process.isRunning(), false, // App disposed
        reason: "Crash after dispose during callback");
      
      // Verify no crash in logs
      final logs = await CrashDetector.checkDeviceLogs(device.id);
      expect(logs?.contains('use-after-free'), false);
    });
    
    test('exception in native code should propagate to Dart', () async {
      final builder = RealPluginBuilder('nitro_battery');
      
      final buildResult = await builder.buildIOS(simulator: true);
      expect(buildResult.success, true);
      
      final device = await SimulatorManager().allocateDevice();
      final process = await device.launchApp();
      
      // Trigger native exception
      try {
        await process.invoke('throwException', {'type': 'runtime'});
        fail("Expected exception");
      } on HybridException catch (e) {
        // Verify proper exception propagation
        expect(e.message, contains("Test exception"));
        expect(e.stackTrace, isNotNull);
      }
    });
    
    test('stream backpressure should handle overflow', () async {
      final builder = RealPluginBuilder('nitro_vani');
      
      final buildResult = await builder.buildIOS(simulator: true);
      expect(buildResult.success, true);
      
      final device = await SimulatorManager().allocateDevice();
      final process = await device.launchApp();
      
      // Start stream with high-frequency events
      var stream = process.startStream('audioLevelStream');
      
      // Rapidly subscribe/unsubscribe
      for (int i = 0; i < 50; i++) {
        await stream.listen((data) {});
        await stream.cancel();
      }
      
      // Verify no crash
      expect(await process.isRunning(), true);
    });
  });
}
```

### 4.6 Integration Test Summary

| Test Suite | Timeline | Plugins Used |
|------------|----------|---------------|
| Race condition tests | Week 1-2 | nitro_vani |
| Thread safety tests | Week 3-4 | nitro_vani, nitro_battery |
| Memory safety tests | Week 5-6 | nitro_vani |
| Exception handling tests | Week 7-8 | nitro_battery |

---

## Part 5: Implementation Roadmap

### Month 1: Crash Prevention Foundation

```
Week 1-2: Race Condition Fixes
├── Apply _engineStarted pattern to all async operations
│   └── Generator produces operation state tracking
├── Add race condition integration tests
│   └── Real iOS build with rapid start/stop
└── Fix existing nitro_vani crash (in progress)
    └── Added _engineStarted flag

Week 3-4: Thread Safety
├── Add thread guard to C++ bridge generator
├── Add callback validity tracking to runtime
├── Add thread safety integration tests
│   └── Real Android build with JNI thread guard
└── Validate on all platforms

Week 5-8: Memory Safety
├── Improve NativeFinalizer reliability
├── Add resource cleanup guarantees
├── Add memory safety integration tests
│   └── Real iOS/macOS with dispose during callback
└── Test on all platforms
```

### Month 2: Developer Experience

```
Week 9-10: CLI - Auto-Fix
├── Implement doctor --fix
├── Add progress indicators
└── Enhanced error messages

Week 11-12: CLI - Dependencies
├── Implement nitrogen add (cmake, pod, spm)
└── Test native dependency integration

Week 13-14: CLI - Interactive Mode
├── Interactive init wizard
├── Guided migration
└── Template selection

Week 15-16: Generator Enhancements
├── Source location in errors
├── Dart mock generation
└── Incremental generation
```

### Month 3: Polish & Testing

```
Week 17-18: Integration Test Expansion
├── Full platform test matrix
├── Performance regression tests
└── Documentation updates

Week 19-20: Documentation
├── Update README
├── Migration guides
└── Troubleshooting docs

Week 21-24: Final Polish
├── Bug fixes from testing
├── Performance optimization
└── Release preparation
```

---

## Part 6: File Changes Reference

### nitrogen_cli

| File | Changes |
|------|---------|
| `lib/commands/doctor_command.dart` | Add `--fix` flag, auto-fix logic |
| `lib/commands/add_command.dart` | **NEW** - native dependency management |
| `lib/commands/init_command.dart` | Add interactive mode |
| `lib/templates/dependency_templates.dart` | **NEW** - dependency templates |
| `test/doctor_command_test.dart` | Add tests for auto-fix |
| `test/integration_test.dart` | Add native dependency tests |

### nitro_generator

| File | Changes |
|------|---------|
| `lib/src/generators/dart_ffi_generator.dart` | Add race condition guards, error context |
| `lib/src/generators/cpp_bridge_generator.dart` | Add thread guard, operation state machine |
| `lib/src/generators/swift_generator.dart` | Add thread validation |
| `lib/src/generators/kotlin_generator.dart` | Add JNI thread guard |
| `test/*_test.dart` | Add tests for new features |

### nitro (runtime)

| File | Changes |
|------|---------|
| `lib/src/nitro_runtime.dart` | Add callback tracking, thread-local errors |
| `lib/src/nitro_config.dart` | Add structured logging with categories |
| `lib/src/isolate_pool.dart` | Add operation timeout support |
| `lib/src/hybrid_object_base.dart` | Improve NativeFinalizer reliability |
| `test/*_test.dart` | Add tests for new features |

### Integration Tests

| File | Changes |
|------|---------|
| `test/real_builds/test_helpers/real_plugin_builder.dart` | **NEW** |
| `test/real_builds/test_helpers/crash_detector.dart` | **NEW** |
| `test/real_builds/ios/race_condition_test.dart` | **NEW** |
| `test/real_builds/android/jni_thread_guard_test.dart` | **NEW** |
| `test/real_builds/ios/memory_safety_test.dart` | **NEW** |

---

## Success Metrics

| Metric | Target |
|--------|--------|
| Race condition crashes | 0 |
| Thread safety crashes | 0 |
| Memory safety crashes | 0 |
| CLI auto-fix coverage | >80% of doctor detections |
| Integration test pass rate | >95% |
| Build time (incremental) | <30 seconds |

---

*Generated: May 2026*
*Plan Version: V2*
*Status: Ready for Implementation*