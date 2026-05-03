// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "nitro", targets: ["nitro"]),
    ],
    dependencies: [
        .package(name: "FlutterMacOS", path: "../FlutterMacOS"),
    ],
    targets: [
        .target(
            name: "nitro",
            dependencies: [
                .product(name: "FlutterMacOS", package: "FlutterMacOS"),
            ],
            path: "Classes",
            publicHeadersPath: "."
        ),
    ]
)
