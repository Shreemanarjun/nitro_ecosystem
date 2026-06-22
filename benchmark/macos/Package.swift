// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "benchmark",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "benchmark", targets: ["benchmark"]),
    ],
    dependencies: [
        .package(name: "FlutterMacOS", path: "../FlutterMacOS"),
    ],
    dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        .target(
            name: "BenchmarkCpp",
            path: "Sources/BenchmarkCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "benchmark",
            dependencies: [
                "BenchmarkCpp",
                .product(name: "FlutterMacOS", package: "FlutterMacOS"),
            ],
            path: "Sources/Benchmark"
        ),
    ]
)
