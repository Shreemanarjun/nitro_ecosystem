// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "benchmark",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "benchmark", targets: ["benchmark"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "BenchmarkCpp",
            path: "Sources/BenchmarkCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17", "-include", "NitroObjCPrefix.h"])
            ]
        ),
        .target(
            name: "benchmark",
            dependencies: [
                "BenchmarkCpp",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/Benchmark"
        ),
    ]
)
