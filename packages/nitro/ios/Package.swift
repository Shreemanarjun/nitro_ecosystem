// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "nitro", targets: ["nitro"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "nitro",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Classes",
            publicHeadersPath: "."
        ),
    ]
)
