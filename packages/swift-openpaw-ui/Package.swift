// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenPawUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenPawUI", targets: ["OpenPawUI"])
    ],
    dependencies: [
        .package(path: "../swift-agent-protocol"),
        .package(path: "../swift-terminal-core")
    ],
    targets: [
        .target(
            name: "OpenPawUI",
            dependencies: [
                .product(name: "OpenPawProtocol", package: "swift-agent-protocol"),
                .product(name: "OpenPawTerminalCore", package: "swift-terminal-core")
            ]
        ),
        .testTarget(name: "OpenPawUITests", dependencies: ["OpenPawUI"])
    ]
)
