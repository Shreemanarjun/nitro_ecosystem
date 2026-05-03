// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "nitro", targets: ["nitro"])
    ],
    dependencies: [
        .package(name: "FlutterMacOS", path: "../FlutterMacOS"),
    ],
    targets: [
        .target(
            name: "NitroC",
            path: "Classes",
            publicHeadersPath: "."
        ),
        .target(
            name: "nitro",
            dependencies: [
                "NitroC",
                .product(name: "FlutterMacOS", package: "FlutterMacOS"),
            ],
            path: "Sources/Nitro"
        ),
    ]
)
