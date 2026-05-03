// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro_battery",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "nitro-battery", targets: ["nitro_battery"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "NitroBatteryCpp",
            path: "Sources/NitroBatteryCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .target(
            name: "nitro_battery",
            dependencies: [
                "NitroBatteryCpp",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/NitroBattery"
        ),
    ]
)
