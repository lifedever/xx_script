// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShadowProxy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShadowProxyCore", targets: ["ShadowProxyCore"]),
        .executable(name: "sp", targets: ["ShadowProxyCLI"]),
    ],
    targets: [
        .target(
            name: "ShadowProxyCore"
        ),
        .executableTarget(
            name: "ShadowProxyCLI",
            dependencies: ["ShadowProxyCore"]
        ),
        .testTarget(
            name: "ShadowProxyCoreTests",
            dependencies: ["ShadowProxyCore"]
        ),
    ]
)
