// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro_battery",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "nitro_battery", targets: ["nitro_battery"])
    ],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        .target(
            name: "NitroBatteryCpp",
            path: "Sources/NitroBatteryCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-std=c++17",
                    "-I../../packages/nitro/src/native",
                ])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "nitro_battery",
            dependencies: ["NitroBatteryCpp"],
            path: "Sources/NitroBattery"
        ),
    ]
)
