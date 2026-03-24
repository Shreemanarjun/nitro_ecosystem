# Nitrogen — v0.3.0 Roadmap & Improvement Plan

> Transitioning from "Proof of Concept" to "Production Grade" Flutter FFI.
> This document outlines the prioritized enhancements for the `nitro` runtime, `nitro_generator`, and `nitrogen_cli`.

---

## 🚀 Vision
Nitrogen should be the fastest, safest, and most ergonomic way to bridge Flutter to Native. Version 0.3.0 focuses on **Developer Experience (DX)**, **Runtime Observability**, and **Production Stability**.

---

## 🛠️ Phase 7 — Developer Experience (DX) & Tooling
*Focus: Reducing "Trial and Error" for plugin authors.*

### 7.1 `SpecValidator` (High Priority)
Implement a robust validation layer in `nitro_generator` to fail-fast with actionable error messages.
- [ ] **Cyclic Struct Detection**: Prevent infinite recursion in `@HybridStruct`.
- [ ] **Enum Support Enhancement**: Allow `@HybridEnum` to be used as fields in `@HybridStruct`.
- [ ] **Method Signature Validation**: Ensure async methods return `Future<T>` and streams return `Stream<T>`.
- [ ] **Symbol Collision Check**: Verify that unique C symbols are generated for all methods and properties.

### 7.2 `nitrogen_cli` Enhancements
- [ ] **`nitrogen watch`**: A high-performance file watcher optimized for `.native.dart` files.
- [ ] **`nitrogen create`**: Scaffold a full plugin template with working "Hello World" native code for Android & iOS.
- [ ] **Expanded `doctor` checks**: 
    - Check Android NDK / CMake installation.
    - Validate iOS Podfile / Swift version compatibility.
    - Verify `NativeFinalizer` usage patterns in generated code.

---

## ⚡ Phase 8 — Runtime Observability & Performance
*Focus: Understanding what the bridge is doing.*

### 8.1 Isolate Pool Sizing & Management
- [ ] **Dynamic Sizing**: Automatically scale the isolate pool based on `Platform.numberOfProcessors`.
- [ ] **Observability APIs**: Add `NitroRuntime.stats` to track:
    - Task latency (avg/min/max).
    - Queue depth and active workers.
    - Bridge call throughput (calls/sec).

### 8.2 Production Stability
- [ ] **Typed Error Propagation**: Implement `HybridException` to bridge native stack traces and error codes to Dart.
- [ ] **Custom Log Handlers**: Allow developers to redirect Nitro logs (errors/warnings) to their own logging framework (e.g., Sentry, Firebase Crashlytics).
- [ ] **Zero-Copy expansion**: Support `Float32List`, `Int32List`, and other `TypedData` types for zero-copy transfers.

---

## 📱 Phase 9 — Platform Support & Testing
*Focus: Reaching 100% parity and reliability.*

### 9.1 iOS End-to-End
- [ ] **Full Integration Suite**: Implement a suite of tests running on physical iOS devices.
- [ ] **Swift Async/Await parity**: Ensure all `@nitroAsync` methods map perfectly to Swift `async/throws`.
- [ ] **Bitcode & Module support**: Validate the generated Swift bridges for App Store submission requirements.

### 9.2 Golden-File Snapshot Testing
- [ ] **Regression Guard**: Add unit tests that compare the full generated output (`.g.dart`, `.bridge.g.kt`, etc.) against "Golden" snapshots for a wide variety of spec files.

---

## 📋 Current Implementation Status (Updated 2026-03-25)

| Component | Status | Recent Updates |
|---|---|---|
| **Runtime (`nitro`)** | 🟡 **Stable** | Added `IsolatePool` support and configurable logging. |
| **Generator (`nitro_generator`)** | 🟡 **Stable** | Basic support for Structs, Enums, and Records. |
| **CLI (`nitrogen_cli`)** | 🟡 **Active** | `link`, `doctor`, and `generate` are functional. |
| **Reference Plugin (`my_camera`)** | ✅ **Done** | Full end-to-end example with Refresh and Streams. |
| **Testing (Unit)** | 🟢 **Good** | 35+ generator snapshot tests. |
| **Testing (Integration)** | 🟡 **Partial** | Android tested; iOS end-to-end pending final validation. |

---

## 🗓️ Delivery Roadmap (Q2 2026)

| Week | Target | Milestone |
|---|---|---|
| 1-2 | **DX Focus** | Complete `SpecValidator` + `nitrogen watch`. |
| 3-4 | **Stability Focus** | `HybridException` + Custom Log Handlers. |
| 5-6 | **Parity Focus** | iOS E2E Validation + Golden Testing. |
| 7-8 | **v0.3.0 Beta** | Public beta testing for Nitrogen Ecosystem. |

---

## 🔧 Maintenance & Non-Goals
- **Non-Goal**: Web support (Wasm-FFI is a separate track).
- **Non-Goal**: Direct C++ implementation as primary logic (stick to Swift/Kotlin for DX).
- **Maintenance**: Update all packages to `Dart 3.7+` and `Flutter 3.29+` compatibility.
