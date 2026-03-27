# 🚀 Nitro Performance Benchmark Suite

A high-performance diagnostic engine for the **Nitro ecosystem**.

### ⚡ Current Status & Core Mission
Nitro bridges the gap between Flutter and Native with **Zero Overhead** and **Full Type-Safety**.

```mermaid
graph LR
    A[Dart Logic] -->|⚡ Ultra-Fast ⚡| B[Native Layer]
    A -->|🛡️ Type-Safe 🛡️| B
    A -->|🔄 Zero-Copy 🔄| B
```

**✅ Currently Supporting**: Android (Kotlin), iOS (Swift), & **Direct C++**
**🚀 Performance Gain**: up to **~65x faster** than MethodChannels!

---

## 🏗️ Architecture Flow
Nitro uses shared memory and direct bindings to bypass serialization bottlenecks.

```mermaid
graph LR
    subgraph "Flutter / Dart"
    D[Dart Logic]
    end

    subgraph "Nitro Bridge"
    GNP[Generated Native Proxy]
    NT[Nitro Runtime]
    end

    subgraph "Native (C++/Swift/Kotlin)"
    NC[Native Code]
    end

    subgraph "Legacy MethodChannel"
    MC[MethodChannel]
    SER[Binary Serialization]
    DES[Binary Deserialization]
    end

    D -- "Direct Call" --> GNP
    GNP -- "JNI / FFI / JSI" --> NT
    NT -- "Memory Address" --> NC
    NC -- "Pointer Return" --> NT
    NT -- "Direct Value" --> D

    D -. "Expensive Copy" .-> MC
    MC -. "Payload" .-> SER
    SER -. "Message Loop" .-> DES
    DES -. "Platform Call" .-> NC
极致的性能：Nitro Direct C++ 路径实现了亚微秒级的调用延迟，完全消除了 JNI/Obj-C 桥接开销。
```

---

## 📱 Test Environment
*   **Mode**: Release (`--release`)
*   **Configuration**: 10 runs of 50,000 iterations (500,000 total samples)
*   **Bridge Type**: **Direct C++ (No JNI/Swift overhead)**

---

## 📊 Unified Performance Dashboard
*Results captured in production Release mode (Lower is better).*

| Bridge | 🚗 Sequential (Min - Max) | 🏎️ Simultaneous (Min - Max) | 🏆 Nitro Advantage |
| :--- | :--- | :--- | :--- |
| **Nitro (Direct C++)** | **1.891 µs** (1.32 - 2.28) | **1.537 µs** (1.04 - 1.87) | **~60x Faster!** |
| **Nitro (Leaf Call)** | **TBD (Pending Run)** | **TBD (Pending Run)** | *Sub-1µs target* |
| **Nitro (Swift/Kotlin)** | **2.287 µs** (1.77 - 2.61) | **1.781 µs** (1.39 - 2.18) | **~50x Faster!** |
| **Direct FFI** | 1.978 µs (1.65 - 2.58) | 1.489 µs (1.11 - 1.78) | *FFI Baseline* |
| MethodChannel | 114.576 µs (92.68 - 122.50) | 79.058 µs (70.90 - 85.27) | (Legacy) |

### ⚡ One-Off Metric
*Single execution latency (avg of 50 samples)*
- **Nitro (Direct C++)**: `0.480 µs`
- **MethodChannel**: `185.24 µs`

---

## 🎯 Conclusion
Nitro has achieved **absolute performance parity** with raw FFI while maintaining a fully automated, type-safe development workflow. By delivering **1.6µs latencies**, it allows developers to build high-throughput native integrations (like frame-by-frame video processing or real-time sensor fusion) with effectively zero bridge overhead.

---

## ✨ Developer Experience (DX)
Nitro is built to bring Flutter-like productivity to native development.

### 🛠️ Nitrogen CLI
At the heart of the ecosystem is **Nitrogen**, a TUI-powered CLI that eliminates manual boilerplate:
- **`nitrogen init`**: Scaffold a pre-wired plugin with optimized native configurations in seconds.
- **`nitrogen generate`**: Automatically produces all Dart FFI, Kotlin JNI, Swift bridges, and C++ implementations from your spec.
- **`nitrogen doctor`**: Run deep health diagnostics on your native build layers (`CMake`, `Podspec`, etc.) to catch wiring errors before they build.
- **`nitrogen link`**: Automatically wires native build files into your project with a single command.

---

## 🚀 Roadmap: Multi-Target High Performance
Nitro **currently** provides full support for **iOS (Swift)**, **Android (Kotlin)**, and **Cross-Platform C++**.

The mission for 1.0 is absolute cross-platform dominance:
- **Desktop Support**: Expanding high-throughput communication to **macOS**, **Windows**, and **Linux**.
- **Wasm Interop**: Investigating high-speed native bindings for **Flutter Web (Wasm)**.
- **Advanced Marshalling**: Further reducing object allocation costs for complex `@HybridStruct` returns.

