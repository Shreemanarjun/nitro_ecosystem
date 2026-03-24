// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "my_camera",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "my_camera", targets: ["my_camera"]),
    ],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        .target(
            name: "MyCameraCpp",
            path: "Sources/MyCameraCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-std=c++17",
                    "-I../../.symlinks/plugins/nitro/src/native",
                ])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "my_camera",
            dependencies: ["MyCameraCpp"],
            path: "Sources/MyCamera"
        ),
    ]
)
