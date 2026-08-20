// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "openpaw-snapshot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openpaw-snapshot", targets: ["openpaw-snapshot"])
    ],
    dependencies: [
        .package(path: "../../packages/swift-openpaw-ui"),
        .package(path: "../../packages/swift-agent-protocol"),
        .package(path: "../../packages/swift-terminal-core"),
    ],
    targets: [
        .executableTarget(
            name: "openpaw-snapshot",
            dependencies: [
                .product(name: "OpenPawUI", package: "swift-openpaw-ui"),
                .product(name: "OpenPawProtocol", package: "swift-agent-protocol"),
                .product(name: "OpenPawTerminalCore", package: "swift-terminal-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
