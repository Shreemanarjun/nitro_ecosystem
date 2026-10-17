// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "benchmark_example",
  platforms: [.macOS(.v10_15)],
  products: [
    .library(name: "benchmark-example", targets: ["benchmark_example"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "BenchmarkExampleCpp",
      path: "Sources/BenchmarkExampleCpp",
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include"),
        .unsafeFlags(["-std=c++17"])
      ]
    ),
    .target(
      name: "benchmark_example",
      dependencies: [
        "BenchmarkExampleCpp",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      path: "Sources/BenchmarkExample"
    )
  ]
)
