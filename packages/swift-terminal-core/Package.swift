// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-terminal-core",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "OpenPawTerminalCore", targets: ["OpenPawTerminalCore"])
    ],
    targets: [
        .target(
            name: "OpenPawTerminalCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenPawTerminalCoreTests",
            dependencies: ["OpenPawTerminalCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
