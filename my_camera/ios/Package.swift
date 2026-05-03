// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "my_camera",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "my_camera", targets: ["my_camera"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        .target(
            name: "MyCameraCpp",
            path: "Sources/MyCameraCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "my_camera",
            dependencies: [
                "MyCameraCpp",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/MyCamera"
        ),
    ]
)
