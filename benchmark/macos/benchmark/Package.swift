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
        name: "NitroArCpp",
        dependencies: ["BenchmarkCpp"],
        path: "Sources/NitroArCpp",
        publicHeadersPath: "include",
        cxxSettings: [
          .headerSearchPath("include"),
          .unsafeFlags(["-std=c++17"])
        ]
      ),
      .target(
        name: "BenchmarkCppCpp",
        dependencies: ["BenchmarkCpp"],
        path: "Sources/BenchmarkCppCpp",
        publicHeadersPath: "include",
        cxxSettings: [
          .headerSearchPath("include"),
          .unsafeFlags(["-std=c++17"])
        ]
      ),
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
              "NitroArCpp",
              "BenchmarkCppCpp",
                "BenchmarkCpp",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/Benchmark"
        ),
    ]
)
