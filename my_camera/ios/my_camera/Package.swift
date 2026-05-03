// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "my_camera",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "my-camera", targets: ["my_camera"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "MyCameraCpp",
            path: "Sources/MyCameraCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
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
